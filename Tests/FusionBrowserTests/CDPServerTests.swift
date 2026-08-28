import XCTest
import CryptoKit
import Darwin
@testable import FusionBrowser

// T2.3 acceptance gate: CDP transport codec + discovery shape + translator dispatch +
// non-whitelist EVALUATE rejection. Live WKWebView cannot run under `swift test`
// (evaluateJSSync deadlocks with no main run loop), so the evaluate DENY path is
// asserted through the real translator -> server.executeAction -> ActionDriver ->
// auth origin check (deny returns before the watchdog, no JS eval, no hang).
// Accessibility.getFullAXTree / captureScreenshot live shapes + the evaluate ALLOW
// path are verified via the binary + Python smoke client, not here.

// MARK: - WS frame codec (RFC 6455, server decodes masked client frames)

final class CDPFrameCodecTests: XCTestCase {
    let codec = FBWSFrameCodec()

    private func maskedFrame(_ payload: String, mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]) -> Data {
        let pl = Data(payload.utf8)
        var out = Data()
        out.append(0x81)
        out.append(UInt8(0x80 | pl.count))
        out.append(contentsOf: mask)
        for i in 0..<pl.count { out.append(pl[i] ^ mask[i % 4]) }
        return out
    }

    private func unmaskedFrame(_ payload: String) -> Data {
        let pl = Data(payload.utf8)
        var out = Data()
        out.append(0x81)
        out.append(UInt8(pl.count))
        out.append(pl)
        return out
    }

    func testDecodeMaskedTextFrame() {
        let (frame, _) = codec.tryDecode(maskedFrame("hello cdp"))!
        XCTAssertEqual(frame?.opcode, 0x1)
        XCTAssertEqual(String(data: frame?.payload ?? Data(), encoding: .utf8), "hello cdp")
    }

    // L-12: RFC 6455 §5.1 — a server MUST reject unmasked client frames. The codec now
    // poisons the stream on an unmasked frame (returns nil permanently), so the old
    // "accept unmasked" assertion is inverted: an unmasked frame is rejected.
    func testDecodeUnmaskedClientFrameRejected() {
        XCTAssertNil(codec.tryDecode(unmaskedFrame("{\"id\":1,\"result\":{}}")))
        // Stream is poisoned — further valid frames also return nil.
        XCTAssertNil(codec.tryDecode(maskedFrame("after")))
    }

    // A fresh codec still accepts a valid masked frame (poison is per-codec, not global).
    func testDecodeMaskedFrameOnFreshCodec() {
        let fresh = FBWSFrameCodec()
        let (frame, _) = fresh.tryDecode(maskedFrame("{\"id\":1,\"result\":{}}"))!
        XCTAssertEqual(frame?.opcode, 0x1)
        XCTAssertEqual(String(data: frame?.payload ?? Data(), encoding: .utf8), "{\"id\":1,\"result\":{}}")
    }

    func testDecodePartialReturnsNil() {
        XCTAssertNil(codec.tryDecode(Data([0x81])))
        XCTAssertNil(codec.tryDecode(Data([0x81, 0x05])))
    }

    func testDecodeExtendedLength126() {
        let payload = String(repeating: "x", count: 200)
        let pl = Data(payload.utf8)
        let mask: [UInt8] = [0x0A, 0x0B, 0x0C, 0x0D]
        var out = Data()
        out.append(0x81)
        out.append(0x80 | 126)
        out.append(UInt8((pl.count >> 8) & 0xFF))
        out.append(UInt8(pl.count & 0xFF))
        out.append(contentsOf: mask)
        for i in 0..<pl.count { out.append(pl[i] ^ mask[i % 4]) }
        let (frame, consumed) = codec.tryDecode(out)!
        XCTAssertEqual(frame?.opcode, 0x1)
        XCTAssertEqual(frame?.payload.count, 200)
        XCTAssertEqual(consumed, out.count)
        XCTAssertEqual(String(data: frame?.payload ?? Data(), encoding: .utf8)?.count, 200)
    }

    func testDecodeCloseAndPingOpcodes() {
        var close = Data([0x88, 0x80])
        close.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        let (cf, _) = codec.tryDecode(close)!
        XCTAssertEqual(cf?.opcode, 0x8)
        var ping = Data([0x89, 0x82])
        ping.append(contentsOf: [0x05, 0x06, 0x07, 0x08, 0xAA, 0xBB])
        for i in 4..<ping.count { ping[i] ^= [0x05, 0x06, 0x07, 0x08][(i - 4) % 4] }
        let (pf, _) = codec.tryDecode(ping)!
        XCTAssertEqual(pf?.opcode, 0x9)
    }
}

// MARK: - Translator dispatch (no-op + static methods; nil server never touches webview)

final class CDPTranslatorTests: XCTestCase {
    let translator = FBCDPTranslator(server: nil, allowedOrigins: [])

    private func dispatch(_ method: String, _ params: [String: Any] = [:], id: Int = 1) -> [String: Any] {
        let resp = translator.dispatch(method: method, params: params, id: id)
        return resp.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func testNoOpEnablesReturnEmptyResult() {
        for m in ["Page.enable", "Runtime.enable", "Accessibility.enable", "DOM.enable",
                  "Network.enable", "Performance.enable", "Log.enable",
                  "Page.disable", "Network.disable", "Runtime.disable"] {
            let r = dispatch(m, id: 7)
            XCTAssertEqual(r["id"] as? Int, 7)
            XCTAssertTrue((r["result"] as? [String: Any])?.isEmpty ?? false, "method not no-op: \(m)")
            XCTAssertNil(r["error"])
        }
    }

    func testDOMGetDocumentShape() {
        // E-8: nil server -> stub document root (no live webview). Shape still pinned:
        // nodeId=1, nodeName=#document. childNodeCount is 0 with no session (fail-safe).
        let r = dispatch("DOM.getDocument")
        let root = (r["result"] as? [String: Any])?["root"] as? [String: Any]
        XCTAssertEqual(root?["nodeId"] as? Int, 1)
        XCTAssertEqual(root?["nodeName"] as? String, "#document")
        XCTAssertNil(r["error"])
    }

    func testDOMQuerySelectorShape() {
        // E-8: nil server -> fail-closed "no server" error (was a fake FNV-hash nodeId).
        // A real server registers a qN id and returns its integer nodeId (see live smoke).
        let r = dispatch("DOM.querySelector", ["selector": "#login-btn"])
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32000, "nil-server querySelector must fail-closed, not fake a nodeId")
    }

    func testDOMQuerySelectorMissingSelectorErrors() {
        let r = dispatch("DOM.querySelector", [:], id: 5)
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32602)
    }

    func testDOMGetBoxModelShape() {
        // E-8: nil server / unregistered handle -> "node not found" (was a hardcoded
        // 1280x800 quad). A real server derefs the live element's getBoundingClientRect
        // (see live smoke). The stub quad is GONE — fail-closed, never a fake rect.
        let r = dispatch("DOM.getBoxModel", ["objectId": "fb-obj-1"])
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32000, "getBoxModel must not return a fake 1280x800 quad")
    }

    func testDOMResolveNodeShape() {
        // E-8: unregistered backendNodeId -> "node not found" (was a fake "fb-node-42"
        // objectId never registered anywhere). A registered backendNodeId mints a real
        // "fb-obj-N" objectId bound to an idStr (see CDPDOMRegistryTests).
        let r = dispatch("DOM.resolveNode", ["backendNodeId": 42])
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32000, "resolveNode must not fake an unregistered objectId")
    }

    func testPerformanceMetricsReturnsRealValues() {
        // R-3/B-3: Performance.getMetrics returns REAL engine metrics, not an empty list.
        // Record a distinct counter so the result is non-empty regardless of shared state.
        let key = "test.cdp.metrics.\(FBTrace.newId())"
        FBMetrics.shared.increment(key, by: 7)
        let r = dispatch("Performance.getMetrics")
        let metrics = (r["result"] as? [String: Any])?["metrics"] as? [[String: Any]]
        XCTAssertNotNil(metrics, "metrics array must be present")
        XCTAssertFalse(metrics?.isEmpty ?? true, "metrics must not be empty (was [] before R-3)")
        let entry = metrics?.first { ($0["name"] as? String) == key }
        XCTAssertEqual(entry?["value"] as? Double, 7.0, "recorded counter must surface with its value")
    }

    func testPageNavigateReturnsFrameId() {
        // E-15: navigate gate is now fail-closed for http(s) origins (empty allowlist denies,
        // nil server denies). A LOCAL scheme (data:) skips the origin gate (originOfUrl ->
        // nil -> no cross-origin risk), so this nil-server translator still returns the static
        // frameId/loaderId without touching a webview (ARCH-3 safe). The static result shape
        // is what's under test, not the URL.
        let r = dispatch("Page.navigate", ["url": "data:text/html,<p>frame</p>"])
        let res = r["result"] as? [String: Any]
        XCTAssertEqual(res?["frameId"] as? String, "fb-frame")
        XCTAssertEqual(res?["loaderId"] as? String, "fb-loader")
        XCTAssertNil(r["error"], "local-scheme navigate must not be denied by the origin gate")
    }

    func testEmulationAndTracingNoOps() {
        for m in ["Emulation.setDeviceMetricsOverride", "Tracing.start", "Tracing.end",
                  "HeapProfiler.takeHeapSnapshot", "Page.handleJavaScriptDialog"] {
            let r = dispatch(m)
            XCTAssertNil(r["error"], "method errored: \(m)")
        }
    }

    func testUnsupportedMethodReturnsError() {
        let r = dispatch("Foo.bar", id: 99)
        XCTAssertEqual(r["id"] as? Int, 99)
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32601)
    }

    // E-8: DOM.focus with an unregistered objectId -> "node not found" fail-closed (was a
    // blind activeElement.focus() ack). A registered objectId derefs the live element.
    // setFileInputFiles stays a headless ack (not E-8 scope).
    func testDOMFocusReturnsNodeNotFoundForUnregisteredHandle() {
        let r = dispatch("DOM.focus", ["objectId": "fb-node-42"], id: 3)
        XCTAssertEqual(r["id"] as? Int, 3)
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32000, "focus must not ack an unregistered handle")
    }

    func testDOMSetFileInputFilesAcknowledged() {
        let r = dispatch("DOM.setFileInputFiles", ["files": ["/tmp/x.png"], "nodeId": 5], id: 4)
        XCTAssertEqual(r["id"] as? Int, 4)
        XCTAssertNil(r["error"], "setFileInputFiles must not error (headless ack)")
        XCTAssertTrue((r["result"] as? [String: Any])?.isEmpty ?? false)
    }
}

// MARK: - CDP server-push event emitter (T3.3: Network/Page lifecycle/console emulation)
// Deterministic unit tests against FBCDPEventEmitter. Live WS + navigate integration
// can't run under `swift test` — Page.navigate hits FBActionDriver -> evaluateJSSync,
// which deadlocks with no main run loop. The emitter is decoupled via a `send` closure
// so we assert event shape/flags without a socket or WKWebView. Live integration is
// verified via the binary + Python smoke client.

final class CDPEventEmitterTests: XCTestCase {
    // Box the captured frames in a class so the send closure's appends are visible to
    // the caller (Swift value-type capture by a closure mutates the captured variable,
    // not the caller's copy of the returned value).
    private final class CaptureBox { var frames: [[String: Any]] = [] }

    private func makeEmitter() -> (FBCDPEventEmitter, CaptureBox) {
        let box = CaptureBox()
        let em = FBCDPEventEmitter { text in
            if let d = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                box.frames.append(obj)
            }
        }
        return (em, box)
    }

    private func methods(_ box: CaptureBox) -> [String] {
        return box.frames.compactMap { $0["method"] as? String }
    }

    // Acceptance: after Page.enable + Network.enable + navigate, push the full event
    // set in real-Chrome order (E-11/Finding 10): Network trio first, then Page lifecycle.
    func testNavigatePushesLifecycleAndNetworkEvents() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Page.enable")
        em.applyDomainEnable(method: "Network.enable")
        XCTAssertTrue(em.pageEnabled)
        XCTAssertTrue(em.networkEnabled)
        em.pushNavigateEvents(url: "https://example.com",
                              response: (status: 200, mime: "text/html", headers: [:]))
        let m = methods(box)
        XCTAssertTrue(m.contains("Page.frameNavigated"), "missing frameNavigated: \(m)")
        XCTAssertTrue(m.contains("Network.requestWillBeSent"), "missing requestWillBeSent: \(m)")
        XCTAssertTrue(m.contains("Network.responseReceived"), "missing responseReceived: \(m)")
        XCTAssertTrue(m.contains("Network.loadingFinished"), "missing loadingFinished: \(m)")
        XCTAssertEqual(m.filter { $0 == "Page.lifecycleEvent" }.count, 2, "expect 2 lifecycle events (load + DOMContentLoaded): \(m)")
        // Every event frame must carry params and NO id (cowork routes id==nil to _dispatch_event).
        for e in box.frames {
            XCTAssertNotNil(e["params"], "event missing params: \(e)")
            XCTAssertNil(e["id"], "event must not carry id: \(e)")
        }
        // Network event params carry the navigated url.
        let req = box.frames.first { $0["method"] as? String == "Network.requestWillBeSent" }?["params"] as? [String: Any]
        XCTAssertEqual(req?["documentURL"] as? String, "https://example.com")
        let resp = box.frames.first { $0["method"] as? String == "Network.responseReceived" }?["params"] as? [String: Any]
        let respObj = resp?["response"] as? [String: Any]
        XCTAssertEqual(respObj?["status"] as? Int, 200)
    }

    // E-11/Finding 10: nav events fire in real-Chrome order — Network trio BEFORE the
    // Page lifecycle, and DOMContentLoaded BEFORE load (was inverted: frameNavigated->load->DOMContentLoaded->Network).
    func testNavigateEventOrderRealChrome() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Page.enable")
        em.applyDomainEnable(method: "Network.enable")
        em.pushNavigateEvents(url: "https://example.com", response: nil)
        let m = methods(box)
        // Full expected sequence (6 events).
        XCTAssertEqual(m, ["Network.requestWillBeSent", "Network.responseReceived",
                           "Network.loadingFinished", "Page.frameNavigated",
                           "Page.lifecycleEvent", "Page.lifecycleEvent"], "wrong event order: \(m)")
        // DOMContentLoaded must precede load (lifecycle names in order).
        let names = box.frames.compactMap { ($0["method"] as? String == "Page.lifecycleEvent") ? ($0["params"] as? [String: Any])?["name"] as? String : nil }
        XCTAssertEqual(names, ["DOMContentLoaded", "load"], "lifecycle order wrong: \(names)")
    }

    // E-11/Finding 25: loaderId/requestId are per-nav (was constants reused every nav);
    // frameId stays constant across navigations (stable per frame).
    func testLoaderIdPerNav() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Page.enable")
        em.applyDomainEnable(method: "Network.enable")
        em.pushNavigateEvents(url: "https://a.example.com", response: nil)
        let loader1 = (box.frames.first { $0["method"] as? String == "Page.frameNavigated" }?["params"] as? [String: Any])?["frame"] as? [String: Any]
        let frame1 = loader1?["id"] as? String
        let loaderId1 = loader1?["loaderId"] as? String
        let req1 = (box.frames.first { $0["method"] as? String == "Network.requestWillBeSent" }?["params"] as? [String: Any])
        let reqId1 = req1?["requestId"] as? String
        em.pushNavigateEvents(url: "https://b.example.com", response: nil)
        let loader2 = (box.frames.last { $0["method"] as? String == "Page.frameNavigated" }?["params"] as? [String: Any])?["frame"] as? [String: Any]
        let frame2 = loader2?["id"] as? String
        let loaderId2 = loader2?["loaderId"] as? String
        let req2 = (box.frames.last { $0["method"] as? String == "Network.requestWillBeSent" }?["params"] as? [String: Any])
        let reqId2 = req2?["requestId"] as? String
        XCTAssertNotNil(loaderId1)
        XCTAssertNotNil(loaderId2)
        XCTAssertNotEqual(loaderId1, loaderId2, "loaderId reused across navs: \(loaderId1)")
        XCTAssertNotEqual(reqId1, reqId2, "requestId reused across navs: \(reqId1)")
        XCTAssertEqual(frame1, frame2, "frameId must stay constant per frame: \(frame1) vs \(frame2)")
        XCTAssertEqual(frame1, "fb-frame", "frameId constant value: \(frame1)")
    }

    // E-11/Finding 26: responseReceived reports the REAL status captured by FBWebView
    // (was hardcoded 200). A 403 surfaces as 403; nil response (local scheme / no capture)
    // surfaces as 0, never a fake 200.
    func testResponseReceivedRealStatus() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Network.enable")
        // Real failure status.
        em.pushNavigateEvents(url: "https://denied.example.com",
                              response: (status: 403, mime: "text/html", headers: ["X-A": "1"]))
        var resp = box.frames.first { $0["method"] as? String == "Network.responseReceived" }?["params"] as? [String: Any]
        var respObj = resp?["response"] as? [String: Any]
        XCTAssertEqual(respObj?["status"] as? Int, 403, "403 must surface as 403, not faked 200")
        XCTAssertEqual(respObj?["statusText"] as? String, "", "non-2xx statusText empty: \(respObj?["statusText"])")
        XCTAssertEqual(respObj?["headers"] as? [String: String], ["X-A": "1"], "real headers threaded")
        // No response captured (local scheme) -> status 0, never a fake 200.
        box.frames.removeAll()
        em.pushNavigateEvents(url: "about:blank", response: nil)
        resp = box.frames.first { $0["method"] as? String == "Network.responseReceived" }?["params"] as? [String: Any]
        respObj = resp?["response"] as? [String: Any]
        XCTAssertEqual(respObj?["status"] as? Int, 0, "no-response must surface as 0, not faked 200")
        XCTAssertEqual(respObj?["statusText"] as? String, "unknown", "status 0 statusText: \(respObj?["statusText"])")
    }

    // Acceptance: WITHOUT domain enable, navigate pushes no events (gated by flags).
    func testNoDomainEnableMeansNoEvents() {
        let (em, box) = makeEmitter()
        // No enables — straight navigate.
        em.pushNavigateEvents(url: "https://example.com", response: nil)
        XCTAssertTrue(box.frames.isEmpty, "events pushed without domain enable: \(box.frames)")
    }

    // Only Page enabled -> only Page events, no Network events.
    func testPageOnlyPushesNoNetworkEvents() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Page.enable")
        em.pushNavigateEvents(url: "https://example.com", response: nil)
        let m = methods(box)
        XCTAssertTrue(m.contains("Page.frameNavigated"))
        XCTAssertFalse(m.contains("Network.requestWillBeSent"), "Network event leaked with only Page enabled: \(m)")
    }

    // Domain disable flips flags back off.
    func testDisableFlipsFlags() {
        let (em, _) = makeEmitter()
        em.applyDomainEnable(method: "Page.enable")
        em.applyDomainEnable(method: "Network.enable")
        XCTAssertTrue(em.pageEnabled)
        em.applyDomainEnable(method: "Page.disable")
        XCTAssertFalse(em.pageEnabled)
        XCTAssertTrue(em.networkEnabled)
    }

    // Acceptance: console bridge — Runtime.enable + captured console JSON -> consoleAPICalled events.
    func testConsoleBridgeEmitsConsoleAPICalled() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Runtime.enable")
        let consoleJSON = #"[{"type":"log","args":["hi"]},{"type":"error","args":["boom"]}]"#
        em.pushConsoleEvents(fromConsoleJSON: consoleJSON)
        let m = methods(box)
        XCTAssertEqual(m.filter { $0 == "Runtime.consoleAPICalled" }.count, 2)
        let first = box.frames.first?["params"] as? [String: Any]
        XCTAssertEqual(first?["type"] as? String, "log")
        let second = box.frames.last?["params"] as? [String: Any]
        XCTAssertEqual(second?["type"] as? String, "error")
    }

    // Without Runtime.enable, console JSON is ignored.
    func testConsoleBridgeNoRuntimeEnableNoEvents() {
        let (em, box) = makeEmitter()
        em.pushConsoleEvents(fromConsoleJSON: #"[{"type":"log","args":["hi"]}]"#)
        XCTAssertTrue(box.frames.isEmpty)
    }

    // Malformed console JSON is dropped, not crashed.
    func testConsoleBridgeMalformedJSONDropped() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Runtime.enable")
        em.pushConsoleEvents(fromConsoleJSON: "not-json")
        XCTAssertTrue(box.frames.isEmpty)
    }
}

// MARK: - EVALUATE rejection (full path: translator -> ActionDriver -> auth origin)

final class CDPEvaluateRejectionTests: XCTestCase {
    private func makeServer(allowedOrigins: [String]) -> (FBCDPServer, FBSessionManager) {
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: allowedOrigins)
        let sanitizer = FBSanitizer()
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: auth,
                                    allowedOrigins: allowedOrigins, sanitizer: sanitizer)
        let server = FBCDPServer(port: 0, manager: mgr, driver: driver,
                                 auth: auth, allowedOrigins: allowedOrigins)
        return (server, mgr)
    }

    // Non-whitelist EVALUATE rejected: fresh session url="" not in allowedOrigins -> evaluate_denied.
    // Deny returns before the watchdog, so no JS eval and no deadlock under `swift test`.
    func testNonWhitelistEvaluateRejected() {
        let (server, mgr) = makeServer(allowedOrigins: ["https://example.com"])
        let translator = FBCDPTranslator(server: server, allowedOrigins: ["https://example.com"])
        let resp = translator.dispatch(method: "Runtime.evaluate",
                                       params: ["expression": "document.cookie"], id: 5)
        let r = resp.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        XCTAssertEqual(r["id"] as? Int, 5)
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32000)
        XCTAssertEqual(err?["message"] as? String, "evaluate_denied")
        // Clean up the lazily-created session.
        if let sid = mgr.listIds().first { _ = mgr.close(sessionId: sid) }
    }

    // Missing expression -> structured error (does not reach ActionDriver).
    func testEvaluateMissingExpressionErrors() {
        let (server, mgr) = makeServer(allowedOrigins: [])
        let translator = FBCDPTranslator(server: server, allowedOrigins: [])
        let resp = translator.dispatch(method: "Runtime.evaluate", params: [:], id: 8)
        let r = resp.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32602)
        if let sid = mgr.listIds().first { _ = mgr.close(sessionId: sid) }
    }

    // E-9: Runtime.evaluate must return the REAL JS result, not a synthetic "ok". The
    // full handler needs a live webview (deadlocks under swift test), so the type-mapping
    // core (cdpRemoteObject) is unit-tested directly: it turns the JSON-decoded JS value
    // into the CDP RemoteObject {type, value} pair. The live end-to-end (expression ->
    // evaluateJSSync -> evaluateResult -> cdpRemoteObject -> {result:{type,value}}) is
    // verified via the release binary + Python smoke. These tests pin the mapping so a
    // regression (e.g. every value -> "string"/"ok") fails loudly.
    private func makeTranslator() -> FBCDPTranslator {
        let (server, _) = makeServer(allowedOrigins: [])
        return FBCDPTranslator(server: server, allowedOrigins: [])
    }

    func testCdpRemoteObjectString() {
        let (typ, val) = makeTranslator().cdpRemoteObject("hello" as Any)
        XCTAssertEqual(typ, "string")
        XCTAssertEqual(val as? String, "hello")
    }

    func testCdpRemoteObjectNumber() {
        let (typ, val) = makeTranslator().cdpRemoteObject(42 as Any)
        XCTAssertEqual(typ, "number")
        XCTAssertEqual(val as? Double, 42.0)
    }

    func testCdpRemoteObjectBoolean() {
        let (typ, val) = makeTranslator().cdpRemoteObject(true as Any)
        XCTAssertEqual(typ, "boolean")
        XCTAssertEqual(val as? Bool, true)
    }

    func testCdpRemoteObjectNullIsUndefined() {
        // JS null deserializes to NSNull; the shim maps it to CDP type "undefined"
        // (no distinct JS-null RemoteObject table in this shim).
        let (typ, _) = makeTranslator().cdpRemoteObject(NSNull())
        XCTAssertEqual(typ, "undefined")
    }

    func testCdpRemoteObjectArrayIsObject() {
        let (typ, val) = makeTranslator().cdpRemoteObject([1, 2, 3] as Any)
        XCTAssertEqual(typ, "object")
        XCTAssertEqual((val as? [Any])?.count, 3)
    }

    func testCdpRemoteObjectDictIsObject() {
        let (typ, val) = makeTranslator().cdpRemoteObject(["title": "page"] as Any)
        XCTAssertEqual(typ, "object")
        XCTAssertEqual((val as? [String: Any])?["title"] as? String, "page")
    }
}

// MARK: - Loopback: HTTP discovery + WS upgrade handshake + WS frame round-trip

final class CDPDiscoveryLoopbackTests: XCTestCase {
    private func freePort() -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.getsockname(fd, sa, &len)
            }
        }
        let port = Int(UInt16(bigEndian: out.sin_port))
        Darwin.close(fd)
        return port
    }

    private func makeServer(port: Int) -> FBCDPServer {
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: [])
        let sanitizer = FBSanitizer()
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: auth,
                                    allowedOrigins: [], sanitizer: sanitizer)
        return FBCDPServer(port: port, manager: mgr, driver: driver,
                           auth: auth, allowedOrigins: [])
    }

    // E-15: WS upgrade now fail-closed on empty Origin / empty allowlist, so the positive
    // WS-handshake tests need a server with an allowlist AND a matching Origin header to
    // upgrade (the bare `makeServer(port:)` has an empty allowlist and would 403).
    private func makeServer(port: Int, allowedOrigins: [String]) -> FBCDPServer {
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: allowedOrigins)
        let sanitizer = FBSanitizer()
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: auth,
                                    allowedOrigins: allowedOrigins, sanitizer: sanitizer)
        return FBCDPServer(port: port, manager: mgr, driver: driver,
                           auth: auth, allowedOrigins: allowedOrigins)
    }

    // F-2: every request must carry `Authorization: Bearer t` now that the CDP layer
    // enforces fail-closed Bearer auth. Helper appends the header to a raw request string.
    private func authed(_ req: String) -> String {
        // Insert the Bearer header before the terminating blank line.
        return req.replacingOccurrences(of: "\r\n\r\n", with: "\r\nAuthorization: Bearer t\r\n\r\n")
    }

    private func connect(port: Int) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return fd
    }

    private func sendAll(fd: Int32, _ s: String) {
        _ = s.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    private func recvUntil(fd: Int32, marker: Data, deadlineSec: Int = 4) -> Data {
        var out = Data()
        let deadline = Date().addingTimeInterval(TimeInterval(deadlineSec))
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                out.append(Data(bytes: buf, count: n))
                if out.range(of: marker) != nil { return out }
            } else if n == 0 { return out }
            else { if errno == EAGAIN || errno == EWOULDBLOCK { continue }; return out }
        }
        return out
    }

    func testDiscoveryListJSONShape() throws {
        let port = freePort()
        let server = makeServer(port: port)
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, authed("GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
        let raw = recvUntil(fd: fd, marker: Data("]".utf8))
        let body = String(data: raw, encoding: .utf8) ?? ""
        let jsonStart = body.range(of: "[")?.lowerBound ?? body.endIndex
        let arr = try JSONSerialization.jsonObject(with: Data(body[jsonStart...].utf8)) as? [[String: Any]]
        XCTAssertEqual(arr?.count, 1)
        let entry = arr?.first ?? [:]
        XCTAssertEqual(entry["type"] as? String, "page")
        XCTAssertEqual(entry["id"] as? String, server.targetId)
        XCTAssertTrue((entry["webSocketDebuggerUrl"] as? String ?? "").hasPrefix("ws://127.0.0.1:"))
        XCTAssertTrue((entry["webSocketDebuggerUrl"] as? String ?? "").contains("/devtools/page/"))
    }

    func testVersionJSONShape() throws {
        let port = freePort()
        let server = makeServer(port: port)
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, authed("GET /json/version HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
        let raw = recvUntil(fd: fd, marker: Data("}".utf8))
        let body = String(data: raw, encoding: .utf8) ?? ""
        let jsonStart = body.range(of: "{")?.lowerBound ?? body.endIndex
        let obj = try JSONSerialization.jsonObject(with: Data(body[jsonStart...].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["Browser"] as? String, "fusion-browser/2.0")
        XCTAssertTrue((obj?["webSocketDebuggerUrl"] as? String ?? "").contains("/devtools/page/"))
    }

    func testWSUpgradeHandshake() throws {
        let port = freePort()
        // E-15: WS upgrade is fail-closed on empty Origin/allowlist, so the positive path
        // needs a server allowlist + a matching Origin header.
        let server = makeServer(port: port, allowedOrigins: ["https://example.com"])
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, authed("GET /devtools/page/\(server.targetId) HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Origin: https://example.com\r\n" +
                        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n"))
        let raw = recvUntil(fd: fd, marker: Data("\r\n\r\n".utf8))
        let resp = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(resp.contains("HTTP/1.1 101"), "no 101: \(resp.prefix(120))")
        XCTAssertTrue(resp.contains("Sec-WebSocket-Accept: \(expected)"), "accept mismatch: \(resp.prefix(200))")
    }

    func testWSFrameRoundTripNoOp() {
        let port = freePort()
        guard let server = try? { () -> FBCDPServer in
            // E-15: positive WS path needs a server allowlist + matching Origin header.
            let s = makeServer(port: port, allowedOrigins: ["https://example.com"])
            try s.start()
            return s
        }() else { XCTFail("server start failed"); return }
        defer { server.stop() }
        usleep(100_000)

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, authed("GET /devtools/page/\(server.targetId) HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Origin: https://example.com\r\n" +
                        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n"))
        _ = recvUntil(fd: fd, marker: Data("\r\n\r\n".utf8))

        // Send masked client text frame once, as raw bytes: Page.enable (no-op, no webview touch).
        let payload = #"{"id":1,"method":"Page.enable","params":{}}"#
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
        let pl = Data(payload.utf8)
        var frame = Data()
        frame.append(0x81)
        frame.append(UInt8(0x80 | pl.count))
        frame.append(contentsOf: mask)
        for i in 0..<pl.count { frame.append(pl[i] ^ mask[i % 4]) }
        let sent = frame.withUnsafeBytes { Darwin.write(fd, $0.bindMemory(to: UInt8.self).baseAddress, frame.count) }
        XCTAssertEqual(sent, frame.count)

        // Server echoes an unmasked text frame. Read until the response terminator "}}"
        // (Page.enable returns {"id":1,"result":{}}) so the full frame payload is buffered
        // before decode — stopping at the first "}" would leave the frame short.
        let respData = recvUntil(fd: fd, marker: Data("}}".utf8), deadlineSec: 5)
        // Server→client frames are unmasked (RFC 6455 §5.1); decode with requireMask=false.
        let (decoded, _) = FBWSFrameCodec(requireMask: false).tryDecode(respData) ?? (nil, 0)
        XCTAssertEqual(decoded?.opcode, 0x1)
        let respStr = String(data: decoded?.payload ?? Data(), encoding: .utf8) ?? ""
        let r = respStr.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        XCTAssertEqual(r["id"] as? Int, 1)
        XCTAssertTrue((r["result"] as? [String: Any])?.isEmpty ?? false)
        XCTAssertNil(r["error"])
    }

    // F-2: WS upgrade without a Bearer token is rejected (403), not upgraded to 101.
    func testWSUpgradeWithoutBearerRejected() throws {
        let port = freePort()
        let server = makeServer(port: port)
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        // No Authorization header.
        sendAll(fd: fd, "GET /devtools/page/\(server.targetId) HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n")
        let raw = recvUntil(fd: fd, marker: Data("\r\n\r\n".utf8))
        let resp = String(data: raw, encoding: .utf8) ?? ""
        // Fail-closed: a missing Bearer is rejected (401/403 — either is a deny, not 101).
        XCTAssertTrue(resp.contains("401") || resp.contains("403"), "expected deny without bearer: \(resp.prefix(120))")
        XCTAssertFalse(resp.contains("101"))
    }

    // F-2: HTTP /json without a Bearer token is rejected (401).
    func testHTTPDiscoveryWithoutBearerRejected() throws {
        let port = freePort()
        let server = makeServer(port: port)
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, "GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let raw = recvUntil(fd: fd, marker: Data("\r\n\r\n".utf8))
        let resp = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(resp.contains("401"), "expected 401 without bearer: \(resp.prefix(120))")
    }

    // F-3: WS upgrade with a disallowed Origin is rejected (403), even with a valid Bearer.
    func testWSUpgradeDisallowedOriginRejected() throws {
        let port = freePort()
        // Server configured with an allowlist that excludes the attacker origin.
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: ["https://example.com"])
        let sanitizer = FBSanitizer()
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: auth,
                                    allowedOrigins: ["https://example.com"], sanitizer: sanitizer)
        let server = FBCDPServer(port: port, manager: mgr, driver: driver,
                                 auth: auth, allowedOrigins: ["https://example.com"])
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, authed("GET /devtools/page/\(server.targetId) HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Origin: https://evil.attacker.com\r\n" +
                        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n"))
        let raw = recvUntil(fd: fd, marker: Data("\r\n\r\n".utf8))
        let resp = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(resp.contains("403"), "expected 403 for disallowed origin: \(resp.prefix(160))")
        XCTAssertFalse(resp.contains("101"))
    }

    // E-15: WS upgrade with a VALID Bearer but NO Origin header is rejected (403). The old
    // code let an empty Origin bypass the check (commented "non-browser client like cowork is
    // allowed"), giving a token-bearing local attacker a free pass. Strict fail-closed: a
    // client MUST send an allowlisted Origin to upgrade, even with a valid Bearer.
    func testWSUpgradeEmptyOriginFailClosed() throws {
        let port = freePort()
        let server = makeServer(port: port, allowedOrigins: ["https://example.com"])
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        // Valid Bearer (authed), but NO Origin header at all.
        sendAll(fd: fd, authed("GET /devtools/page/\(server.targetId) HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n"))
        let raw = recvUntil(fd: fd, marker: Data("\r\n\r\n".utf8))
        let resp = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(resp.contains("403"), "empty Origin must be rejected (E-15 fail-closed): \(resp.prefix(160))")
        XCTAssertFalse(resp.contains("101"), "empty Origin must NOT upgrade")
    }

    // E-15/R-16: PUT /json/new?<remote-url> with an empty allowlist is rejected (403), not
    // navigated. The old path called executeAction with NO origin gate, letting default-config
    // operators drive the webview to any attacker origin via the discovery endpoint.
    func testPutJsonNewRemoteOriginDeniedOnEmptyAllowlist() throws {
        let port = freePort()
        let server = makeServer(port: port, allowedOrigins: [])
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, authed("PUT /json/new?https://evil.attacker.com HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
        let raw = recvUntil(fd: fd, marker: Data("\r\n\r\n".utf8))
        let resp = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(resp.contains("403"), "PUT /json/new remote origin must be denied on empty allowlist (E-15): \(resp.prefix(160))")
    }

    // F-7: hasPrefix bypass is closed. `https://example.com.evil.com` must NOT match an
    // allowlist of `https://example.com` (the old hasPrefix check let it through).
    func testOriginHasPrefixBypassClosed() {
        let auth = FBAuth(token: "t")
        // Structured compare rejects the suffix-host.
        XCTAssertFalse(auth.isOriginAllowed("https://example.com.evil.com",
                                            allowedOrigins: ["https://example.com"]))
        XCTAssertFalse(auth.isOriginAllowed("https://example.comadmin",
                                            allowedOrigins: ["https://example.com"]))
        // Exact match passes; scheme+host case-insensitive.
        XCTAssertTrue(auth.isOriginAllowed("https://example.com", allowedOrigins: ["https://example.com"]))
        XCTAssertTrue(auth.isOriginAllowed("HTTPS://Example.COM", allowedOrigins: ["https://example.com"]))
        // Port-aware: allowlist with port matches same port; bare host allowlist matches any port.
        XCTAssertTrue(auth.isOriginAllowed("https://example.com:8443", allowedOrigins: ["https://example.com"]))
        XCTAssertFalse(auth.isOriginAllowed("https://example.com:8443", allowedOrigins: ["https://example.com:443"]))
        // F-6: empty whitelist denies (fail-closed), not allow-all.
        XCTAssertFalse(auth.isOriginAllowed("https://example.com", allowedOrigins: []))
        // Opaque origins rejected when a whitelist is configured.
        XCTAssertFalse(auth.isOriginAllowed("about:blank", allowedOrigins: ["https://example.com"]))
        XCTAssertFalse(auth.isOriginAllowed("data:text/html,x", allowedOrigins: ["https://example.com"]))
    }

    // F-4: a 64-bit length frame with the high bit set is rejected (would crash via
    // negative-Int subdata). The codec poisons the stream and returns nil.
    func testNegativeLengthFrameRejected() {
        let codec = FBWSFrameCodec()
        // [0x82 (FIN+binary), 0x7F (mask+127), 0x80 0x00... (high-bit-set 64-bit len), 4 mask bytes]
        var frame = Data([0x82, 0x7F, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        frame.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // mask key
        XCTAssertNil(codec.tryDecode(frame), "negative-length frame must be rejected, not crash")
    }

    // F-5: an oversize declared payload (exceeding 10MiB cap) is rejected, not buffered.
    func testOversizePayloadRejected() {
        let codec = FBWSFrameCodec()
        // Declare a 126-length frame with length = maxPayload+1 (we only need the header
        // to be well-formed enough to reach the cap check; mask set, 16-bit length).
        let overlong = FBWSFrameCodec.maxPayloadBytes + 1
        var frame = Data([0x81, 0xFE]) // FIN+text, mask+126
        frame.append(UInt8((overlong >> 8) & 0xFF))
        frame.append(UInt8(overlong & 0xFF))
        frame.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // mask key
        // Don't send the payload body — the cap check fires before the body-read guard.
        XCTAssertNil(codec.tryDecode(frame), "oversize payload must be rejected before buffering")
    }
}

// MARK: - CDP DOM identity registry + JS resolver builders (E-8)
// The registry maps CDP integer nodeIds / opaque objectIds back to the walker idStr
// ("eN" / "qN") so focus / getBoxModel / resolveNode deref a real live element. The pure
// JS builders (buildBoxModelJS / buildFocusJS) pin the resolver shape + the stale-node
// {ok:false} invariant — no webview needed (ARCH-3 safe). Live rect/deref behavior is
// verified via scripts/cdp_dom_smoke.py against the release binary.

final class CDPDOMRegistryTests: XCTestCase {
    // A translator with a nil server is enough for registry + builder tests: the registry
    // lives on the translator, and the builders only read idStrToSelector (no server call).
    private let translator = FBCDPTranslator(server: nil, allowedOrigins: [])

    // registerIdStr("e5") -> stableNodeId=5; resolveIdStr({backendNodeId:5}) -> "e5".
    // Round-trip the int handle cowork caches from getFullAXTree back to the walker idStr.
    func testRegisterAndResolveIntHandle() {
        let nodeId = translator.registerIdStr("e5")
        XCTAssertEqual(nodeId, 5, "eN -> N integer nodeId")
        XCTAssertEqual(translator.resolveIdStr(params: ["backendNodeId": 5]), "e5")
        XCTAssertEqual(translator.resolveIdStr(params: ["nodeId": 5]), "e5")
    }

    // mintObjectId("e5") -> "fb-obj-1"; resolveIdStr({objectId:...}) -> "e5". Cowork's
    // click flow caches this objectId after resolveNode and passes it to focus/getBoxModel.
    func testMintAndResolveObjectId() {
        let oid = translator.mintObjectId("e5")
        XCTAssertTrue(oid.hasPrefix("fb-obj-"), "objectId namespace: \(oid)")
        XCTAssertEqual(translator.resolveIdStr(params: ["objectId": oid]), "e5")
        // A second mint is a fresh handle (cowork may re-resolve the same node).
        let oid2 = translator.mintObjectId("e5")
        XCTAssertNotEqual(oid, oid2)
        XCTAssertEqual(translator.resolveIdStr(params: ["objectId": oid2]), "e5")
    }

    // Unknown handles -> nil -> caller returns node_not_found fail-closed (never a fake deref).
    func testResolveUnknownHandleIsNil() {
        XCTAssertNil(translator.resolveIdStr(params: ["backendNodeId": 9999]))
        XCTAssertNil(translator.resolveIdStr(params: ["objectId": "fb-obj-9999"]))
        XCTAssertNil(translator.resolveIdStr(params: [:]))
    }

    // objectId takes precedence over an int handle (cowork sends both on some calls).
    func testObjectIdPrecedence() {
        translator.registerIdStr("e7")           // int 7 -> "e7"
        let oid = translator.mintObjectId("e3")  // objectId -> "e3"
        let p: [String: Any] = ["objectId": oid, "backendNodeId": 7]
        XCTAssertEqual(translator.resolveIdStr(params: p), "e3")
    }

    // buildBoxModelJS pins the resolver shape: deref __fbMap -> getBoundingClientRect quad
    // (8 coords TL->TR->BR->BL); empty idStr -> nil; no fallback selector -> no `else` clause.
    func testBuildBoxModelJSShape() {
        XCTAssertNil(translator.buildBoxModelJS(idStr: ""))
        let js = translator.buildBoxModelJS(idStr: "e5")!
        XCTAssertTrue(js.hasPrefix("(function(id){var ref=window.__fbMap&&window.__fbMap.get(id);"))
        XCTAssertTrue(js.contains("getBoundingClientRect()"))
        XCTAssertTrue(js.contains("content:[r.left,r.top,r.right,r.top,r.right,r.bottom,r.left,r.bottom]"))
        XCTAssertTrue(js.hasSuffix("})(\"e5\");"), "idStr is jsStr-escaped into the IIFE arg")
        XCTAssertFalse(js.contains("querySelector"), "no fallback without a bound selector")
    }

    // buildBoxModelJS with a bound qN selector emits a re-query fallback branch (the walker
    // rebuilds __fbMap fresh each extract, dropping qN entries; the fallback re-resolves).
    func testBuildBoxModelJSWithSelectorFallback() {
        translator.bindSelector("input#u", toIdStr: "q1")
        let js = translator.buildBoxModelJS(idStr: "q1")!
        XCTAssertTrue(js.contains("else{var fb=document.querySelector(\"input#u\");"))
        XCTAssertTrue(js.contains("rr.left,rr.top,rr.right,rr.top,rr.right,rr.bottom,rr.left,rr.bottom"))
    }

    // buildFocusJS pins the resolver shape: deref -> focus() + bubbling FocusEvent; empty
    // -> nil; qN selector fallback re-queries + focuses.
    func testBuildFocusJSShape() {
        XCTAssertNil(translator.buildFocusJS(idStr: ""))
        let js = translator.buildFocusJS(idStr: "e2")!
        XCTAssertTrue(js.hasPrefix("(function(id){var ref=window.__fbMap&&window.__fbMap.get(id);"))
        XCTAssertTrue(js.contains("el.focus();"))
        XCTAssertTrue(js.contains("new FocusEvent('focus',{bubbles:true})"))
        XCTAssertTrue(js.hasSuffix("})(\"e2\");"))
        XCTAssertFalse(js.contains("querySelector"), "no fallback without a bound selector")
    }

    func testBuildFocusJSWithSelectorFallback() {
        translator.bindSelector("button.go", toIdStr: "q3")
        let js = translator.buildFocusJS(idStr: "q3")!
        XCTAssertTrue(js.contains("else{var fb=document.querySelector(\"button.go\");if(fb){fb.focus();"))
    }

    // A selector with a double-quote is jsStr-escaped into the fallback (no literal break).
    func testBuilderEscapesSelectorQuotes() {
        translator.bindSelector("a[title=\"hi\"]", toIdStr: "q9")
        let js = translator.buildFocusJS(idStr: "q9")!
        XCTAssertTrue(js.contains("querySelector(\"a[title=\\\"hi\\\"]\")"), "selector quotes escaped: \(js)")
    }
}
