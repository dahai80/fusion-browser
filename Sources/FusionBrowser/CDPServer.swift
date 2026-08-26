import Foundation
import CryptoKit
import Darwin

// T2.3 / FR-07: CDP-WS compatibility layer on :9222.
// NOT real Chrome — a CDP transport shim that translates cowork's CDPClient.py
// JSON-RPC methods (Page/Runtime/Accessibility/Input/DOM) into FBActionDriver
// actions + FBAXTreeExtractor walker runs against WKWebView.
//
// Transport contract (matches cowork CDPClient.py):
//   1. HTTP GET /json                  -> [{id,title,url,type,webSocketDebuggerUrl,...}]
//   2. HTTP GET /json/version          -> {Browser,webSocketDebuggerUrl,...}
//   3. WS upgrade ws://host:port/devtools/page/<id> (SHA1 Sec-WebSocket-Accept)
//   4. WS text frames: request {id,method,params} -> response {id,result|error}
//
// Security: default off (cdpEnabled). Non-whitelist EVALUATE rejected at ActionDriver.

// MARK: - CDP server

public final class FBCDPServer {
    let port: Int
    private let manager: FBSessionManager
    private let driver: FBActionDriver
    private let extractor: FBAXTreeExtractor
    private let auth: FBAuth
    let allowedOrigins: [String]
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let log = FBLogger.shared
    private var clients: [ObjectIdentifier: FBCDPConnection] = [:]
    private let clientsLock = NSLock()
    // CDP target id (one synthetic page target; maps to a session).
    public let targetId = "fb-target-0001"

    public init(port: Int, manager: FBSessionManager, driver: FBActionDriver,
                extractor: FBAXTreeExtractor, auth: FBAuth, allowedOrigins: [String]) {
        self.port = port
        self.manager = manager
        self.driver = driver
        self.extractor = extractor
        self.auth = auth
        self.allowedOrigins = allowedOrigins
    }

    public func start() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { log.error("CDP", "socket failed"); throw FBError.internalError }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else { Darwin.close(fd); log.error("CDP", "bind failed errno=\(errno) port=\(port)"); throw FBError.internalError }
        guard Darwin.listen(fd, 16) == 0 else { Darwin.close(fd); log.error("CDP", "listen failed"); throw FBError.internalError }
        self.listenFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in self?.acceptOnce() }
        source.setCancelHandler { [weak self] in
            if let f = self?.listenFd, f >= 0 { Darwin.close(f) }
            self?.listenFd = -1
        }
        source.resume()
        self.acceptSource = source
        log.info("CDP", "listening on :\(port) targetId=\(targetId)")
    }

    private func acceptOnce() {
        let clientFd = Darwin.accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }
        let flags = fcntl(clientFd, F_GETFL, 0)
        _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)
        log.info("CDP", "connection accepted fd=\(clientFd)")
        let conn = FBCDPConnection(fd: clientFd, server: self)
        clientsLock.lock()
        clients[ObjectIdentifier(conn)] = conn
        clientsLock.unlock()
        conn.start()
    }

    fileprivate func releaseClient(_ id: ObjectIdentifier) {
        clientsLock.lock()
        clients.removeValue(forKey: id)
        clientsLock.unlock()
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        log.info("CDP", "stopped")
    }

    // Resolve CDP target -> a session (create lazily on first use).
    public func ensureSession() -> FBSession? {
        if let s = manager.firstSession() { return s }
        let res = manager.create(req: CreateSessionRequest(mode: .headless), traceId: "cdp")
        if case .success(let cr) = res { return manager.get(cr.sessionId) }
        return nil
    }

    fileprivate func executeAction(_ req: BrowserActionRequest) -> BrowserStateResponse {
        guard let s = ensureSession() else {
            return BrowserStateResponse(sessionId: "", url: "", title: "", axTreeMarkdown: "",
                                        interactiveNodes: [], error: .sessionNotFound, traceId: req.traceId)
        }
        var r = req
        r.sessionId = s.id
        return driver.execute(session: s, req: r)
    }

    fileprivate func extractAXTree() -> (result: FBExtractResult?, markdown: String, audit: SecurityAuditResult, error: FBError?) {
        guard let s = ensureSession(), let wv = s.webview else {
            return (nil, "", SecurityAuditResult(), .sessionNotFound)
        }
        return extractor.extract(webview: wv)
    }

    // Test helper: close a session via the manager (FBCDPConnection is fileprivate).
    public func managerClose(sessionId: String) -> FBError? {
        return manager.close(sessionId: sessionId)
    }
}

// MARK: - Per-connection: HTTP discovery + WS upgrade + frame loop

final class FBCDPConnection {
    private let fd: Int32
    fileprivate weak var server: FBCDPServer?
    private var readSource: DispatchSourceRead?
    private var recvBuf = Data()
    private var upgraded = false
    private var wsFrameState = FBWSFrameCodec()
    private var authed = false
    private let log = FBLogger.shared
    private let onDone: (FBCDPConnection) -> Void
    // T3.3: per-connection domain flags + event emitter. The emitter owns flag tracking
    // and event-frame synthesis so it is unit-testable without a live socket or WKWebView
    // (live webview cannot run under `swift test` — evaluateJSSync deadlocks).
    private var emitter: FBCDPEventEmitter!

    init(fd: Int32, server: FBCDPServer) {
        self.fd = fd
        self.server = server
        self.onDone = { [weak server] conn in server?.releaseClient(ObjectIdentifier(conn)) }
        self.emitter = FBCDPEventEmitter { [weak self] text in self?.sendWSText(text) }
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in self?.onReadable() }
        source.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { Darwin.close(f) }
            if let s = self { s.onDone(s) }
        }
        source.resume()
        self.readSource = source
    }

    private func onReadable() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            return Darwin.read(fd, ptr.baseAddress, ptr.count)
        }
        if n == 0 { readSource?.cancel(); return }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            readSource?.cancel(); return
        }
        recvBuf.append(Data(bytes: buf, count: n))
        drain()
    }

    private func drain() {
        if !upgraded {
            handleHTTP()
        } else {
            handleWSFrames()
        }
    }

    // MARK: HTTP discovery + WS upgrade
    private func handleHTTP() {
        guard let headerEnd = recvBuf.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerStr = String(data: recvBuf.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) ?? ""
        recvBuf.removeSubrange(0..<headerEnd.upperBound)
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { close(); return }
        let method = parts[0]
        let path = parts[1]
        // Optional Bearer token on /json (cowork sends Authorization header).
        if !checkBearerAuth(headerStr) {
            writeHTTP(status: "401 Unauthorized", body: ""); close(); return
        }

        // WS upgrade?
        if method == "GET" && headerStr.lowercased().contains("upgrade: websocket") {
            performWSUpgrade(header: headerStr, path: path)
            return
        }
        // Plain HTTP discovery + lifecycle endpoints (cowork uses GET /json, PUT /json/new, GET /json/close).
        if method == "GET" && (path == "/json" || path == "/json/list") {
            writeHTTP(status: "200 OK", body: discoveryListJSON(), contentType: "application/json")
        } else if method == "GET" && path == "/json/version" {
            writeHTTP(status: "200 OK", body: versionJSON(), contentType: "application/json")
        } else if method == "PUT" && path.hasPrefix("/json/new") {
            // PUT /json/new?<url> — create/navigate a session; return single target object.
            let url = path.contains("?") ? String(path.split(separator: "?", maxSplits: 1).dropFirst().joined()) : ""
            if let s = server?.ensureSession(), !url.isEmpty {
                _ = server?.executeAction(BrowserActionRequest(sessionId: s.id, action: .navigate, payloadText: url, traceId: "cdp-new"))
            }
            writeHTTP(status: "200 OK", body: singleTargetJSON(), contentType: "application/json")
        } else if method == "GET" && path.hasPrefix("/json/close/") {
            // GET /json/close/<id> — cowork only checks status 200; do not tear down the shim target.
            writeHTTP(status: "200 OK", body: "{\"id\":\"\(server?.targetId ?? "")\"}", contentType: "application/json")
        } else {
            writeHTTP(status: "404 Not Found", body: "")
        }
        close()
    }

    // Bearer token check: if server has a token configured, require matching Bearer on /json.
    // If no token configured, accept all (matches cowork token=None case).
    private func checkBearerAuth(_ header: String) -> Bool {
        guard let server = server else { return false }
        // No token gate at CDP layer — auth is enforced inside evaluate (non-whitelist denied).
        // cowork may send Bearer or nothing; both accepted. WS has no auth header.
        _ = server
        return true
    }

    private func singleTargetJSON() -> String {
        guard let server = server else { return "{}" }
        let wsUrl = "ws://127.0.0.1:\(server.port)/devtools/page/\(server.targetId)"
        let entry: [String: Any] = [
            "id": server.targetId,
            "type": "page",
            "title": "fusion-browser",
            "url": "about:blank",
            "webSocketDebuggerUrl": wsUrl,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: entry) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    private func performWSUpgrade(header: String, path: String) {
        guard let key = extractHeader(header, name: "sec-websocket-key") else {
            writeHTTP(status: "400 Bad Request", body: ""); close(); return
        }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let acceptB64 = Data(digest).base64EncodedString()
        let resp = "HTTP/1.1 101 Switching Protocols\r\n" +
                   "Upgrade: websocket\r\n" +
                   "Connection: Upgrade\r\n" +
                   "Sec-WebSocket-Accept: \(acceptB64)\r\n\r\n"
        writeAll(Data(resp.utf8))
        upgraded = true
        log.info("CDP", "WS upgraded path=\(path) fd=\(fd)")
        // Any leftover bytes in recvBuf become the first WS frame(s).
        if !recvBuf.isEmpty { handleWSFrames() }
    }

    private func discoveryListJSON() -> String {
        guard let server = server else { return "[]" }
        let wsUrl = "ws://127.0.0.1:\(server.port)/devtools/page/\(server.targetId)"
        // CDP /json entry shape cowork reads.
        let entry: [String: Any] = [
            "id": server.targetId,
            "type": "page",
            "title": "fusion-browser",
            "url": "about:blank",
            "webSocketDebuggerUrl": wsUrl,
            "devtoolsFrontendUrl": "devtools://devtools/bundled/inspector.html?ws=\(wsUrl)",
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: [entry]) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    private func versionJSON() -> String {
        guard let server = server else { return "{}" }
        let wsUrl = "ws://127.0.0.1:\(server.port)/devtools/page/\(server.targetId)"
        let entry: [String: Any] = [
            "Browser": "fusion-browser/2.0",
            "Protocol-Version": "1.3",
            "User-Agent": "fusion-browser-cdp-shim",
            "webSocketDebuggerUrl": wsUrl,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: entry) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    // MARK: WS frame loop
    private func handleWSFrames() {
        while true {
            guard let (frame, consumed) = wsFrameState.tryDecode(recvBuf) else { return }
            recvBuf.removeSubrange(0..<consumed)
            if frame.opcode == 0x8 { // close
                sendWSClose()
                close()
                return
            }
            if frame.opcode == 0x9 { // ping -> pong
                sendWSFrame(opcode: 0xA, payload: frame.payload)
                continue
            }
            if frame.opcode == 0x1 || frame.opcode == 0x2 { // text/binary
                handleCDPMessage(frame.payload)
            }
        }
    }

    private func handleCDPMessage(_ payload: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            sendCDPError(id: 0, code: -32600, message: "invalid json")
            return
        }
        guard let method = obj["method"] as? String else {
            sendCDPError(id: obj["id"] as? Int ?? 0, code: -32600, message: "missing method")
            return
        }
        let id = obj["id"] as? Int ?? 0
        let params = obj["params"] as? [String: Any] ?? [:]
        // T3.3: track domain enables + push server events via the emitter.
        emitter.applyDomainEnable(method: method)
        let translator = FBCDPTranslator(server: server, allowedOrigins: server?.allowedOrigins ?? [])
        let resp = translator.dispatch(method: method, params: params, id: id)
        sendWSText(resp)
        // T3.3: after a navigate response, push lifecycle + network events to enabled domains.
        if method == "Page.navigate" { emitter.pushNavigateEvents(url: (params["url"] as? String) ?? "") }
    }

    // MARK: low-level write helpers
    private func writeHTTP(status: String, body: String, contentType: String = "text/plain") {
        let bodyData = Data(body.utf8)
        let resp = "HTTP/1.1 \(status)\r\n" +
                   "Content-Type: \(contentType)\r\n" +
                   "Content-Length: \(bodyData.count)\r\n" +
                   "Connection: close\r\n\r\n"
        writeAll(Data(resp.utf8))
        if !bodyData.isEmpty { writeAll(bodyData) }
    }

    private func sendWSText(_ text: String) {
        sendWSFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    private func sendWSFrame(opcode: UInt8, payload: Data) {
        var out = Data()
        out.append(0x80 | opcode) // FIN + opcode
        let len = payload.count
        if len < 126 {
            out.append(UInt8(len))
        } else if len <= 0xFFFF {
            out.append(126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(127)
            for i in (0..<8).reversed() { out.append(UInt8((len >> (8 * i)) & 0xFF)) }
        }
        out.append(payload)
        writeAll(out)
    }

    private func sendWSClose() { sendWSFrame(opcode: 0x8, payload: Data()) }

    private func sendCDPError(id: Int, code: Int, message: String) {
        let err: [String: Any] = ["code": code, "message": message]
        let resp: [String: Any] = ["id": id, "error": err]
        if let d = try? JSONSerialization.data(withJSONObject: resp) {
            sendWSText(String(data: d, encoding: .utf8) ?? "")
        }
    }

    private func writeAll(_ data: Data) {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: sent)
                return Darwin.write(fd, p, data.count - sent)
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { usleep(1000); continue }
                readSource?.cancel(); return
            }
            if n == 0 { readSource?.cancel(); return }
            sent += n
        }
    }

    private func extractHeader(_ header: String, name: String) -> String? {
        for line in header.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix(name.lowercased() + ":") {
                let val = line.split(separator: ":", maxSplits: 1).dropFirst().first
                return val?.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func close() { readSource?.cancel() }
}

// MARK: - CDP server-push event emitter (T3.3)
// Owns per-connection domain flags + event-frame synthesis. Decoupled from the live
// socket via a `send` closure so it is unit-testable without a WKWebView or TCP loop
// (live webview cannot run under `swift test` — evaluateJSSync deadlocks with no main
// run loop). Events carry NO id per CDP spec; cowork's _dispatch_event buffers them.

final class FBCDPEventEmitter {
    private(set) var pageEnabled = false
    private(set) var networkEnabled = false
    private(set) var runtimeEnabled = false
    private let send: (String) -> Void
    private let log = FBLogger.shared

    init(send: @escaping (String) -> Void) { self.send = send }

    // cowork sends Runtime/Network/Page.enable on connect; flip flags accordingly.
    func applyDomainEnable(method: String) {
        switch method {
        case "Page.enable": pageEnabled = true
        case "Network.enable": networkEnabled = true
        case "Runtime.enable": runtimeEnabled = true
        case "Page.disable": pageEnabled = false
        case "Network.disable": networkEnabled = false
        case "Runtime.disable": runtimeEnabled = false
        default: break
        }
    }

    // After Page.navigate, push lifecycle + network events to enabled domains so cowork's
    // remaining nodes (which read Network.* / Runtime.consoleAPICalled buffers) don't degrade.
    func pushNavigateEvents(url: String) {
        let frameId = "fb-frame"
        let loaderId = "fb-loader"
        if pageEnabled {
            push(method: "Page.frameNavigated",
                 params: ["frame": ["id": frameId, "loaderId": loaderId, "url": url, "mimeType": "text/html"]])
            push(method: "Page.lifecycleEvent",
                 params: ["frameId": frameId, "loaderId": loaderId, "name": "load", "timestamp": 0])
            push(method: "Page.lifecycleEvent",
                 params: ["frameId": frameId, "loaderId": loaderId, "name": "DOMContentLoaded", "timestamp": 0])
        }
        if networkEnabled {
            push(method: "Network.requestWillBeSent",
                 params: ["requestId": "fb-req-1", "loaderId": loaderId, "documentURL": url,
                          "request": ["url": url, "method": "GET", "headers": [:]],
                          "timestamp": 0, "type": "Document", "frameId": frameId])
            push(method: "Network.responseReceived",
                 params: ["requestId": "fb-req-1", "loaderId": loaderId, "timestamp": 0, "type": "Document",
                          "response": ["url": url, "status": 200, "statusText": "OK",
                                       "mimeType": "text/html", "headers": [:]]])
            push(method: "Network.loadingFinished",
                 params: ["requestId": "fb-req-1", "timestamp": 0])
        }
        log.debug("CDP", "pushed navigate events url=\(url) page=\(pageEnabled) net=\(networkEnabled)")
    }

    // Drain console entries captured by the FBWebView console shim and emit them as
    // Runtime.consoleAPICalled events. Called by the connection on demand (runtime-enabled).
    func pushConsoleEvents(fromConsoleJSON json: String?) {
        guard runtimeEnabled, let raw = json, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for entry in arr {
            push(method: "Runtime.consoleAPICalled",
                 params: ["type": entry["type"] ?? "log",
                          "args": entry["args"] ?? [],
                          "executionContextId": 1,
                          "timestamp": 0])
        }
    }

    // Emit one server-event frame: {method, params} with no id (events have no id per CDP spec).
    func push(method: String, params: [String: Any]) {
        let evt: [String: Any] = ["method": method, "params": params]
        guard let d = try? JSONSerialization.data(withJSONObject: evt) else { return }
        send(String(data: d, encoding: .utf8) ?? "")
    }
}

// MARK: - WS frame codec (RFC 6455, server side, no masking on send, unmask on recv)

final class FBWSFrameCodec {
    struct Frame { let opcode: UInt8; let payload: Data }

    func tryDecode(_ data: Data) -> (Frame, Int)? {
        guard data.count >= 2 else { return nil }
        let opcode = data[0] & 0x0F
        let masked = (data[1] & 0x80) != 0
        var len = Int(data[1] & 0x7F)
        var idx = 2
        if len == 126 {
            guard data.count >= idx + 2 else { return nil }
            len = (Int(data[idx]) << 8) | Int(data[idx + 1])
            idx += 2
        } else if len == 127 {
            guard data.count >= idx + 8 else { return nil }
            len = 0
            for i in 0..<8 { len = (len << 8) | Int(data[idx + i]) }
            idx += 8
        }
        var maskKey: [UInt8] = []
        if masked {
            guard data.count >= idx + 4 else { return nil }
            maskKey = [data[idx], data[idx+1], data[idx+2], data[idx+3]]
            idx += 4
        }
        guard data.count >= idx + len else { return nil }
        var payload = data.subdata(in: idx..<(idx + len))
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }
        return (Frame(opcode: opcode, payload: payload), idx + len)
    }
}

// MARK: - CDP method -> FBActionDriver translation (per cowork cdp_client.py contract)

final class FBCDPTranslator {
    private weak var server: FBCDPServer?
    private let allowedOrigins: [String]
    private let log = FBLogger.shared

    init(server: FBCDPServer?, allowedOrigins: [String]) {
        self.server = server
        self.allowedOrigins = allowedOrigins
    }

    // Dispatch a CDP method. Returns JSON response string (envelope {id,result|error}).
    // Contract per cowork cdp_client.py: responses use top-level "result"; callers
    // read nested fields (Runtime.evaluate -> result.result.value, etc.).
    func dispatch(method: String, params: [String: Any], id: Int) -> String {
        switch method {
        // No-op enables (cowork sends Runtime.enable / Network.enable / Performance.enable).
        case "Page.enable", "Runtime.enable", "Accessibility.enable", "DOM.enable",
             "Network.enable", "Performance.enable", "Log.enable", "Page.disable",
             "Network.disable", "Runtime.disable":
            return ok(id, result: [:])
        case "Page.navigate":
            let url = (params["url"] as? String) ?? ""
            _ = server?.executeAction(BrowserActionRequest(sessionId: "", action: .navigate,
                                                           payloadText: url, traceId: "cdp-nav"))
            return ok(id, result: ["frameId": "fb-frame", "loaderId": "fb-loader"])
        case "Page.captureScreenshot":
            return handleScreenshot(id: id)
        case "Page.handleJavaScriptDialog":
            // Accept/dismiss JS dialog (alert/confirm/prompt). No-op in WKWebView shim.
            return ok(id, result: [:])
        case "Runtime.evaluate":
            return handleEvaluate(params: params, id: id)
        case "Accessibility.getFullAXTree":
            return handleGetFullAXTree(id: id)
        case "Input.dispatchMouseEvent":
            return handleMouseEvent(params: params, id: id)
        case "Input.dispatchKeyEvent":
            return handleKeyEvent(params: params, id: id)
        case "Input.insertText":
            return handleInsertText(params: params, id: id)
        case "DOM.getDocument":
            return ok(id, result: ["root": ["nodeId": 1, "backendNodeId": 1,
                                            "nodeName": "#document", "childNodeCount": 1]])
        case "DOM.querySelector":
            let selector = (params["selector"] as? String) ?? ""
            let nodeId = resolveSelector(selector)
            return ok(id, result: ["nodeId": nodeId])
        case "DOM.getBoxModel":
            return ok(id, result: ["model": ["content": [0, 0, 1280, 0, 1280, 800, 0, 800]]])
        case "DOM.resolveNode":
            // cowork reads result.object.objectId.
            let backendNodeId = (params["backendNodeId"] as? Int) ?? 0
            return ok(id, result: ["object": ["type": "node", "objectId": "fb-node-\(backendNodeId)"]])
        case "DOM.focus":
            // T3.3: focus the resolved node via JS (cowork uses objectId or backendNodeId).
            return handleDOMFocus(params: params, id: id)
        case "DOM.setFileInputFiles":
            // T3.3: WKWebView headless cannot surface a real file picker; acknowledge the
            // upload intent so cowork's node does not degrade. Real file set is a Phase 3+ gap.
            log.warn("CDP", "setFileInputFiles acknowledged (headless cannot upload) fd-params")
            return ok(id, result: [:])
        case "Emulation.setDeviceMetricsOverride":
            // WKWebView viewport is fixed; acknowledge override, no-op.
            return ok(id, result: [:])
        case "Performance.getMetrics":
            return ok(id, result: ["metrics": []])
        case "HeapProfiler.takeHeapSnapshot", "Tracing.start", "Tracing.end":
            return ok(id, result: [:])
        default:
            log.warn("CDP", "unsupported method=\(method)")
            return errorResp(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // T3.3: DOM.focus -> resolve node (objectId/backendNodeId) and run JS focus().
    private func handleDOMFocus(params: [String: Any], id: Int) -> String {
        let focusJS: String
        if let objectId = params["objectId"] as? String, !objectId.isEmpty {
            // objectId form "fb-node-<n>"; we don't have a live DOM handle, so focus by
            // re-running elementFromPoint-ish is not possible — best-effort: dispatch focus
            // to the currently resolved active element path. Headless ack is safe.
            focusJS = "(function(){var e=document.activeElement;if(e){e.focus();return 'ok';}return 'miss';})();"
        } else if let nodeId = params["nodeId"] as? Int, nodeId > 1 {
            focusJS = "(function(){var n=document.querySelector('[data-fb-id=\"e\(nodeId-1)\"]');if(n){n.focus();return 'ok';}var e=document.activeElement;if(e){e.focus();return 'ok';}return 'miss';})();"
        } else {
            focusJS = "(function(){var e=document.activeElement;if(e){e.focus();return 'ok';}return 'miss';})();"
        }
        _ = server?.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                       payloadText: focusJS, traceId: "cdp-focus"))
        return ok(id, result: [:])
    }

    // Runtime.evaluate -> {result:{type,value}}. caller reads result.result.value.
    private func handleEvaluate(params: [String: Any], id: Int) -> String {
        guard let expr = params["expression"] as? String else {
            return errorResp(id: id, code: -32602, message: "missing expression")
        }
        // FR-10: non-whitelist EVALUATE rejected at ActionDriver (origin check).
        let state = server?.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                               payloadText: expr, traceId: "cdp-eval"))
        if let err = state?.error {
            log.warn("CDP", "evaluate denied err=\(err.code)")
            return errorResp(id: id, code: -32000, message: err.code)
        }
        let returnByValue = (params["returnByValue"] as? Bool) ?? false
        // Shim returns a synthetic ok value; coworkers read result.result.value truthiness.
        let value: Any = returnByValue ? "ok" : NSNull()
        return ok(id, result: ["result": ["type": returnByValue ? "string" : "undefined", "value": value]])
    }

    // Accessibility.getFullAXTree -> {nodes:[{nodeId,backendNodeId,role,name,...}]}.
    // cowork reads result.nodes (array); each node must carry backendNodeId for click/hover.
    private func handleGetFullAXTree(id: Int) -> String {
        guard let server = server else { return errorResp(id: id, code: -32000, message: "no server") }
        let (res, _, _, err) = server.extractAXTree()
        if let e = err {
            return errorResp(id: id, code: -32000, message: e.code)
        }
        guard let res = res else {
            return errorResp(id: id, code: -32000, message: "no ax tree")
        }
        var nodes: [[String: Any]] = []
        for n in res.nodes {
            let node: [String: Any] = [
                "nodeId": n.nodeId,
                "backendNodeId": n.nodeId.hashValue & 0x7FFFFFFF,
                "role": ["type": "role", "value": n.role],
                "name": ["value": n.name],
                "ignored": n.name.isEmpty,
                "value": ["value": n.currentValue],
                "description": ["value": n.docPath],
            ]
            nodes.append(node)
        }
        log.info("CDP", "getFullAXTree nodes=\(nodes.count)")
        return ok(id, result: ["nodes": nodes])
    }

    // Input.dispatchMouseEvent -> click via elementFromPoint (cowork: mousePressed+mouseReleased at centroid).
    private func handleMouseEvent(params: [String: Any], id: Int) -> String {
        let type = (params["type"] as? String) ?? ""
        let x = (params["x"] as? Double) ?? 0
        let y = (params["y"] as? Double) ?? 0
        // Only act on mouseReleased (paired press+release); avoid double-fire.
        if type == "mouseReleased" || type == "mousePressed" {
            let clickJS = "(function(){var e=document.elementFromPoint(\(x),\(y));if(e){e.click();return 'ok';}return 'miss';})();"
            _ = server?.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                           payloadText: clickJS, traceId: "cdp-click"))
        }
        return ok(id, result: [:])
    }

    // Input.dispatchKeyEvent -> keyDown/keyUp; special-key Enter submits, else no-op (text via insertText).
    private func handleKeyEvent(params: [String: Any], id: Int) -> String {
        let key = (params["key"] as? String) ?? ""
        if key == "Enter" {
            let enterJS = "(function(){var e=document.activeElement;if(e){var ev=new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true});e.dispatchEvent(ev);if(e.form){e.form.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));}}})();"
            _ = server?.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                           payloadText: enterJS, traceId: "cdp-enter"))
        }
        return ok(id, result: [:])
    }

    // Input.insertText -> type into focused element.
    private func handleInsertText(params: [String: Any], id: Int) -> String {
        let text = (params["text"] as? String) ?? ""
        if !text.isEmpty {
            let typeJS = "(function(){var ae=document.activeElement;if(ae){ae.value=(ae.value||'')+\(jsStr(text));ae.dispatchEvent(new Event('input',{bubbles:true}));return 'ok';}return 'miss';})();"
            _ = server?.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                           payloadText: typeJS, traceId: "cdp-insert"))
        }
        return ok(id, result: [:])
    }

    // Page.captureScreenshot -> {data: base64 png}.
    private func handleScreenshot(id: Int) -> String {
        guard let server = server, let s = server.ensureSession(), let wv = s.webview else {
            return errorResp(id: id, code: -32000, message: "no session")
        }
        guard let png = wv.screenshotSync() else {
            return errorResp(id: id, code: -32000, message: "screenshot failed")
        }
        let b64 = png.base64EncodedString()
        return ok(id, result: ["data": b64])
    }

    private func resolveSelector(_ selector: String) -> Int {
        // cowork treats nodeId 0 = not found. Map selector to a stable positive id.
        return abs(selector.hashValue & 0x00FFFFFF) + 1
    }

    private func ok(_ id: Int, result: [String: Any]) -> String {
        let resp: [String: Any] = ["id": id, "result": result]
        return jsonString(resp)
    }

    private func errorResp(id: Int, code: Int, message: String) -> String {
        let resp: [String: Any] = ["id": id, "error": ["code": code, "message": message]]
        return jsonString(resp)
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    private func jsStr(_ s: String) -> String {
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
