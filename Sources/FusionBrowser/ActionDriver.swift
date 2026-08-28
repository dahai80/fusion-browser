import Foundation
import WebKit

// FR-06: action driver with tiered watchdog (NFR-R).
// NFR-R: navigate 30s, click/type 50ms-2s, screenshot 5s. Timeout -> crashed -> rebuild.
// Rebuild replays ONLY idempotent actions (navigate/scroll/screenshot); click/type/evaluate fail directly.

// F-15: cooperative cancel token for the watchdog block. NSLock-guarded bool so the
// cancel write (caller thread, on timeout) and the isCancelled read (worker thread, at
// dispatch entry) are synchronized — a plain var would be a data race.
public final class FBCancelToken {
    private let lock = NSLock()
    private var flag: Bool = false
    public init() {}
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); let v = flag; lock.unlock(); return v }
}

public final class FBActionDriver {
    private let watchdog: FBWatchdogPolicy
    private let auth: FBAuth
    private let allowedOrigins: [String]
    private let sanitizer: FBSanitizer
    // T3.4: optional visual-grounding fallback for when DOM/stable mapping can't resolve a node.
    private let visualLocator: FBVisualLocator?
    private let log = FBLogger.shared

    public init(watchdog: FBWatchdogPolicy, auth: FBAuth, allowedOrigins: [String],
                sanitizer: FBSanitizer, visualLocator: FBVisualLocator? = nil) {
        self.watchdog = watchdog
        self.auth = auth
        self.allowedOrigins = allowedOrigins
        self.sanitizer = sanitizer
        self.visualLocator = visualLocator
    }

    // Execute one action against a session. Returns state response (error set on failure).
    // H-5: the caller MUST pass the token's actual capabilities (from FBAuth.authenticate).
    // The driver enforces the per-action cap as the SINGLE source of truth — UDS/CDP pre-checks
    // are a fast fail-hint, but this gate is authoritative (closes the old hardcoded `.all`
    // bypass where a navigate-only token could EVALUATE because the driver never saw the real
    // caps). Evaluate additionally needs the origin whitelist (canEvaluate).
    public func execute(session: FBSession, req reqIn: BrowserActionRequest, caps: FBCapabilities) -> BrowserStateResponse {
        let traceId = reqIn.traceId ?? FBTrace.newId()
        let startTs = Date().timeIntervalSince1970
        let sid = session.id

        // T2.1 node-id normalization: AXTree markdown advertises interactive nodes as
        // [@eN] (with @ for LLM display), but the stable mapping + JS __fbMap key the
        // node BARE (e1). Callers (agent-studio BrowserTool, LLM, CDP) may pass the
        // markdown form "@e1". Strip the leading @ once here so resolve()/admit/JS all
        // see the bare key; the two forms then resolve the same node. Visible log so a
        // caller consistently sending @ is detectable (Rule 12), not silently coerced.
        var req = reqIn
        if let nid = req.targetNodeId, nid.hasPrefix("@") {
            let bare = String(nid.dropFirst())
            log.info("Action", "node_id normalize @ stripped: \(nid)->\(bare) sess=\(sid)",
                     traceId: traceId, sessionId: sid)
            req.targetNodeId = bare
        }

        // H-5: per-action capability enforcement (authoritative gate). The caller passes the
        // token's actual caps (FBAuth.authenticate result); a navigate-only token lacks
        // .evaluate and is rejected here BEFORE the scheduler/webview are touched — so a
        // denied request consumes neither a sched slot nor a rate token. This closes the
        // old defect where the driver hardcoded `.all` and a scoped token could EVALUATE.
        // `.evaluate` fails with evaluateDenied (its own code); other missing caps -> authDenied.
        guard let need = requiredCap(for: req.action) else {
            log.warn("Action", "no required cap mapped action=\(req.action.rawValue) sess=\(sid)",
                     traceId: traceId, sessionId: sid)
            return errorResp(session: session, req: req, traceId: traceId, err: .internalError, startTs: startTs)
        }
        if !caps.contains(need) {
            let err: FBError = req.action == .evaluate ? .evaluateDenied : .authDenied
            log.warn("Action", "cap denied need=\(need.rawValue) have=\(caps.rawValue) action=\(req.action.rawValue) sess=\(sid)",
                     traceId: traceId, sessionId: sid)
            return errorResp(session: session, req: req, traceId: traceId, err: err, startTs: startTs)
        }

        // FR-13 scheduling gate.
        switch session.scheduler.admit(action: req.action, target: req.targetNodeId, payload: req.payloadText) {
        case .accept: break
        case .rejectMaxActions(let e), .rejectTimeout(let e), .rejectReplayLimit(let e), .rejectRepeatBreak(let e):
            log.warn("Action", "sched reject \(e.code) sess=\(sid)", traceId: traceId, sessionId: sid)
            return errorResp(session: session, req: req, traceId: traceId, err: e, startTs: startTs)
        }

        // E-22: close-barrier. A concurrent close() (another client, reaper, memwatchdog)
        // flips isClosing + nils the webview field atomically BEFORE the main-hop teardown.
        // We may have captured this session via manager.get just before close() ran, so the
        // dict lookup passed but the session is now tearing down. Fail fast — do NOT touch
        // the webview (stopLoading/removeFromSuperview interleaved with our evaluateJSSync
        // -> JS completion never fires -> watchdog timeout or trap). Checked AFTER the
        // scheduler admit so a closing session does NOT consume a rate-limit/sched slot.
        if session.isClosing {
            log.warn("Action", "execute on closing session sess=\(sid)", traceId: traceId, sessionId: sid)
            return errorResp(session: session, req: req, traceId: traceId, err: .sessionClosing, startTs: startTs)
        }
        guard let wv = session.webview else {
            return errorResp(session: session, req: req, traceId: traceId, err: .sessionNotFound, startTs: startTs)
        }
        // R-5: mark the session active so the idle reaper doesn't close it mid-action-stream.
        session.touch()

        // FR-10: EVALUATE origin check. The .evaluate cap was enforced above (H-5); here
        // re-check the page origin against the whitelist (canEvaluate still requires the cap,
        // so pass the real caps — a token without .evaluate is already rejected above, this
        // is the belt-and-suspenders origin half).
        if req.action == .evaluate {
            let origin = wv.currentUrl()
            guard auth.canEvaluate(caps: caps, origin: origin, allowedOrigins: allowedOrigins) else {
                log.warn("Action", "evaluate denied origin=\(origin) sess=\(sid)", traceId: traceId, sessionId: sid)
                return errorResp(session: session, req: req, traceId: traceId, err: .evaluateDenied, startTs: startTs)
            }
        }

        let timeoutMs = watchdog.timeout(for: req.action)
        let result = runWithWatchdog(timeoutMs: timeoutMs) { [weak self] token in
            // F-15: if the watchdog already timed out and cancelled us, do NOT touch the
            // session/webview — the caller has moved on (possibly closing/rebuilding).
            if token.isCancelled { return nil }
            return self?.dispatch(session: session, webview: wv, req: req, sid: sid, traceId: traceId)
        }

        switch result {
        case .success(let state):
            let ms = Int((Date().timeIntervalSince1970 - startTs) * 1000)
            FBMetrics.shared.recordLatency("action.\(req.action.rawValue)", ms: ms)
            FBMetrics.shared.increment("action.\(req.action.rawValue).ok")
            return state
        case .failure(let err):
            log.warn("Action", "watchdog fail \(err.code) action=\(req.action.rawValue) sess=\(sid)",
                     traceId: traceId, sessionId: sid)
            return handleCrash(session: session, req: req, traceId: traceId, err: err, startTs: startTs)
        }
    }

    // H-5: map an action to the capability it requires. Mirrors UDSServer.cap(for:) so the
    // driver gate and the UDS pre-check agree. Returns nil only for an unmapped action
    // (none today; a future action that forgets to map fails visibly -> internalError).
    private func requiredCap(for action: ActionType) -> FBCapabilities? {
        switch action {
        case .navigate:   return .navigate
        case .click:      return .click
        case .typeText:   return .type
        case .scroll:     return .scroll
        case .screenshot: return .screenshot
        case .evaluate:   return .evaluate
        // .close is a session-level op handled by SessionManager.close, never routed to
        // execute(); nil -> the cap gate above fails visibly with internalError (Rule 12).
        case .close:      return nil
        }
    }

    // F-15: watchdog with cooperative cancel + join + locked outcome.
    // The old fire-and-forget `DispatchQueue.global().async { outcome = block() }` had two
    // defects: (a) `outcome` was an unsynchronized captured var read on the caller thread
    // while the block wrote it concurrently = data race (UB); (b) on timeout the block kept
    // running and called extract/evaluateJSSync on a session the caller had already given up
    // on — possibly mid-close/rebuild — touching a dead WKWebView or polluting the next
    // session's __fbMap. Fix: a cancel flag the block checks at the dispatch entry (no public
    // API cancels a running WKWebView eval, but we can stop BEFORE touching the webview), the
    // outcome read/write under a lock, and on timeout we set the flag and JOIN the block
    // (bounded wait) so the caller does not return while work still touches the session.
    private func runWithWatchdog(timeoutMs: Int, block: @escaping (FBCancelToken) -> BrowserStateResponse?) -> FBResult<BrowserStateResponse> {
        let token = FBCancelToken()
        let lock = NSLock()
        var outcome: BrowserStateResponse? = nil
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let st = block(token)
            lock.lock()
            outcome = st
            lock.unlock()
            sem.signal()
        }
        let waited = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        if waited == .timedOut {
            token.cancel()
            log.warn("Action", "watchdog timeout; cancelling + joining leaked block")
            // Join: bound the wait so a truly wedged (non-checking) block cannot hang the
            // caller forever. The block checks the token at dispatch entry, so in the normal
            // case it exits promptly; the bound covers a block already past the check.
            _ = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
            return .failure(.timeout)
        }
        lock.lock()
        let st = outcome
        lock.unlock()
        guard let st = st else { return .failure(.internalError) }
        return .success(st)
    }

    // T2.1/T2.2 dispatch: navigate/click/type/scroll/screenshot/evaluate via WKWebView.
    // click/type resolve @eN via stable mapping WeakRef + fingerprint; stale -> node_stale.
    private func dispatch(session: FBSession, webview wv: FBWebView, req: BrowserActionRequest, sid: String, traceId: String) -> BrowserStateResponse {
        let startTs = Date().timeIntervalSince1970
        // E-7: the .screenshot action previously fell through to a plain AXTree extract and
        // never captured an image — the response's screenshot field was always nil. Now capture
        // the real PNG via screenshotSync and carry it into the state response. Non-screenshot
        // actions leave this nil (no capture cost). Only capture for the explicit .screenshot
        // action; visual fallback (T3.4) takes its own internal screenshot, not this path.
        var capturedPng: Data? = nil
        // E-9: capture the real Runtime.evaluate JS return value (was discarded: callers
        // got literal "ok"). JSON-encode the deserialized value (NSString/NSNumber/NSNull/
        // NSArray/NSDictionary) into a String for the wire; nil when eval returned
        // undefined (nil), threw, or timed out. Decoded by CDP handleEvaluate into {result:{type,value}}.
        var evalResultJson: String? = nil
        switch req.action {
        case .navigate:
            if let url = req.payloadText { wv.navigate(url: url, timeoutMs: watchdog.navigateMs) }
        case .click:
            if let nid = req.targetNodeId {
                let mp = session.extractor.resolve(nid)
                let fp = mp?.fingerprint ?? ""
                if let raw = wv.evaluateJSSyncArgs(FBWalkerScript.resolveClick, args: [nid, fp]) as? String,
                   let data = raw.data(using: .utf8),
                   let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let ok = r["ok"] as? Bool ?? false
                    let stale = r["stale"] as? Bool ?? false
                    if !ok && stale {
                        log.warn("Action", "click node_stale @\(nid) sess=\(sid)", traceId: traceId, sessionId: sid)
                        // T3.4: visual-grounding fallback before surfacing node_stale.
                        if let coord = visualFallback(webview: wv, nodeId: nid, mapping: mp, session: session) {
                            // L-5: validate finite + in-viewport BEFORE string interpolation into
                            // JS (NaN/Infinity would become elementFromPoint(NaN,NaN)).
                            guard coord.x.isFinite, coord.y.isFinite,
                                  coord.x >= 0, coord.y >= 0,
                                  coord.x <= 1280, coord.y <= 800 else {
                                log.warn("Action", "visual coord invalid x=\(coord.x) y=\(coord.y) sess=\(sid)",
                                         traceId: traceId, sessionId: sid)
                                return errorResp(session: session, req: req, traceId: traceId, err: .nodeStale, startTs: startTs)
                            }
                            // L-5: visual click bypasses the fingerprint __fbMap path, so update
                            // the scheduler's lastActionKey to the bare-coordinate key — otherwise
                            // the scheduler's lastActionKey still holds "click:@eN:" and a second
                            // visual fallback trips repeat-break on a stale key.
                            session.scheduler.noteVisualClick(target: nid)
                            let clickJS = "(function(){var e=document.elementFromPoint(\(coord.x),\(coord.y));if(e){e.click();return 'ok';}return 'miss';})();"
                            _ = wv.evaluateJSSync(clickJS)
                            log.info("Action", "click visual fallback @\(nid) x=\(coord.x) y=\(coord.y) sess=\(sid)",
                                     traceId: traceId, sessionId: sid)
                        } else {
                            return errorResp(session: session, req: req, traceId: traceId, err: .nodeStale, startTs: startTs)
                        }
                    }
                }
            }
        case .typeText:
            if let nid = req.targetNodeId, let text = req.payloadText {
                let fp = session.extractor.resolve(nid)?.fingerprint ?? ""
                if let raw = wv.evaluateJSSyncArgs(FBWalkerScript.resolveType, args: [nid, fp, text]) as? String,
                   let data = raw.data(using: .utf8),
                   let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let ok = r["ok"] as? Bool ?? false
                    let stale = r["stale"] as? Bool ?? false
                    if !ok && stale {
                        log.warn("Action", "type node_stale @\(nid) sess=\(sid)", traceId: traceId, sessionId: sid)
                        return errorResp(session: session, req: req, traceId: traceId, err: .nodeStale, startTs: startTs)
                    }
                }
            }
        case .scroll:
            let dy = req.scrollDeltaY ?? 300
            _ = wv.evaluateJSSync("window.scrollBy(0,\(dy))")
        case .screenshot:
            // E-7: real capture. screenshotSync returns WKSnapshot PNG (headless offscreen
            // webview is not on a CoreGraphics display, so takeSnapshot, not CGWindowList).
            // A nil capture (timeout / no webview) is logged; the response then carries no
            // image but still the AXTree, so the caller degrades visibly (Rule 12).
            // Stable at any frequency because the on-screen host window (WebView.swift
            // headless branch) keeps page visibilityState "visible", so WebContent's
            // ProcessThrottler never sends prepareToSuspend and WKSnapshot never races a
            // suspend (the SIGTRAP exit 133 root cause; App Nap token alone does NOT prevent
            // it — ProcessThrottler suspension is driven by page visibility, not App Nap).
            capturedPng = wv.screenshotSync(timeoutMs: watchdog.screenshotMs)
            if capturedPng == nil {
                log.warn("Action", "screenshot capture nil sess=\(sid)", traceId: traceId, sessionId: sid)
            } else {
                log.info("Action", "screenshot captured \(capturedPng?.count ?? 0)B png sess=\(sid)",
                         traceId: traceId, sessionId: sid)
            }
        case .evaluate:
            // E-9: capture the real JS expression result, JSON-encoded, so callers
            // (CDP Runtime.evaluate + UDS) get the actual value instead of "ok".
            // WKWebView returns JSON-compatible Foundation objects (NSString/NSNumber/
            // NSNull/NSArray/NSDictionary). .fragmentsAllowed encodes a bare fragment
            // (string/number/bool/null) as a top-level JSON value, not wrapped in an array.
            if let script = req.payloadText {
                if let val = wv.evaluateJSSync(script),
                   let data = try? JSONSerialization.data(withJSONObject: val, options: [.fragmentsAllowed]),
                   let s = String(data: data, encoding: .utf8) {
                    evalResultJson = s
                }
            }
        case .close:
            break
        }
        // T2.1: re-extract AXTree after action for state response.
        // H-1: route through THIS session's extractor (per-session mapping isolation).
        let (res, md, audit, err) = session.extractor.extract(webview: wv)
        let ms = Int((Date().timeIntervalSince1970 - startTs) * 1000)
        if let e = err {
            return errorResp(session: session, req: req, traceId: traceId, err: e, startTs: startTs)
        }
        let nodes = res?.nodes.map { FBAXTreeReducer.toWireNode($0) } ?? []
        return BrowserStateResponse(sessionId: sid, url: res?.url ?? wv.currentUrl(),
                                    title: res?.title ?? wv.currentTitle(),
                                    axTreeMarkdown: md, interactiveNodes: nodes,
                                    screenshotPng: capturedPng,
                                    hasSecurityInjectionBlocked: audit.hiddenNodesPurged > 0,
                                    executionTimeMs: ms, securityAudit: audit,
                                    sessionRecovered: false, traceId: traceId,
                                    evaluateResult: evalResultJson)
    }

    // T3.4: best-effort visual grounding fallback. Screenshot + VLM coordinate predict,
    // returns nil if locator absent / disabled / failed / OOB / redacted.
    // F-13: the screenshot is a full 1280x800 viewport PNG and leaves this process to a
    // separate fusion-mlx VLM process (its own prompt/KV/request logs). It can capture a
    // rendered, unmasked password field or account number. So NEVER fall back when:
    //   (a) the stale node's role is a secret input (password/secret), or
    //   (b) the page origin matches a credential-injection domain for this session.
    // Surfacing node_stale is safer than exfiltrating secret pixels.
    // L-5: gate on locator.isEnabled (visualLocator != nil is not enough — the config
    // object can exist with enabled=false).
    private func visualFallback(webview wv: FBWebView, nodeId: String, mapping: FBNodeMapping?,
                                session: FBSession) -> FBPredictedCoord? {
        guard let locator = visualLocator, locator.isEnabled else { return nil }
        // F-13(a): skip for secret-input roles.
        let role = (mapping?.role ?? "").lowercased()
        if role.contains("password") || role.contains("secret") {
            log.warn("Action", "visual fallback skipped: secret role=\(role) @\(nodeId) sess=\(session.id)")
            return nil
        }
        // F-13(b): skip when the page origin matches this session's credential domain —
        // the screenshot likely renders authenticated/credential-bearing content.
        if let credDomain = session.credentialDomain, !credDomain.isEmpty {
            let origin = wv.currentUrl()
            if origin.contains(credDomain) {
                log.warn("Action", "visual fallback skipped: origin matches cred domain=\(credDomain) @\(nodeId) sess=\(session.id)")
                return nil
            }
        }
        guard let png = wv.screenshotSync() else {
            log.warn("Action", "visual fallback no screenshot sess=\(session.id)")
            return nil
        }
        let desc = [mapping?.role, mapping?.name].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
        let description = desc.isEmpty ? "the primary interactive element" : desc
        return locator.predict(screenshot: png, description: description, viewportSize: (w: 1280, h: 800))
    }

    // NFR-R: crash recovery. Rebuild replays idempotent only; depth cap 1.
    // L-1: recovered must be TRUTHFUL. The old code marked recovered:true on BOTH branches
    // without actually re-navigating (the comment said "handled by next request"), so a
    // caller saw recovered=true + error and wrongly assumed a consistent session. We do NOT
    // replay (no lastUrl re-navigate path), so report recovered:false on every branch — the
    // session is re-marked runnable for the next action, but the caller is told the failed
    // action was NOT recovered (page state may be inconsistent; the next action re-extracts).
    private func handleCrash(session: FBSession, req: BrowserActionRequest, traceId: String,
                             err: FBError, startTs: Double) -> BrowserStateResponse {
        session.transition(to: .crashed)
        // E-23: rebuildDepth must count ONLY real replays. A non-idempotent action
        // (navigate/click/type/evaluate) is never replayed, so it must NOT consume the
        // depth cap. Check idempotency FIRST; only an idempotent action that will actually
        // be replayed may call canRebuild() (which increments). The old order called
        // canRebuild() before isIdempotent, so two slow-page click timeouts (non-idempotent,
        // never replayed) exhausted rebuildDepthCap=1 and bricked the session permanent_fail.
        // L-1: .navigate is non-idempotent (POST/onLoad side effects), so it lands here too.
        guard FBScheduler.isIdempotent(req.action) else {
            // Non-idempotent: no replay, no depth consumed -> fail directly, session runnable.
            session.transition(to: .running)
            return errorResp(session: session, req: req, traceId: traceId, err: err, startTs: startTs,
                             recovered: false)
        }
        // Idempotent: this is a real replay candidate -> consume the depth cap now.
        guard session.scheduler.canRebuild() else {
            session.transition(to: .permanentFail)
            return errorResp(session: session, req: req, traceId: traceId, err: .replayLimit, startTs: startTs,
                             recovered: false)
        }
        session.transition(to: .rebuilding)
        log.info("Action", "rebuild admit idempotent action=\(req.action.rawValue) sess=\(session.id)",
                 traceId: traceId, sessionId: session.id)
        // No re-navigate (no lastUrl tracked); re-mark runnable, report honestly NOT recovered.
        session.transition(to: .running)
        return errorResp(session: session, req: req, traceId: traceId, err: err, startTs: startTs, recovered: false)
    }

    private func errorResp(session: FBSession, req: BrowserActionRequest, traceId: String,
                           err: FBError, startTs: Double, recovered: Bool = false) -> BrowserStateResponse {
        let ms = Int((Date().timeIntervalSince1970 - startTs) * 1000)
        FBMetrics.shared.increment("action.\(req.action.rawValue).fail")
        return BrowserStateResponse(sessionId: session.id, url: "", title: "",
                                    axTreeMarkdown: "", interactiveNodes: [],
                                    executionTimeMs: ms, sessionRecovered: recovered,
                                    error: err, traceId: traceId)
    }

}
