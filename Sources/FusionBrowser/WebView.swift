import Foundation
import WebKit
import AppKit

// FR-06: WKWebView wrapper. Headless via offscreen window; Headed via visible window.
// FR-04: nonPersistent dataStore per session (in-memory only).
// FR-08: shared WKProcessPool limits WebContent process count.

public final class FBWebView: NSObject, WKNavigationDelegate, WKUIDelegate {
    public let mode: WebMode
    public let sessionId: String
    private(set) var webView: WKWebView?
    private var hostWindow: NSWindow?
    private let log = FBLogger.shared
    // Shared pool to cap WebContent process count (FR-08).
    static let sharedPool = WKProcessPool()

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
        // FR-08: share process pool across sessions.
        config.processPool = FBWebView.sharedPool
        config.preferences.javaScriptEnabled = true

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        self.webView = wv

        if mode == .headless {
            // Offscreen, no visible window. Attach to a zero-size host to keep it alive.
            let host = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 800),
                                styleMask: [], backing: .buffered, defer: false)
            host.contentView = wv
            host.isReleasedWhenClosed = false
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
    public func injectCookies(_ attrs: [String: String], domain: String) {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore,
              let name = attrs["name"], let value = attrs["value"] else { return }
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
            log.warn("WebView", "cookie build failed name=\(name) domain=\(domain) sess=\(sessionId)")
            return
        }
        store.setCookie(cookie)
        log.info("WebView", "cookie injected name=\(name) domain=\(domain) httponly=\(attrs["httponly"] ?? "false") samesite=\(attrs["samesite"] ?? "") sess=\(sessionId)")
    }

    // FR-06 navigate. Watchdog handled by ActionDriver; here returns immediately.
    public func navigate(url: String, timeoutMs: Int) {
        guard let wv = webView, let u = URL(string: url) else { return }
        wv.load(URLRequest(url: u))
        log.info("WebView", "navigate \(url) sess=\(sessionId)")
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
            log.warn("WebView", "evaluateJSSync timeout script=\(script.prefix(80))")
            return nil
        }
        return out
    }

    // T2.1: sync JS eval with string args interpolated into the script (no arguments[] API on macOS 14).
    // Replaces ONE __ARG__ placeholder per arg, in order. (replacingOccurrences replaces ALL
    // occurrences, which would fill every placeholder with the first arg and starve the rest —
    // that broke click/type: expectFp got the nodeId, fingerprint never matched -> node_stale.)
    public func evaluateJSSyncArgs(_ script: String, args: [String], timeoutMs: Int = 5_000) -> Any? {
        var js = script
        for a in args {
            let esc = a.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
            if let r = js.range(of: "__ARG__") {
                js.replaceSubrange(r, with: esc)
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
            wv.takeSnapshot(with: cfg) { image, _ in
                if let img = image, let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff) {
                    out = rep.representation(using: .png, properties: [:])
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
        hostWindow?.close()
        hostWindow = nil
        log.debug("WebView", "destroyed sess=\(sessionId)")
    }

    // MARK: WKNavigationDelegate
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.info("WebView", "didFinish \(webView.url?.absoluteString ?? "") sess=\(sessionId)")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("WebView", "didFail \(error.localizedDescription) sess=\(sessionId)")
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
