import Foundation
import WebKit
import AppKit

// FR-06: WKWebView wrapper. Headless via offscreen window; Headed via visible window.
// FR-04: nonPersistent dataStore per session (in-memory only).
// FR-08: WebContent process count is bounded by the session cap (FBResourceQuota.maxSessions,
// enforced in SessionManager) + WebKit's built-in per-site process isolation. The old
// shared WKProcessPool was a no-op on macOS 12+ (deprecated: "multiple instances no
// longer has any effect") and was removed — it never enforced a process cap (B-2).

public final class FBWebView: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let mode: WebMode
    public let sessionId: String
    private(set) var webView: WKWebView?
    private var hostWindow: NSWindow?
    private let log = FBLogger.shared
    // L-7: JS eval pipeline wedge flag. WKWebView serializes JS eval on the main thread;
    // an adversarial/buggy page script (while(true){}) wedges the queue so every subsequent
    // evaluateJSSync times out with no way to cancel the in-flight eval. Set on timeout,
    // surfaced loudly, and a self-heal reload is attempted. There is no public API to cancel
    // a running evaluateJavaScript, so the only recovery is to reload the page (which drops
    // the wedged script context) — best-effort, never blocks the caller.
    private var jsWedged: Bool = false
    // R-1: pending navigation completion slot. Off-main navigate arms this; the
    // WKNavigationDelegate didFinish/didFail signals it, identity-matched to the
    // WKNavigation returned by load(). Lets navigate wait for the page to actually
    // load before the subsequent extract queries it (the old code only waited for
    // the main-hop = load issued, so extract ran against a still-loading page ->
    // stale/partial AXTree). One in-flight nav per session (navigate is synchronous
    // and serialized by the action watchdog).
    private let navLock = NSLock()
    private var pendingNav: (sem: DispatchSemaphore, nav: WKNavigation?)?

    // E-11/Finding 26: capture the real main-document HTTP response so the CDP
    // Network.responseReceived event can report the actual status (was hardcoded 200).
    // Set by decidePolicyFor (fires before didFinish); read by the CDP emitter after nav.
    // NSLock-guarded: decidePolicyFor fires on main, the CDP read fires off main.
    private let respLock = NSLock()
    private var _lastResponse: (status: Int, mime: String, headers: [String: String])?
    var lastResponse: (status: Int, mime: String, headers: [String: String])? {
        respLock.lock(); defer { respLock.unlock() }; return _lastResponse
    }
    func setLastResponse(_ r: (status: Int, mime: String, headers: [String: String])?) {
        respLock.lock(); _lastResponse = r; respLock.unlock()
    }

    public init(mode: WebMode, sessionId: String) {
        self.mode = mode
        self.sessionId = sessionId
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        // FR-04: in-memory session, nonPersistent dataStore per session.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        // FR-08: no explicit processPool — WKProcessPool is deprecated (macOS 12+, no-op).
        // WebKit manages WebContent processes internally with per-site isolation; the
        // live process count is bounded by the session cap (FBResourceQuota.maxSessions).
        config.preferences.javaScriptEnabled = true

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        self.webView = wv

        if mode == .headless {
            // Headless lives in an on-screen transparent window so the WKWebView page
            // visibilityState stays "visible". An offscreen (-2000,-2000) or un-ordered
            // window makes the page hidden, and WebKit's ProcessThrottler then sends
            // prepareToSuspend to the WebContent process; a WKSnapshot (screenshotSync)
            // forces a render that races the suspend and traps (sendPrepareToSuspendIPC ->
            // ~ProcessThrottlerActivity -> RefCounted::deref -> SIGTRAP exit 133). A
            // .userInitiated process activity token does NOT prevent this — ProcessThrottler
            // suspension is driven by page visibilityState, NOT by macOS App Nap. The window
            // must be on a real screen rect to keep visibilityState=visible. alphaValue=0 +
            // opaque=false + borderless make it invisible to the user; .accessory policy keeps
            // the app out of the Dock. .popUpMenu level + ignoresMouseEvents keep it from
            // stealing focus/input. Tested: on-screen + real snapshot = no crash; the RSS cost
            // of repeated snapshots is a separate cache-pressure concern (handled by the
            // reaper + memoryWatchdog), not a leak (plateaus, does not grow unbounded).
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            host.contentView = wv
            host.isReleasedWhenClosed = false
            host.isOpaque = false
            host.backgroundColor = .clear
            host.alphaValue = 0
            host.ignoresMouseEvents = true
            host.level = .popUpMenu
            host.orderFrontRegardless()
            self.hostWindow = host
        } else {
            let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
            host.title = "fusion-browser \(sessionId)"
            host.contentView = wv
            host.isReleasedWhenClosed = false
            host.makeKeyAndOrderFront(nil)
            self.hostWindow = host
        }
        installConsoleBridge(into: wv)
        log.debug("WebView", "setup \(sessionId) mode=\(mode.rawValue)")
    }

    // T3.3: intercept console.log/info/warn/error so the CDP layer can surface them as
    // Runtime.consoleAPICalled events (cowork buffers these). Writes to window.__fbConsole,
    // drained by FBCDPConnection.pushConsoleEvents. Runs as a user script at document start
    // so it applies to every navigated frame.
    private func installConsoleBridge(into wv: WKWebView) {
        let controller = wv.configuration.userContentController
        let script = """
        (function(){
            if(window.__fbConsoleInstalled){return;}
            window.__fbConsoleInstalled=true;
            window.__fbConsole=[];
            function serialize(a){try{return JSON.parse(JSON.stringify(a));}catch(e){return String(a);}}
            function wrap(type){return function(){var args=[].slice.call(arguments).map(serialize);
                window.__fbConsole.push({type:type,args:args});};}
            ['log','info','warn','error','debug'].forEach(function(k){
                var orig=console[k]?console[k].bind(console):function(){};
                console[k]=function(){wrap(k).apply(null,arguments);orig.apply(null,arguments);};
            });
        })();
        """
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(userScript)
    }

    // FR-05: inject full cookie attributes into this session's in-memory dataStore.
    // Stores name/value/domain/path/expires/secure/httponly/samesite (T2.4 full-attr requirement).
    // F-11: returns Bool so the caller reports injection truthfully (was true unconditionally).
    public func injectCookies(_ attrs: [String: String], domain: String) -> Bool {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore,
              let name = attrs["name"], let value = attrs["value"] else {
            log.warn("WebView", "cookie inject skip: missing store/name/value domain=\(domain) sess=\(sessionId)")
            return false
        }
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: attrs["domain"] ?? domain,
            .path: attrs["path"] ?? "/",
            .name: name,
            .value: value,
            .secure: attrs["secure"] == "true"
        ]
        if let expStr = attrs["expires"], let ts = Double(expStr), ts > 0 {
            props[.expires] = Date(timeIntervalSince1970: ts)
        }
        if attrs["httponly"] == "true" {
            props[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE"
        }
        if let sameSite = attrs["samesite"], !sameSite.isEmpty {
            props[HTTPCookiePropertyKey(rawValue: "SameSite")] = sameSite
        }
        guard let cookie = HTTPCookie(properties: props) else {
            log.warn("WebView", "cookie build failed name=<masked> domain=\(domain) sess=\(sessionId)")
            return false
        }
        // E-27: setCookie completion + off-main semaphore wait. The no-completion
        // store.setCookie(cookie) returns immediately and the cookie commits asynchronously,
        // so the old path returned true BEFORE the store actually held the cookie — a create
        // that navigated right after inject could miss the credential (race). The completion-
        // handler overload confirms the commit. Mirror clearCookies(): NEVER sync-wait on main
        // (the completion dispatches to main; sync-wait on main deadlocks); on main fall back
        // to the no-completion form + warn that the commit isn't confirmed (honest — the
        // create inject path runs off-main per SessionManager, so the main branch is a rare
        // guard, not the live path). Returns true only after the completion fires.
        if Thread.isMainThread {
            store.setCookie(cookie)
            log.warn("WebView", "cookie setCookie on main: commit not confirmed domain=\(domain) sess=\(sessionId)")
            return true
        }
        let sem = DispatchSemaphore(value: 0)
        var committed = false
        store.setCookie(cookie) {
            committed = true
            sem.signal()
        }
        let waited = sem.wait(timeout: .now() + .seconds(2))
        // E-39: cookie name reveals auth-token identity (e.g. sessionid, __Secure-SESSID).
        // Mask it like a password — log only domain + sess for ops correlation. Drop
        // httponly/samesite (low ops value, trims the line). The credential audit log
        // (Observability.swift) already records op/result only, never the value or name.
        log.info("WebView", "cookie injected name=<masked> domain=\(domain) committed=\(committed) timedout=\(waited == .timedOut) sess=\(sessionId)")
        return committed
    }

    // F-12: clear in-memory cookies for this session. logout must revoke the RUNTIME
    // cookie store, not just the persistent Keychain layer — otherwise the live webview
    // stays authenticated after Keychain delete. Synchronous (semaphore) so the caller
    // can order it BEFORE webview destroy on main. NEVER call on the main thread (the
    // completion dispatches to main; sync-wait on main deadlocks) — call off-main.
    public func clearCookies() {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        if Thread.isMainThread {
            log.warn("WebView", "clearCookies called on main; skipping sync wait (would deadlock) sess=\(sessionId)")
            return
        }
        let sem = DispatchSemaphore(value: 0)
        var count = 0
        // getAllCookies completion dispatches on main (UI actor). delete via the
        // completion-handler overload (the no-completion form is Swift-async), chaining
        // a final signal so the off-main caller can wait synchronously.
        store.getAllCookies { cookies in
            count = cookies.count
            let group = DispatchGroup()
            for c in cookies {
                group.enter()
                store.delete(c) { group.leave() }
            }
            group.notify(queue: .main) { sem.signal() }
        }
        _ = sem.wait(timeout: .now() + .seconds(2))
        log.info("WebView", "cleared \(count) in-memory cookies sess=\(sessionId)")
    }

    // FR-06 navigate. Watchdog handled by ActionDriver; here waits for didFinish/didFail.
    // WKWebView.load MUST run on main (off-main -> SIGTRAP exit 133). Called from
    // ActionDriver.dispatch inside the runWithWatchdog block on DispatchQueue.global(),
    // so guard the main-thread hop. Sync-wait so the subsequent extract() re-queries
    // the page that was actually loaded; never sync-wait ON main (deadlock).
    // R-1: the old code only waited for the main-hop (load() issued) — extract then ran
    // against a still-loading page -> stale/partial AXTree. Now arm a pending-nav slot on
    // the WKNavigation returned by load(), and wait for the navigation delegate to signal
    // didFinish/didFail (identity-matched by the WKNavigation object). On main thread the
    // wait is skipped (would deadlock); create-with-initial-url on main is fire-and-forget
    // (the next action re-extracts anyway).
    // F-17: capture [weak self] (NOT a local strong `wv`) so a close() that nulls the
    // webview during the wait can deallocate the WKWebView + its nonPersistent dataStore
    // and injected cookies — a local strong ref pinned it past close, and a late enqueued
    // load() fired on a torn-down session. The closure re-checks self.webView != nil
    // before load; on timeout we stopLoading() to cancel a wedged navigation.
    public func navigate(url: String, timeoutMs: Int) {
        guard let u = URL(string: url) else {
            log.warn("WebView", "navigate bad url=\(url) sess=\(sessionId)")
            return
        }
        // E-11/Finding 26: clear the previous nav's captured response BEFORE load so a
        // stale status can't leak into this nav's Network.responseReceived. decidePolicyFor
        // (below) refills it with the real status; for local schemes it stays nil -> status 0.
        setLastResponse(nil)
        if Thread.isMainThread {
            webView?.load(URLRequest(url: u))
            log.info("WebView", "navigate \(url) sess=\(sessionId) (main, no didFinish wait)")
            return
        }
        let sem = DispatchSemaphore(value: 0)
        var capturedNav: WKNavigation? = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let wv = self.webView else { sem.signal(); return }
            capturedNav = wv.load(URLRequest(url: u))
            // Arm the pending-nav slot so didFinish/didFail can signal THIS semaphore.
            // R-1: race-safe — the delegate fires on main too, so install under navLock
            // before we leave the main block; if didFinish somehow beats us (synchronous
            // page) the signal is buffered in the semaphore and the wait returns at once.
            self.navLock.lock()
            self.pendingNav = (sem, capturedNav)
            self.navLock.unlock()
            sem.signal()
        }
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            log.warn("WebView", "navigate main-hop timeout \(url) sess=\(sessionId)")
            webView?.stopLoading()
            clearPendingNav()
            return
        }
        // Wait for didFinish/didFail on the captured navigation. The main-hop semaphore
        // above released once load() was issued (and the slot armed); this second wait is
        // the real load-completion gate. Bounded by the same watchdog timeout budget.
        let waited = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        clearPendingNav()
        if waited == .timedOut {
            log.warn("WebView", "navigate didFinish timeout \(url) sess=\(sessionId)")
            webView?.stopLoading()
        } else {
            log.info("WebView", "navigate \(url) sess=\(sessionId) (didFinish)")
        }
    }

    // R-1: resolve + clear the pending-nav slot. Idempotent; called on both the success
    // and timeout/teardown paths so a stale slot never signals a future navigate.
    private func clearPendingNav() {
        navLock.lock()
        pendingNav = nil
        navLock.unlock()
    }

    public func currentUrl() -> String { return webView?.url?.absoluteString ?? "" }
    public func currentTitle() -> String { return webView?.title ?? "" }

    // JS eval with completion (async path).
    public func evaluateJS(_ script: String, completion: @escaping (Any?, Error?) -> Void) {
        webView?.evaluateJavaScript(script, completionHandler: completion)
    }

    // T2.1: sync JS eval. Blocks on semaphore until WKWebView callback fires.
    // Safe to call from a background queue (ActionDriver watchdog block); MUST NOT call on main
    // (would deadlock — WKWebView dispatches completion to main).
    // L-7: on timeout the underlying evaluateJavaScript is still running on WKWebView's
    // serialized JS queue, so the NEXT eval also blocks and times out — the session is wedged.
    // Set jsWedged (loud, surfacable), then best-effort reload the current URL to drop the
    // stuck script context (no public API cancels a running eval). The reload is async + on
    // main; it does not block this caller. If the page re-wedges, subsequent heals no-op
    // (guard the flag so we don't reload-loop).
    public func evaluateJSSync(_ script: String, timeoutMs: Int = 5_000) -> Any? {
        guard Thread.isMainThread == false else {
            log.error("WebView", "evaluateJSSync called on main -> would deadlock; returning nil")
            return nil
        }
        let sem = DispatchSemaphore(value: 0)
        var out: Any? = nil
        webView?.evaluateJavaScript(script) { result, _ in
            out = result
            sem.signal()
        }
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            jsWedged = true
            // R-15: the script body can carry credential payloads (typeText text, evaluate
            // expressions with secrets). The old log dumped script.prefix(80) to %{public}
            // os_log + the stderr sink — plaintext secrets in operator logs / Console.app.
            // Redact: log the length only (correlation via length + session), never the body.
            log.error("WebView", "evaluateJSSync TIMEOUT -> JS pipeline wedged sess=\(sessionId) scriptLen=\(script.count); attempting self-heal reload")
            selfHealReload()
            return nil
        }
        // A completion that fires in time clears the wedge (the pipeline drained).
        if jsWedged {
            jsWedged = false
            log.info("WebView", "JS pipeline recovered (eval completed) sess=\(sessionId)")
        }
        return out
    }

    // L-7: drop the wedged JS context by reloading the current URL. Async on main; never
    // blocks the caller. Guarded by jsWedged so a still-wedged page doesn't reload-loop on
    // every subsequent timed-out eval (the flag only clears when an eval actually completes).
    private func selfHealReload() {
        guard jsWedged else { return }
        let url = webView?.url?.absoluteString ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let wv = self.webView else { return }
            if let u = URL(string: url) {
                wv.load(URLRequest(url: u))
                self.log.warn("WebView", "self-heal reload \(url) sess=\(self.sessionId)")
            } else {
                wv.reload()
                self.log.warn("WebView", "self-heal reload (no url) sess=\(self.sessionId)")
            }
        }
    }

    // T2.1: sync JS eval with string args interpolated into the script (no arguments[] API on macOS 14).
    // Replaces ONE __ARG__ placeholder per arg, in order. (replacingOccurrences replaces ALL
    // occurrences, which would fill every placeholder with the first arg and starve the rest —
    // that broke click/type: expectFp got the nodeId, fingerprint never matched -> node_stale.)
    // F-16: each arg is serialized to a JSON string token (which includes its own surrounding
    // double quotes and a fully escaped body) and the surrounding `="__ARG__"` literal in the
    // script has its quotes stripped to `=__ARG__` so the JSON token supplies them. The old
    // hand-rolled 3-char escape (\\, ", \n) left backtick/${}/CR/</script> unescaped — a payload
    // with `;` or `}` broke the JS string and let the engine self-XSS via typeText. JSON
    // serialization is the complete, correct string-literal escape.
    public func evaluateJSSyncArgs(_ script: String, args: [String], timeoutMs: Int = 5_000) -> Any? {
        var js = script
        for a in args {
            guard let tokenData = try? JSONSerialization.data(withJSONObject: [a]),
                  let tokenArr = try? JSONSerialization.jsonObject(with: tokenData) as? [String],
                  let escaped = tokenArr.first else {
                log.warn("WebView", "arg JSON-serialize failed, dropping arg sess=\(sessionId)")
                continue
            }
            if let r = js.range(of: "__ARG__") {
                js.replaceSubrange(r, with: escaped)
            }
        }
        return evaluateJSSync(js, timeoutMs: timeoutMs)
    }

    // T2.3 / CDP Page.captureScreenshot: sync PNG capture.
    // takeSnapshot runs on main; blocks on semaphore (call off-main like evaluateJSSync).
    public func screenshotSync(timeoutMs: Int = 5_000) -> Data? {
        guard Thread.isMainThread == false else {
            log.error("WebView", "screenshotSync called on main -> would deadlock; returning nil")
            return nil
        }
        let sem = DispatchSemaphore(value: 0)
        var out: Data? = nil
        DispatchQueue.main.async { [weak self] in
            guard let wv = self?.webView else { sem.signal(); return }
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: 1280, height: 800)
            // afterScreenUpdates=false: reuse the last composited frame instead of forcing a
            // fresh composite per snapshot (the page is static between actions).
            cfg.afterScreenUpdates = false
            wv.takeSnapshot(with: cfg) { image, _ in
                // E-7 memory: tiffRepresentation + NSBitmapImageRep each alloc ~4MB in the
                // host and were retained per-snapshot (16MB/snapshot, never freed -> 1GB at
                // 200 snapshots). Build the PNG via the CGImage backing the NSImage instead:
                // takeSnapshot's NSImage wraps a CGImage; pull it, make a single
                // NSBitmapImageRep from the CGImage (no tiff intermediate), PNG-encode, then
                // nil the rep so its backing bitmap releases before the next snapshot. The
                // resulting PNG Data is a value type and does not retain the bitmap.
                autoreleasepool {
                    if let img = image, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let rep = NSBitmapImageRep(cgImage: cg)
                        out = rep.representation(using: .png, properties: [:])
                    }
                }
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
            log.warn("WebView", "screenshotSync timeout")
            return nil
        }
        return out
    }

    public func destroy() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        setLastResponse(nil)
        hostWindow?.close()
        hostWindow = nil
        log.debug("WebView", "destroyed sess=\(sessionId)")
    }

    // MARK: WKNavigationDelegate
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.info("WebView", "didFinish \(webView.url?.absoluteString ?? "") sess=\(sessionId)")
        resolvePendingNav(navigation)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("WebView", "didFail \(error.localizedDescription) sess=\(sessionId)")
        resolvePendingNav(navigation)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.error("WebView", "didFailProvisional \(error.localizedDescription) sess=\(sessionId)")
        resolvePendingNav(navigation)
    }

    // E-11/Finding 26: capture the real HTTP status/mimeType/headers of the main-document
    // response so the CDP Network.responseReceived event reports truth (was always 200).
    // decidePolicyFor fires for every navigation (main + subframe); keep only the main-frame
    // one (isForMainFrame) since cowork's navigate is main-document only. Always .allow.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            let headers = http.allHeaderFields as? [String: String] ?? [:]
            setLastResponse((http.statusCode, http.mimeType ?? "", headers))
            log.info("WebView", "nav response status=\(http.statusCode) mime=\(http.mimeType ?? "") sess=\(sessionId)")
        }
        decisionHandler(.allow)
    }

    // R-1: signal the pending navigate's completion if the finished/failed navigation is
    // the one we're waiting on (identity match on the WKNavigation object). A mismatch
    // (redirect-triggered subframe nav, etc.) is ignored so we only release on the
    // top-level load we started. Idempotent: clearPendingNav on the caller side also
    // nulls the slot, so a late delegate fire after timeout finds nil and no-ops.
    private func resolvePendingNav(_ navigation: WKNavigation?) {
        navLock.lock()
        let pending = pendingNav
        if let p = pending, let started = p.nav, let finished = navigation, started === finished {
            pendingNav = nil
            navLock.unlock()
            p.sem.signal()
        } else {
            navLock.unlock()
        }
    }

    // NFR-S1: block unauthorized cross-origin iframe + cancel downloads.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Block popups/new windows.
        log.warn("WebView", "blocked popup/new-window sess=\(sessionId)")
        return nil
    }
}
