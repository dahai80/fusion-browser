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
        XCTAssertEqual(frame.opcode, 0x1)
        XCTAssertEqual(String(data: frame.payload, encoding: .utf8), "hello cdp")
    }

    func testDecodeUnmaskedServerFrame() {
        let (frame, _) = codec.tryDecode(unmaskedFrame("{\"id\":1,\"result\":{}}"))!
        XCTAssertEqual(frame.opcode, 0x1)
        XCTAssertEqual(String(data: frame.payload, encoding: .utf8), "{\"id\":1,\"result\":{}}")
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
        XCTAssertEqual(frame.opcode, 0x1)
        XCTAssertEqual(frame.payload.count, 200)
        XCTAssertEqual(consumed, out.count)
        XCTAssertEqual(String(data: frame.payload, encoding: .utf8)?.count, 200)
    }

    func testDecodeCloseAndPingOpcodes() {
        var close = Data([0x88, 0x80])
        close.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        let (cf, _) = codec.tryDecode(close)!
        XCTAssertEqual(cf.opcode, 0x8)
        var ping = Data([0x89, 0x82])
        ping.append(contentsOf: [0x05, 0x06, 0x07, 0x08, 0xAA, 0xBB])
        for i in 4..<ping.count { ping[i] ^= [0x05, 0x06, 0x07, 0x08][(i - 4) % 4] }
        let (pf, _) = codec.tryDecode(ping)!
        XCTAssertEqual(pf.opcode, 0x9)
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
        let r = dispatch("DOM.getDocument")
        let root = (r["result"] as? [String: Any])?["root"] as? [String: Any]
        XCTAssertEqual(root?["nodeId"] as? Int, 1)
        XCTAssertEqual(root?["nodeName"] as? String, "#document")
    }

    func testDOMQuerySelectorShape() {
        let r = dispatch("DOM.querySelector", ["selector": "#login-btn"])
        XCTAssertGreaterThan((r["result"] as? [String: Any])?["nodeId"] as? Int ?? -1, 0)
    }

    func testDOMGetBoxModelShape() {
        let r = dispatch("DOM.getBoxModel")
        let content = (r["result"] as? [String: Any])?["model"] as? [String: Any]
        XCTAssertEqual((content?["content"] as? [Any])?.count, 8)
    }

    func testDOMResolveNodeShape() {
        let r = dispatch("DOM.resolveNode", ["backendNodeId": 42])
        let obj = (r["result"] as? [String: Any])?["object"] as? [String: Any]
        XCTAssertEqual(obj?["objectId"] as? String, "fb-node-42")
        XCTAssertEqual(obj?["type"] as? String, "node")
    }

    func testPerformanceMetricsEmpty() {
        let r = dispatch("Performance.getMetrics")
        XCTAssertTrue(((r["result"] as? [String: Any])?["metrics"] as? [Any])?.isEmpty ?? false)
    }

    func testPageNavigateReturnsFrameId() {
        let r = dispatch("Page.navigate", ["url": "https://example.com"])
        let res = r["result"] as? [String: Any]
        XCTAssertEqual(res?["frameId"] as? String, "fb-frame")
        XCTAssertEqual(res?["loaderId"] as? String, "fb-loader")
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

    // T3.3: DOM.focus / DOM.setFileInputFiles exist and return empty result (no -32601),
    // so cowork's remaining nodes don't degrade on unknown method.
    func testDOMFocusReturnsEmptyResult() {
        let r = dispatch("DOM.focus", ["objectId": "fb-node-42"], id: 3)
        XCTAssertEqual(r["id"] as? Int, 3)
        XCTAssertNil(r["error"])
        XCTAssertTrue((r["result"] as? [String: Any])?.isEmpty ?? false)
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

    // Acceptance: after Page.enable + Network.enable + navigate, push frameNavigated +
    // lifecycleEvent + Network.requestWillBeSent/responseReceived/loadingFinished.
    func testNavigatePushesLifecycleAndNetworkEvents() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Page.enable")
        em.applyDomainEnable(method: "Network.enable")
        XCTAssertTrue(em.pageEnabled)
        XCTAssertTrue(em.networkEnabled)
        em.pushNavigateEvents(url: "https://example.com")
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

    // Acceptance: WITHOUT domain enable, navigate pushes no events (gated by flags).
    func testNoDomainEnableMeansNoEvents() {
        let (em, box) = makeEmitter()
        // No enables — straight navigate.
        em.pushNavigateEvents(url: "https://example.com")
        XCTAssertTrue(box.frames.isEmpty, "events pushed without domain enable: \(box.frames)")
    }

    // Only Page enabled -> only Page events, no Network events.
    func testPageOnlyPushesNoNetworkEvents() {
        let (em, box) = makeEmitter()
        em.applyDomainEnable(method: "Page.enable")
        em.pushNavigateEvents(url: "https://example.com")
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
                                maxTotalMemoryMB: 300, maxWebContentProcesses: 2)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: allowedOrigins)
        let extractor = FBAXTreeExtractor()
        let sanitizer = FBSanitizer()
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: auth,
                                    allowedOrigins: allowedOrigins, extractor: extractor, sanitizer: sanitizer)
        let server = FBCDPServer(port: 0, manager: mgr, driver: driver, extractor: extractor,
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
                                maxTotalMemoryMB: 300, maxWebContentProcesses: 2)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: [])
        let extractor = FBAXTreeExtractor()
        let sanitizer = FBSanitizer()
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: auth,
                                    allowedOrigins: [], extractor: extractor, sanitizer: sanitizer)
        return FBCDPServer(port: port, manager: mgr, driver: driver, extractor: extractor,
                           auth: auth, allowedOrigins: [])
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
        sendAll(fd: fd, "GET /json HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
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
        sendAll(fd: fd, "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        let raw = recvUntil(fd: fd, marker: Data("}".utf8))
        let body = String(data: raw, encoding: .utf8) ?? ""
        let jsonStart = body.range(of: "{")?.lowerBound ?? body.endIndex
        let obj = try JSONSerialization.jsonObject(with: Data(body[jsonStart...].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["Browser"] as? String, "fusion-browser/2.0")
        XCTAssertTrue((obj?["webSocketDebuggerUrl"] as? String ?? "").contains("/devtools/page/"))
    }

    func testWSUpgradeHandshake() throws {
        let port = freePort()
        let server = makeServer(port: port)
        try server.start()
        defer { server.stop() }
        usleep(100_000)

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, "GET /devtools/page/\(server.targetId) HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n")
        let raw = recvUntil(fd: fd, marker: Data("\r\n\r\n".utf8))
        let resp = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(resp.contains("HTTP/1.1 101"), "no 101: \(resp.prefix(120))")
        XCTAssertTrue(resp.contains("Sec-WebSocket-Accept: \(expected)"), "accept mismatch: \(resp.prefix(200))")
    }

    func testWSFrameRoundTripNoOp() {
        let port = freePort()
        guard let server = try? { () -> FBCDPServer in
            let s = makeServer(port: port)
            try s.start()
            return s
        }() else { XCTFail("server start failed"); return }
        defer { server.stop() }
        usleep(100_000)

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let fd = connect(port: port)
        defer { Darwin.close(fd) }
        sendAll(fd: fd, "GET /devtools/page/\(server.targetId) HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
                        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n")
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

        // Server echoes an unmasked text frame; read until a complete frame is decodable.
        let respData = recvUntil(fd: fd, marker: Data("}".utf8), deadlineSec: 5)
        let (decoded, _) = FBWSFrameCodec().tryDecode(respData) ?? (nil, 0)
        XCTAssertEqual(decoded?.opcode, 0x1)
        let respStr = String(data: decoded?.payload ?? Data(), encoding: .utf8) ?? ""
        let r = respStr.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        XCTAssertEqual(r["id"] as? Int, 1)
        XCTAssertTrue((r["result"] as? [String: Any])?.isEmpty ?? false)
        XCTAssertNil(r["error"])
    }
}
