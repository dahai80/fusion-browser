import Foundation
import WebKit

// FR-06: action driver with tiered watchdog (NFR-R).
// NFR-R: navigate 30s, click/type 50ms-2s, screenshot 5s. Timeout -> crashed -> rebuild.
// Rebuild replays ONLY idempotent actions (navigate/scroll/screenshot); click/type/evaluate fail directly.

public final class FBActionDriver {
    private let watchdog: FBWatchdogPolicy
    private let auth: FBAuth
    private let allowedOrigins: [String]
    private let extractor: FBAXTreeExtractor
    private let sanitizer: FBSanitizer
    // T3.4: optional visual-grounding fallback for when DOM/stable mapping can't resolve a node.
    private let visualLocator: FBVisualLocator?
    private let log = FBLogger.shared

    public init(watchdog: FBWatchdogPolicy, auth: FBAuth, allowedOrigins: [String],
                extractor: FBAXTreeExtractor, sanitizer: FBSanitizer,
                visualLocator: FBVisualLocator? = nil) {
        self.watchdog = watchdog
        self.auth = auth
        self.allowedOrigins = allowedOrigins
        self.extractor = extractor
        self.sanitizer = sanitizer
        self.visualLocator = visualLocator
    }

    // Execute one action against a session. Returns state response (error set on failure).
    public func execute(session: FBSession, req reqIn: BrowserActionRequest) -> BrowserStateResponse {
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

        // FR-13 scheduling gate.
        switch session.scheduler.admit(action: req.action, target: req.targetNodeId, payload: req.payloadText) {
        case .accept: break
        case .rejectMaxActions(let e), .rejectTimeout(let e), .rejectReplayLimit(let e), .rejectRepeatBreak(let e):
            log.warn("Action", "sched reject \(e.code) sess=\(sid)", traceId: traceId, sessionId: sid)
            return errorResp(session: session, req: req, traceId: traceId, err: e, startTs: startTs)
        }

        guard let wv = session.webview else {
            return errorResp(session: session, req: req, traceId: traceId, err: .sessionNotFound, startTs: startTs)
        }

        // FR-10: EVALUATE capability + origin check done at server (caps known there);
        // here re-check origin against whitelist.
        if req.action == .evaluate {
            let origin = wv.currentUrl()
            guard auth.canEvaluate(caps: .all, origin: origin, allowedOrigins: allowedOrigins) else {
                log.warn("Action", "evaluate denied origin=\(origin) sess=\(sid)", traceId: traceId, sessionId: sid)
                return errorResp(session: session, req: req, traceId: traceId, err: .evaluateDenied, startTs: startTs)
            }
        }

        let timeoutMs = watchdog.timeout(for: req.action)
        let result = runWithWatchdog(timeoutMs: timeoutMs) { [weak self] in
            self?.dispatch(session: session, webview: wv, req: req, sid: sid, traceId: traceId)
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

    // Watchdog: run block, fail with timeout if not completed in time.
    private func runWithWatchdog(timeoutMs: Int, block: @escaping () -> BrowserStateResponse?) -> FBResult<BrowserStateResponse> {
        let sem = DispatchSemaphore(value: 0)
        var outcome: BrowserStateResponse? = nil
        DispatchQueue.global().async {
            outcome = block()
            sem.signal()
        }
        let waited = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        if waited == .timedOut {
            return .failure(.timeout)
        }
        guard let st = outcome else { return .failure(.internalError) }
        return .success(st)
    }

    // T2.1/T2.2 dispatch: navigate/click/type/scroll/screenshot/evaluate via WKWebView.
    // click/type resolve @eN via stable mapping WeakRef + fingerprint; stale -> node_stale.
    private func dispatch(session: FBSession, webview wv: FBWebView, req: BrowserActionRequest, sid: String, traceId: String) -> BrowserStateResponse {
        let startTs = Date().timeIntervalSince1970
        switch req.action {
        case .navigate:
            if let url = req.payloadText { wv.navigate(url: url, timeoutMs: watchdog.navigateMs) }
        case .click:
            if let nid = req.targetNodeId {
                let fp = extractor.resolve(nid)?.fingerprint ?? ""
                if let raw = wv.evaluateJSSyncArgs(FBWalkerScript.resolveClick, args: [nid, fp]) as? String,
                   let data = raw.data(using: .utf8),
                   let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let ok = r["ok"] as? Bool ?? false
                    let stale = r["stale"] as? Bool ?? false
                    if !ok && stale {
                        log.warn("Action", "click node_stale @\(nid) sess=\(sid)", traceId: traceId, sessionId: sid)
                        // T3.4: visual-grounding fallback before surfacing node_stale.
                        if let coord = visualFallback(webview: wv, nodeId: nid, session: session) {
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
                let fp = extractor.resolve(nid)?.fingerprint ?? ""
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
            break // screenshot handled in state assembly
        case .evaluate:
            if let script = req.payloadText { _ = wv.evaluateJSSync(script) }
        case .close:
            break
        }
        // T2.1: re-extract AXTree after action for state response.
        let (res, md, audit, err) = extractor.extract(webview: wv)
        let ms = Int((Date().timeIntervalSince1970 - startTs) * 1000)
        if let e = err {
            return errorResp(session: session, req: req, traceId: traceId, err: e, startTs: startTs)
        }
        let nodes = res?.nodes.map { FBAXTreeReducer.toWireNode($0) } ?? []
        return BrowserStateResponse(sessionId: sid, url: res?.url ?? wv.currentUrl(),
                                    title: res?.title ?? wv.currentTitle(),
                                    axTreeMarkdown: md, interactiveNodes: nodes,
                                    hasSecurityInjectionBlocked: audit.hiddenNodesPurged > 0,
                                    executionTimeMs: ms, securityAudit: audit,
                                    sessionRecovered: false, traceId: traceId)
    }

    // T3.4: best-effort visual grounding fallback. Screenshot + VLM coordinate predict,
    // returns nil if locator absent / disabled / failed / OOB. Description is derived from
    // the stale node's role+name so the VLM has a grounding cue.
    private func visualFallback(webview wv: FBWebView, nodeId: String, session: FBSession) -> FBPredictedCoord? {
        guard let locator = visualLocator else { return nil }
        guard let png = wv.screenshotSync() else {
            log.warn("Action", "visual fallback no screenshot sess=\(session.id)")
            return nil
        }
        let mapping = extractor.resolve(nodeId)
        let desc = [mapping?.role, mapping?.name].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
        let description = desc.isEmpty ? "the primary interactive element" : desc
        return locator.predict(screenshot: png, description: description, viewportSize: (w: 1280, h: 800))
    }

    // NFR-R: crash recovery. Rebuild replays idempotent only; depth cap 1.
    private func handleCrash(session: FBSession, req: BrowserActionRequest, traceId: String,
                             err: FBError, startTs: Double) -> BrowserStateResponse {
        session.transition(to: .crashed)
        guard session.scheduler.canRebuild() else {
            session.transition(to: .permanentFail)
            return errorResp(session: session, req: req, traceId: traceId, err: .replayLimit, startTs: startTs,
                             recovered: false)
        }
        guard FBScheduler.isIdempotent(req.action) else {
            // Non-idempotent (click/type/evaluate) NOT replayed -> fail directly.
            return errorResp(session: session, req: req, traceId: traceId, err: err, startTs: startTs,
                             recovered: true)
        }
        session.transition(to: .rebuilding)
        log.info("Action", "rebuild replay idempotent action=\(req.action.rawValue) sess=\(session.id)",
                 traceId: traceId, sessionId: session.id)
        // Phase 1: rebuild = re-navigate (handled by next request). Mark recovered.
        session.transition(to: .running)
        return errorResp(session: session, req: req, traceId: traceId, err: err, startTs: startTs, recovered: true)
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
