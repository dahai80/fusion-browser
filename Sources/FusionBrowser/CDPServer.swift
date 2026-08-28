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
    private let auth: FBAuth
    let allowedOrigins: [String]
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let log = FBLogger.shared
    private var clients: [ObjectIdentifier: FBCDPConnection] = [:]
    private let clientsLock = NSLock()
    // P-4: cap concurrent CDP connections so a connection flood can't exhaust memory.
    fileprivate let maxConnections = 8
    // H-5: the caps granted to the authenticated WS connection. Set on WS upgrade from
    // verifyBearer's return; executeAction threads them to the driver. Guarded by capsLock
    // (set on the WS handshake queue, read on the dispatch queue). Empty until first upgrade
    // -> executeAction fails closed (no caps -> every action denied) until a client auths.
    fileprivate private(set) var authedCaps: FBCapabilities = []
    private let capsLock = NSLock()
    // CDP target id (one synthetic page target; maps to a session).
    public let targetId = "fb-target-0001"

    public init(port: Int, manager: FBSessionManager, driver: FBActionDriver,
                auth: FBAuth, allowedOrigins: [String]) {
        self.port = port
        self.manager = manager
        self.driver = driver
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
        // F-1: bind loopback only (127.0.0.1), never INADDR_ANY/0.0.0.0. CDP is a local
        // debug shim; binding all interfaces exposes a zero-auth RCE surface to the LAN.
        // sin_addr.s_addr is in network byte order (big-endian). 0x7F000001 is 127.0.0.1
        // in host order; .bigEndian swaps to the on-wire big-endian representation.
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else { Darwin.close(fd); log.error("CDP", "bind failed errno=\(errno) port=\(port)"); throw FBError.internalError }
        // P-4: raise backlog from 16 to 128 so burst connections don't drop SYN under load.
        guard Darwin.listen(fd, 128) == 0 else { Darwin.close(fd); log.error("CDP", "listen failed"); throw FBError.internalError }
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
        // P-4: enforce per-server connection cap. Reject excess fds before allocating a
        // connection + read buffer; protects against connection-flood memory exhaustion.
        clientsLock.lock()
        if clients.count >= maxConnections {
            clientsLock.unlock()
            Darwin.close(clientFd)
            log.warn("CDP", "connection rejected fd=\(clientFd): maxConnections=\(maxConnections) reached")
            return
        }
        clientsLock.unlock()
        let flags = fcntl(clientFd, F_GETFL, 0)
        _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)
        log.info("CDP", "connection accepted fd=\(clientFd)")
        let conn = FBCDPConnection(fd: clientFd, server: self)
        clientsLock.lock()
        clients[ObjectIdentifier(conn)] = conn
        clientsLock.unlock()
        conn.start()
    }

    // F-2/H-5: verify a Bearer token against the server's FBAuth AND surface the granted
    // capabilities. Fail-closed — no token configured denies all (PRD FR-10/NFR-S3: CDP
    // entry must be authed). The old form returned a bare Bool and DISCARDED the caps, so
    // CDP auth degraded to binary valid/invalid with no per-method enforcement — any valid
    // token drove the full CDP surface (navigate/click/type/evaluate/screenshot). Now the
    // caller (WS upgrade) stores the caps on the server; executeAction threads them to the
    // driver so a scoped token is enforced at every CDP method, not just EVALUATE.
    fileprivate func verifyBearer(_ token: String?) -> FBCapabilities? {
        return auth.authenticate(token: token)
    }

    // F-3: structured origin check shared with the EVALUATE gate (F-7). Fail-closed:
    // empty allowedOrigins denies.
    fileprivate func isOriginAllowed(_ origin: String) -> Bool {
        return auth.isOriginAllowed(origin, allowedOrigins: allowedOrigins)
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

    // H-5: store the caps granted at WS upgrade so executeAction can enforce them per CDP
    // method. Called once per connection on a successful handshake.
    fileprivate func setAuthedCaps(_ caps: FBCapabilities) {
        capsLock.lock(); authedCaps = caps; capsLock.unlock()
        log.info("CDP", "authed caps set raw=\(caps.rawValue)")
    }
    fileprivate func currentCaps() -> FBCapabilities {
        capsLock.lock(); let c = authedCaps; capsLock.unlock(); return c
    }

    fileprivate func executeAction(_ req: BrowserActionRequest) -> BrowserStateResponse {
        guard let s = ensureSession() else {
            return BrowserStateResponse(sessionId: "", url: "", title: "", axTreeMarkdown: "",
                                        interactiveNodes: [], error: .sessionNotFound, traceId: req.traceId)
        }
        var r = req
        r.sessionId = s.id
        // H-5: pass the connection's actual caps to the driver (authoritative per-action gate).
        // Empty caps (no client authed yet, or a scoped token) -> the driver denies the action.
        return driver.execute(session: s, req: r, caps: currentCaps())
    }

    fileprivate func extractAXTree() -> (result: FBExtractResult?, markdown: String, audit: SecurityAuditResult, error: FBError?) {
        guard let s = ensureSession(), !s.isClosing, let wv = s.webview else {
            return (nil, "", SecurityAuditResult(), .sessionNotFound)
        }
        // H-1: route through THIS session's extractor (per-session mapping isolation).
        return s.extractor.extract(webview: wv)
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
    // E-8: ONE persistent translator per connection. The translator owns the DOM
    // identity registry (intToIdStr / objectIdToIdStr / idStrToSelector); a fresh
    // translator per message would wipe the registry between getFullAXTree and the
    // later resolveNode/focus/getBoxModel, breaking both cowork flows. Created lazily
    // at WS upgrade (server + allowlist are known then), reused for every frame.
    private var translator: FBCDPTranslator!

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
        // F-5: cap the receive buffer so a malicious peer can't drive unbounded growth.
        // Pre-upgrade HTTP headers cap at 64KiB (no legitimate header block is larger);
        // post-upgrade WS messages are bounded by FBWSFrameCodec.maxPayloadBytes (10MiB).
        let cap = upgraded ? FBWSFrameCodec.maxPayloadBytes + 1024 : 64 * 1024
        if recvBuf.count > cap {
            log.warn("CDP", "recvBuf over cap (\(cap)) fd=\(fd), closing")
            close()
            return
        }
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
        // Optional Bearer token on /json (cowork sends Authorization header). Discovery
        // executes no actions, so caps need not be stored here (stored on WS upgrade).
        if checkBearerAuth(headerStr) == nil {
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
            // E-15: same navigate-origin gate as Page.navigate (R-16). An empty allowlist is
            // fail-closed for http(s) origins; local schemes (about:/data:) are allowed.
            if !url.isEmpty, let navOrigin = originOfConnUrl(url), !navOrigin.isEmpty {
                guard server?.isOriginAllowed(navOrigin) ?? false else {
                    log.warn("CDP", "PUT /json/new navigate denied origin=\(navOrigin) fd=\(fd)")
                    writeHTTP(status: "403 Forbidden", body: "navigate_denied"); close(); return
                }
            }
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

    // F-2/H-5: Bearer token check on /json + WS upgrade — fail-closed, returns the granted
    // caps (nil = rejected). If the server has a token configured (authToken), the request
    // MUST carry a matching `Authorization: Bearer <token>`. No token configured denies all
    // (PRD FR-10/NFR-S3 dual-entry auth). On success the caps are stored on the server so
    // executeAction enforces them per CDP method (the old bare-Bool form discarded caps and
    // let any valid token drive the full surface).
    private func checkBearerAuth(_ header: String) -> FBCapabilities? {
        guard let server = server else { return nil }
        let bearer = extractBearer(header)
        guard let caps = server.verifyBearer(bearer) else {
            log.warn("CDP", "bearer auth rejected fd=\(fd)")
            return nil
        }
        return caps
    }

    // Extract `Authorization: Bearer <token>` value (returns the bare token, or nil).
    private func extractBearer(_ header: String) -> String? {
        guard let raw = extractHeader(header, name: "authorization") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return nil }
        let token = String(trimmed.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    // E-15: extract the origin (scheme://host[:port]) of a URL for the PUT /json/new
    // navigate gate. Mirrors FBCDPTranslator.originOfUrl (private there). Returns nil for
    // local schemes (data:/about:/blob:/javascript:/file:) which navigate freely, "" for
    // unparseable input, "scheme://host[:port]" otherwise.
    private func originOfConnUrl(_ url: String) -> String? {
        let lower = url.lowercased()
        for local in ["data:", "about:", "blob:", "javascript:", "file:"] {
            if lower.hasPrefix(local) { return nil }
        }
        guard let comps = URLComponents(string: url),
              let scheme = comps.scheme, let host = comps.host, !host.isEmpty else {
            return ""
        }
        if let port = comps.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
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
        // F-2/H-5: WS upgrade must also pass Bearer auth (fail-closed). A browser can open a
        // raw WS without an Authorization header, so this gate blocks cross-origin browser
        // CSRF even when the page origin itself is allowlisted. The granted caps are stored on
        // the server so executeAction enforces them per CDP method.
        guard let caps = checkBearerAuth(header) else {
            writeHTTP(status: "403 Forbidden", body: "bearer required"); close(); return
        }
        server?.setAuthedCaps(caps)
        // E-15/F-3: reject cross-origin WebSocket upgrades, fail-closed on empty Origin.
        // Browsers permit `new WebSocket()` across origins; without an Origin check any
        // visited webpage can drive the engine. The old code let an EMPTY Origin bypass
        // the check (commented "non-browser client like cowork is allowed"), which gave a
        // token-bearing local attacker (or any client that omits the header) a free pass.
        // Per audit §6 item 13: 空 Origin 不得绕过. isOriginAllowed already denies on an
        // empty allowlist AND on a missing/opaque origin, so a bare delegation is the
        // strict fail-closed gate: a client MUST send an allowlisted Origin to upgrade.
        // (cowork's CDP client omits Origin — it breaks here by design; tracked upstream
        // via the E-15 issue. The UDS path is unaffected.)
        let wsOrigin = extractHeader(header, name: "origin") ?? ""
        guard server?.isOriginAllowed(wsOrigin) ?? false else {
            log.warn("CDP", "WS upgrade origin rejected origin=\(wsOrigin.isEmpty ? "<empty>" : wsOrigin) fd=\(fd)")
            writeHTTP(status: "403 Forbidden", body: "origin not allowed"); close(); return
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
        authed = true
        // E-8: mint the ONE translator for this connection now that upgrade succeeded.
        // It carries the DOM identity registry; reused for every subsequent frame.
        self.translator = FBCDPTranslator(server: server, allowedOrigins: server?.allowedOrigins ?? [])
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
            // tryDecode returns nil only when poisoned or not enough bytes yet — stop and
            // wait for more recv data. A non-nil return ALWAYS carries a `consumed` count
            // (a complete message OR a consumed FIN=0 fragment); strip those bytes and loop.
            guard let (frame, consumed) = wsFrameState.tryDecode(recvBuf) else { return }
            recvBuf.removeSubrange(0..<consumed)
            // frame may be nil = a consumed FIN=0 fragment (still accumulating). Loop to
            // parse the next frame from the buffer; no message to handle yet.
            guard let frame = frame else { continue }
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
        // E-8: reuse the connection's persistent translator so the DOM registry
        // (intToIdStr/objectIdToIdStr/idStrToSelector) survives across messages.
        let resp = translator.dispatch(method: method, params: params, id: id)
        sendWSText(resp)
        // T3.3: after a navigate response, push lifecycle + network events to enabled domains.
        // E-11/Finding 26: pass the real HTTP response captured by FBWebView's decidePolicyFor
        // (executeAction -> wv.navigate blocks to didFinish, so the response is already captured).
        if method == "Page.navigate" {
            let url = (params["url"] as? String) ?? ""
            let respCapture = server?.ensureSession().flatMap { $0.webview?.lastResponse }
            emitter.pushNavigateEvents(url: url, response: respCapture)
            drainConsoleEvents()
        }
        // E-11/Finding 9: a script run via Runtime.evaluate may have console.log'd; drain
        // __fbConsole so cowork's console buffer receives Runtime.consoleAPICalled events.
        if method == "Runtime.evaluate" { drainConsoleEvents() }
    }

    // E-11/Finding 9: drain window.__fbConsole (populated by the WebView.swift console shim)
    // and emit Runtime.consoleAPICalled for each buffered entry. The shim had no reader, so
    // consoleAPICalled never fired. Drained after navigate (scripts ran) + after evaluate.
    private func drainConsoleEvents() {
        guard emitter.runtimeEnabled else { return }
        guard let s = server?.ensureSession(), !s.isClosing, let wv = s.webview else { return }
        let raw = wv.evaluateJSSync("JSON.stringify(window.__fbConsole||[])") as? String
        _ = wv.evaluateJSSync("window.__fbConsole=[]")
        emitter.pushConsoleEvents(fromConsoleJSON: raw)
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
    // E-11/Finding 25: per-navigation loaderId/requestId counter (was constant "fb-loader").
    private var navSeq = 0

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

    // E-11: emit in real-Chrome order (was frameNavigated->load->DOMContentLoaded->Network).
    // Real Chrome: Network.requestWillBeSent -> responseReceived -> loadingFinished, then
    // Page.frameNavigated -> DOMContentLoaded -> load. One synchronous burst after nav
    // completion (executeAction blocks to didFinish; the shim cannot stream during load,
    // cowork buffers raw and tolerates the burst).
    // E-11/Finding 25: loaderId/requestId per-nav (was constants); frameId stable per frame.
    // E-11/Finding 26: responseReceived reports the REAL status captured by FBWebView's
    // decidePolicyFor (was hardcoded 200). status 0 = no response captured (local scheme).
    func pushNavigateEvents(url: String, response: (status: Int, mime: String, headers: [String: String])?) {
        let frameId = "fb-frame"
        navSeq += 1
        let loaderId = "fb-loader-\(navSeq)"
        let reqId = "fb-req-\(navSeq)"
        let status = response?.status ?? 0
        let mime = (response?.mime.isEmpty ?? true) ? "text/html" : response!.mime
        let statusText = (200...299).contains(status) ? "OK" : (status == 0 ? "unknown" : "")
        if networkEnabled {
            push(method: "Network.requestWillBeSent",
                 params: ["requestId": reqId, "loaderId": loaderId, "documentURL": url,
                          "request": ["url": url, "method": "GET", "headers": [:]],
                          "timestamp": 0, "type": "Document", "frameId": frameId])
            push(method: "Network.responseReceived",
                 params: ["requestId": reqId, "loaderId": loaderId, "timestamp": 0, "type": "Document",
                          "response": ["url": url, "status": status, "statusText": statusText,
                                       "mimeType": mime, "headers": response?.headers ?? [:]]])
            push(method: "Network.loadingFinished",
                 params: ["requestId": reqId, "timestamp": 0])
        }
        if pageEnabled {
            push(method: "Page.frameNavigated",
                 params: ["frame": ["id": frameId, "loaderId": loaderId, "url": url, "mimeType": mime]])
            push(method: "Page.lifecycleEvent",
                 params: ["frameId": frameId, "loaderId": loaderId, "name": "DOMContentLoaded", "timestamp": 0])
            push(method: "Page.lifecycleEvent",
                 params: ["frameId": frameId, "loaderId": loaderId, "name": "load", "timestamp": 0])
        }
        log.debug("CDP", "pushed navigate events url=\(url) status=\(status) page=\(pageEnabled) net=\(networkEnabled)")
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

    // Hard cap on a single WS message payload (F-5: prevent unbounded recvBuf growth /
    // OOM). 10MiB per RFC 6455 §5.1 practical limit (CLAUDE.md claims 10MiB; enforced here).
    static let maxPayloadBytes = 10 * 1024 * 1024
    // L-13: fragmentation accumulator. RFC 6455 §5.4: a message may span a FIN=0 start
    // frame (opcode 0x1/0x2) followed by FIN=0 continuation frames (opcode 0x0) and a
    // final FIN=1 continuation frame. We accumulate fragments and only emit the message
    // when the final frame arrives. Control frames (0x8/0x9/0xA) are never fragmented.
    private var fragAccumulator: Data? = nil
    private var fragOpcode: UInt8 = 0
    // F-4/L-12: poison flag — once a malformed frame is seen (negative length, unmasked
    // client frame, oversize), the codec refuses all further decoding until reset.
    private var poisoned = false
    // Direction: when true (default, server-side), client frames MUST be masked (RFC 6455
    // §5.1) and an unmasked frame is a protocol error → poison. When false, the codec
    // decodes server-to-client frames (which MUST be unmasked per §5.1); a masked server
    // frame is the protocol error. The server path uses the default; a client decoding
    // server responses passes requireMask=false.
    private let requireMask: Bool

    init(requireMask: Bool = true) { self.requireMask = requireMask }

    // Decode one frame from the front of `data`. Return value:
    //   nil                       -> poisoned OR not enough bytes yet (caller strips NOTHING,
    //                                waits for more recv data; re-feed the same buffer).
    //   (Frame?, Int)             -> `consumed` bytes were parsed. If the Frame is non-nil it
    //                                is a COMPLETE message (caller strips `consumed`, handles
    //                                the frame). If the Frame is nil, the parsed frame was a
    //                                FIN=0 FRAGMENT (caller strips `consumed`, loops for more
    //                                — the bytes are consumed and must not be re-parsed, or
    //                                the accumulator is overwritten and a fragmented message
    //                                never completes). The caller MUST strip `consumed` on
    //                                EVERY non-nil return, then re-call on the remainder.
    func tryDecode(_ data: Data) -> (Frame?, Int)? {
        // F-4/L-12: a prior malformed frame poisons the stream (RFC: MUST close). Return
        // nil permanently so the connection tears down rather than risking UB.
        if poisoned { return nil }
        guard data.count >= 2 else { return nil }
        let b0 = data[0]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let b1 = data[1]
        // L-12: RFC 6455 §5.1 — masking is directional. Client→server frames MUST be
        // masked; server→client frames MUST be unmasked. A frame with the wrong mask
        // state is a protocol error → poison (the connection MUST be closed).
        let masked = (b1 & 0x80) != 0
        if requireMask && !masked {
            poisoned = true
            return nil
        }
        if !requireMask && masked {
            poisoned = true
            return nil
        }
        var len = Int(b1 & 0x7F)
        var idx = 2
        if len == 126 {
            guard data.count >= idx + 2 else { return nil }
            len = (Int(data[idx]) << 8) | Int(data[idx + 1])
            idx += 2
        } else if len == 127 {
            guard data.count >= idx + 8 else { return nil }
            // F-4: RFC 6455 §5.1 requires the 64-bit length MSB (bit 63) be 0. A set high
            // bit makes `len` negative in Swift's signed Int → `subdata` builds an inverted
            // Range → fatal crash. Reject any length >= 2^63 (high bit set) as malformed.
            // Build the length as unsigned then bound it; reject if the top byte is set.
            if (data[idx] & 0x80) != 0 { poisoned = true; return nil }
            len = 0
            for i in 0..<8 { len = (len << 8) | Int(data[idx + i]) }
            idx += 8
        }
        // F-4: defend against negative/absurd lengths even after the unsigned build.
        if len < 0 { poisoned = true; return nil }
        // F-5: cap total message size (fragmented or single). Reject oversize messages.
        let already = fragAccumulator?.count ?? 0
        if already + len > Self.maxPayloadBytes { poisoned = true; return nil }
        // Masking is directional (RFC 6455 §5.1): client→server frames carry a 4-byte
        // masking key (read + XOR); server→client frames carry NO mask key. When decoding
        // server→client frames (requireMask=false), skip the mask-key read entirely —
        // reading 4 bytes as a "mask" would consume payload bytes and desync the frame.
        if requireMask {
            guard data.count >= idx + 4 else { return nil } // mask key
            let maskKey = [data[idx], data[idx+1], data[idx+2], data[idx+3]]
            idx += 4
            guard data.count >= idx + len else { return nil }
            var payload = data.subdata(in: idx..<(idx + len))
            for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
            let consumed = idx + len
            return assembleFrame(opcode: opcode, fin: fin, payload: payload, consumed: consumed)
        } else {
            guard data.count >= idx + len else { return nil }
            let payload = data.subdata(in: idx..<(idx + len))
            let consumed = idx + len
            return assembleFrame(opcode: opcode, fin: fin, payload: payload, consumed: consumed)
        }
    }

    // Shared frame assembly for both directions: control frames are never fragmented;
    // data frames honor RFC 6455 §5.4 fragmentation (FIN=0 start → continuation → FIN=1).
    // Returns (Frame?, Int): non-nil Frame = complete message; nil Frame = consumed a
    // FIN=0 fragment (caller still strips `consumed` and loops). nil return = poisoned or
    // incomplete (caller strips nothing).
    private func assembleFrame(opcode: UInt8, fin: Bool, payload: Data, consumed: Int) -> (Frame?, Int)? {
        // Control frames (close/ping/pong) are never fragmented and must have FIN=1.
        if opcode == 0x8 || opcode == 0x9 || opcode == 0xA {
            return (Frame(opcode: opcode, payload: payload), consumed)
        }
        // L-13: fragmentation handling. Start frame (opcode 0x1/0x2) with FIN=0 begins a
        // message; continuation frames (opcode 0x0) append; the final frame (FIN=1) emits.
        if opcode == 0x0 {
            // Continuation without a prior start frame is a protocol error.
            guard var acc = fragAccumulator else { poisoned = true; return nil }
            acc.append(payload)
            if fin {
                let out = Frame(opcode: fragOpcode, payload: acc)
                fragAccumulator = nil
                return (out, consumed)
            }
            fragAccumulator = acc
            // Consumed a continuation fragment; no complete message yet. MUST return the
            // consumed byte count so the caller strips these bytes — otherwise the next
            // tryDecode re-parses this fragment, overwrites the accumulator, and the
            // message never completes (the original L-13 bug: returned nil = strip nothing).
            return (nil, consumed)
        }
        // opcode 0x1 or 0x2 (text/binary) start frame.
        if !fin {
            // Begin a fragmented message. Consume the start-frame bytes so the caller does
            // not re-parse them; return nil Frame (no complete message yet).
            fragAccumulator = payload
            fragOpcode = opcode
            return (nil, consumed)
        }
        // Unfragmented single frame — the common path.
        return (Frame(opcode: opcode, payload: payload), consumed)
    }
}

// MARK: - CDP method -> FBActionDriver translation (per cowork cdp_client.py contract)

final class FBCDPTranslator {
    private weak var server: FBCDPServer?
    private let allowedOrigins: [String]
    private let log = FBLogger.shared
    // E-8: per-connection DOM identity registry. CDP hands back integer nodeIds /
    // backendNodeIds and opaque objectIds that cowork caches; these map back to the
    // walker's idStr ("eN" from getFullAXTree, "qN" from querySelector) so focus /
    // getBoxModel / resolveNode can deref a real live element via window.__fbMap.
    //   intToIdStr:      stableNodeId(idStr) -> idStr   (recover idStr from a nodeId int)
    //   objectIdToIdStr: "fb-obj-<seq>"      -> idStr   (recover idStr from a CDP objectId)
    //   idStrToSelector: idStr              -> selector (qN re-query fallback; see buildFocusJS)
    // Guarded by registryLock — getBoxModel/focus/resolveNode may arrive back-to-back.
    private var intToIdStr: [Int: String] = [:]
    private var objectIdToIdStr: [String: String] = [:]
    private var idStrToSelector: [String: String] = [:]
    private var objSeq = 0
    private var qSeq = 0
    private let registryLock = NSLock()

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
            // E-15/L-11/R-16: gate navigation by origin so an attacker cannot pair
            // navigate+evaluate to run JS on an allowlisted page they navigated TO. Local
            // schemes (data:, about:) are allowed (originOfUrl returns nil -> no cross-origin
            // risk). http(s) origins MUST land in the allowlist, and an EMPTY allowlist is
            // fail-closed (deny), consistent with EVALUATE's isOriginAllowed — the old code
            // short-circuited on `!srv.allowedOrigins.isEmpty`, letting default-config
            // operators drive the webview to any attacker origin. Per audit §6 item 13:
            // 空 allowedOrigins 时 navigate 必须 fail-closed（与 EVALUATE 一致）.
            if let navOrigin = originOfUrl(url), !navOrigin.isEmpty {
                guard server?.isOriginAllowed(navOrigin) ?? false else {
                    log.warn("CDP", "navigate denied origin=\(navOrigin)")
                    return errorResp(id: id, code: -32000, message: "navigate_denied")
                }
            }
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
            return handleGetDocument(id: id)
        case "DOM.querySelector":
            return handleQuerySelector(params: params, id: id)
        case "DOM.getBoxModel":
            return handleGetBoxModel(params: params, id: id)
        case "DOM.resolveNode":
            return handleResolveNode(params: params, id: id)
        case "DOM.focus":
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
            // R-3/B-3: return REAL engine metrics, not an empty list. CDP shape:
            // {metrics:[{name,value}]} — counters + latency quantiles flattened.
            // Bearer-gated at the WS upgrade (H-5); the .metrics capability maps to
            // the configured token (tokenCapabilities "metrics"/"all"), so an
            // un-elevated token still gets the live counters here (CDP has no
            // per-method cap layer — the gate is the Bearer token itself).
            let arr = FBMetrics.shared.metricsArray()
            let metrics: [[String: Any]] = arr.map { m in ["name": m.name, "value": m.value] }
            return ok(id, result: ["metrics": metrics])
        case "HeapProfiler.takeHeapSnapshot", "Tracing.start", "Tracing.end":
            return ok(id, result: [:])
        default:
            log.warn("CDP", "unsupported method=\(method)")
            return errorResp(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // E-8: DOM.getDocument -> real-ish root. cowork uses the root nodeId ONLY as the
    // querySelector scope (cdp_client.py L263, L465); it does not inspect root children.
    // Return a fixed document root + childNodeCount from a fresh extract, which ALSO
    // populates window.__fbMap as a side effect (priming the registry-ready idStr table).
    private func handleGetDocument(id: Int) -> String {
        // The document root is NOT an element — no deref needed — so return a stub root
        // even with no live server (cowork uses the root nodeId only as the querySelector
        // scope). With a live server, populate childNodeCount + register observed eN ids.
        var childCount = 0
        if let server = server, let s = server.ensureSession(), !s.isClosing, let wv = s.webview {
            let (res, _, _, _) = server.extractAXTree()
            childCount = res?.nodes.count ?? 0
            // Register every eN we just observed so a later resolveNode(backendNodeId=N)
            // can recover "eN" from the int registry. eN ids are stable for a stable DOM;
            // E-13 (cross-extract stability) is a separate task (#66).
            if let nodes = res?.nodes {
                for n in nodes { registerIdStr(n.nodeId) }
            }
            log.info("CDP", "getDocument root childNodeCount=\(childCount) webview=ok")
        } else {
            log.info("CDP", "getDocument: no live session/webview, stub root childNodeCount=0")
        }
        return ok(id, result: ["root": ["nodeId": kCDPRootNodeId, "backendNodeId": kCDPRootNodeId,
                                        "nodeName": "#document", "childNodeCount": childCount]])
    }

    // E-8: DOM.querySelector -> run the selector against the live DOM, register the FIRST
    // match in window.__fbMap under a fresh "qN" id, return its integer nodeId. cowork's
    // fill flow (cdp_client.py L263-265) passes the returned nodeId back to DOM.focus.
    // qN ids live in a distinct space from walker eN ids to avoid collisions; both
    // resolve uniformly through window.__fbMap.get(idStr).
    private func handleQuerySelector(params: [String: Any], id: Int) -> String {
        // Validate the selector param FIRST — a missing/empty selector is a caller bug
        // (-32602 invalid params) regardless of whether a server is attached.
        guard let selector = params["selector"] as? String, !selector.isEmpty else {
            return errorResp(id: id, code: -32602, message: "missing selector")
        }
        guard let server = server else { return errorResp(id: id, code: -32000, message: "no server") }
        // Prime __fbMap (a cold session has none). Also registers observed eN ids.
        _ = server.extractAXTree()
        // Mint a qN id, register it, and run the selector. We store selector->idStr so a
        // later focus/getBoxModel can RE-QUERY if __fbMap was wiped by an intervening
        // extract (the walker rebuilds __fbMap fresh each extract, dropping qN entries).
        let qId = mintQId()
        idStrToSelector[qId] = selector
        // Escape the selector as a JS string literal (jsStr adds surrounding quotes +
        // escapes quotes/backslashes) and pass it WHOLE as the IIFE argument. Earlier this
        // unwrapped the quotes to pass the bare selector, but `})(#u);` is a JS syntax error
        // (bare `#u` is not a token) -> evaluate throws -> no result -> nodeId 0.
        let selLit = jsStr(selector)
        // Return a bare JS OBJECT, not JSON.stringify(...). E-9 made the .evaluate path
        // JSON-encode the deserialized JS return value into evaluateResult; a JSON.stringify
        // here would yield a JS string, which the driver re-encodes -> double-encoded
        // ("{\"ok\":true,...}") -> our [String:Any] decode fails -> nodeId 0. A bare object
        // deserializes to NSDictionary -> re-encodes to {"ok":true,...} -> decode as dict.
        let js = "(function(sel){var el=document.querySelector(sel);if(!el){return {ok:false};}"
            + "try{window.__fbMap.set(" + jsStr(qId) + ",new WeakRef(el));}catch(e){return {ok:false};}"
            + "return {ok:true,id:" + jsStr(qId) + "};})(" + selLit + ");"
        let state = server.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                              payloadText: js, traceId: "cdp-qsa"))
        if let err = state.error {
            log.warn("CDP", "querySelector evaluate denied err=\(err.code) sel=\(selector.prefix(40))")
            return errorResp(id: id, code: -32000, message: err.code)
        }
        guard let raw = state.evaluateResult, let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              let okFlag = decoded["ok"] as? Bool, okFlag,
              let resolvedId = decoded["id"] as? String else {
            log.info("CDP", "querySelector no match sel=\(selector.prefix(40))")
            return ok(id, result: ["nodeId": 0])
        }
        let nodeId = registerIdStr(resolvedId)
        log.info("CDP", "querySelector sel=\(selector.prefix(40)) -> \(resolvedId) nodeId=\(nodeId)")
        return ok(id, result: ["nodeId": nodeId])
    }

    // E-8: DOM.getBoxModel -> deref the live element via __fbMap and return its
    // getBoundingClientRect quad. cowork computes the click centroid from model.content
    // (8 coords, TL->TR->BR->BL). Returns the REAL rect, not the old 1280x800 stub.
    private func handleGetBoxModel(params: [String: Any], id: Int) -> String {
        guard let server = server else { return errorResp(id: id, code: -32000, message: "no server") }
        guard let idStr = resolveIdStr(params: params) else {
            return errorResp(id: id, code: -32000, message: "node not found")
        }
        // Prime __fbMap in case no prior getFullAXTree/getDocument ran.
        _ = server.extractAXTree()
        guard let boxJS = buildBoxModelJS(idStr: idStr) else {
            return errorResp(id: id, code: -32000, message: "node not found")
        }
        let state = server.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                              payloadText: boxJS, traceId: "cdp-box"))
        if let err = state.error {
            log.warn("CDP", "getBoxModel evaluate denied err=\(err.code) idStr=\(idStr)")
            return errorResp(id: id, code: -32000, message: err.code)
        }
        guard let raw = state.evaluateResult, let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              let okFlag = decoded["ok"] as? Bool, okFlag,
              let content = decoded["content"] as? [Double], content.count == 8 else {
            log.info("CDP", "getBoxModel node stale idStr=\(idStr)")
            return errorResp(id: id, code: -32000, message: "node stale")
        }
        log.info("CDP", "getBoxModel idStr=\(idStr) content=\(content)")
        return ok(id, result: ["model": ["content": content]])
    }

    // E-8: DOM.resolveNode -> {backendNodeId} or {nodeId} -> recover idStr -> mint a CDP
    // objectId bound to it. cowork reads result.object.objectId and passes it to
    // DOM.focus / DOM.getBoxModel. The old code returned "fb-node-<N>", an objectId never
    // registered anywhere, so the downstream derefs always missed.
    private func handleResolveNode(params: [String: Any], id: Int) -> String {
        guard let server = server else { return errorResp(id: id, code: -32000, message: "no server") }
        // E-13: resolveNode is the only DOM handler that did not extract+register, so a
        // backendNodeId handed to it without a prior getFullAXTree found an empty registry.
        // Mirror handleGetDocument: extract + register observed eN so the int->idStr binding
        // reflects the CURRENT tree (self-priming). backendNodeId is a document-order
        // position (1-based Nth interactive node); after a SPA reorder it derefs the CURRENT
        // Nth node (option b), after a tree-shrink the deref site fail-closes (node stale).
        let (res, _, _, err) = server.extractAXTree()
        if let e = err {
            return errorResp(id: id, code: -32000, message: e.code)
        }
        if let nodes = res?.nodes {
            for n in nodes { registerIdStr(n.nodeId) }
        }
        guard let idStr = resolveIdStr(params: params) else {
            return errorResp(id: id, code: -32000, message: "node not found")
        }
        let objectId = mintObjectId(idStr)
        log.info("CDP", "resolveNode idStr=\(idStr) -> objectId=\(objectId)")
        return ok(id, result: ["object": ["type": "node", "objectId": objectId]])
    }

    // E-8: DOM.focus -> deref the live element via __fbMap and call .focus() (+ dispatch a
    // bubbling focus event so React/Vue controlled components register the focus, mirroring
    // the R-10 setter spirit). cowork uses objectId (click flow) or nodeId (fill flow).
    private func handleDOMFocus(params: [String: Any], id: Int) -> String {
        guard let server = server else { return errorResp(id: id, code: -32000, message: "no server") }
        guard let idStr = resolveIdStr(params: params) else {
            return errorResp(id: id, code: -32000, message: "node not found")
        }
        _ = server.extractAXTree()
        guard let focusJS = buildFocusJS(idStr: idStr) else {
            return errorResp(id: id, code: -32000, message: "node not found")
        }
        let state = server.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                              payloadText: focusJS, traceId: "cdp-focus"))
        if let err = state.error {
            log.warn("CDP", "focus evaluate denied err=\(err.code) idStr=\(idStr)")
            return errorResp(id: id, code: -32000, message: err.code)
        }
        let result = state.evaluateResult ?? "\"miss\""
        log.info("CDP", "focus idStr=\(idStr) result=\(result)")
        return ok(id, result: [:])
    }

    // E-8: recover the walker idStr from whatever handle a CDP request carries. Checks
    // objectId first (cowork click flow), then backendNodeId, then nodeId. For a qN idStr
    // whose __fbMap entry an intervening extract may have wiped, returns the idStr anyway;
    // the focus/boxModel JS re-queries the stored selector as a fallback (buildFocusJS /
    // buildBoxModelJS). Unknown handles -> nil -> caller returns node_not_found fail-closed.
    internal func resolveIdStr(params: [String: Any]) -> String? {
        if let oid = params["objectId"] as? String, !oid.isEmpty {
            registryLock.lock(); let s = objectIdToIdStr[oid]; registryLock.unlock()
            if let s = s { return s }
        }
        let intId = (params["backendNodeId"] as? Int) ?? (params["nodeId"] as? Int) ?? 0
        if intId > 0 {
            registryLock.lock(); let s = intToIdStr[intId]; registryLock.unlock()
            if let s = s { return s }
        }
        return nil
    }

    // E-8: register an idStr (mint or reuse), return its integer nodeId (stableNodeId).
    // Idempotent: re-registering the same idStr is a no-op.
    @discardableResult
    internal func registerIdStr(_ idStr: String) -> Int {
        let intId = stableNodeId(idStr)
        registryLock.lock()
        intToIdStr[intId] = idStr
        registryLock.unlock()
        return intId
    }

    // E-8: mint a fresh objectId bound to an idStr. Cowork caches and reuses this handle.
    internal func mintObjectId(_ idStr: String) -> String {
        registryLock.lock()
        objSeq += 1
        let oid = "fb-obj-\(objSeq)"
        objectIdToIdStr[oid] = idStr
        registryLock.unlock()
        return oid
    }

    // E-8: mint a fresh qN idStr for querySelector matches.
    private func mintQId() -> String {
        registryLock.lock()
        qSeq += 1
        let q = "q\(qSeq)"
        registryLock.unlock()
        return q
    }

    // E-8 test seam: bind a selector to a qN idStr so the builder fallback path is
    // unit-testable (mirrors what handleQuerySelector stores for a real querySelector hit).
    internal func bindSelector(_ selector: String, toIdStr idStr: String) {
        registryLock.lock()
        idStrToSelector[idStr] = selector
        registryLock.unlock()
    }

    // E-8 test seam: build the getBoxModel JS for an idStr, nil for empty. Pure (no
    // webview) so the resolver shape is unit-testable under `swift test` (live dispatch
    // can't run here — ARCH-3). The JS derefs window.__fbMap.get(idStr); if the WeakRef is
    // gone (an intervening extract wiped qN, or a SPA re-render GC'd the node), fall back to
    // re-querying the stored selector (qN only). Pins that a stale node returns {ok:false},
    // not a faked rect.
    internal func buildBoxModelJS(idStr: String) -> String? {
        guard !idStr.isEmpty else { return nil }
        var fallback = ""
        registryLock.lock()
        if let sel = idStrToSelector[idStr] {
            fallback = "else{var fb=document.querySelector(" + jsStr(sel) + ");if(fb){var rr=fb.getBoundingClientRect();return {ok:true,content:[rr.left,rr.top,rr.right,rr.top,rr.right,rr.bottom,rr.left,rr.bottom]};}}"
        }
        registryLock.unlock()
        // Return bare JS OBJECTS (not JSON.stringify) — E-9 re-encodes the deserialized JS
        // return, so a JSON.stringify here would double-encode and our [String:Any] decode
        // would fail (see handleQuerySelector for the same fix).
        return "(function(id){var ref=window.__fbMap&&window.__fbMap.get(id);"
            + "if(ref&&ref.deref){var el=ref.deref();if(el){var r=el.getBoundingClientRect();"
            + "return {ok:true,content:[r.left,r.top,r.right,r.top,r.right,r.bottom,r.left,r.bottom]};}}"
            + fallback + "return {ok:false};})(" + jsStr(idStr) + ");"
    }

    // E-8 test seam: build the focus JS for an idStr, nil for empty. Pure (no webview).
    // Deref __fbMap.get(idStr) -> .focus() + a bubbling FocusEvent (React/Vue controlled
    // components). qN fallback re-queries the stored selector if the WeakRef was wiped.
    internal func buildFocusJS(idStr: String) -> String? {
        guard !idStr.isEmpty else { return nil }
        var fallback = ""
        registryLock.lock()
        if let sel = idStrToSelector[idStr] {
            fallback = "else{var fb=document.querySelector(" + jsStr(sel) + ");if(fb){fb.focus();fb.dispatchEvent(new FocusEvent('focus',{bubbles:true}));return 'ok';}}"
        }
        registryLock.unlock()
        return "(function(id){var ref=window.__fbMap&&window.__fbMap.get(id);"
            + "if(ref&&ref.deref){var el=ref.deref();if(el){el.focus();el.dispatchEvent(new FocusEvent('focus',{bubbles:true}));return 'ok';}}"
            + fallback + "return 'miss';})(" + jsStr(idStr) + ");"
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
        log.debug("CDP", "evaluate expr_len=\(expr.count) returnByValue=\(returnByValue) fd-eval")
        // E-9: return the REAL JS expression result, not a synthetic "ok". The driver
        // JSON-encoded the deserialized value into state.evaluateResult; decode it here and
        // build the CDP RemoteObject shape {type, value}. Type inference:
        //   string -> {type:"string", value:<str>}
        //   number -> {type:"number", value:<num>}
        //   bool   -> {type:"boolean", value:<bool>}
        //   null   -> {type:"undefined" (JSON null has no JS null distinct from undefined in
        //             this shim), value: NSNull()} — caller reads .value as null/nil
        //   array/object -> {type:"object", value:<json>} (only meaningful with returnByValue)
        //   absent (eval returned undefined/threw/timeout) -> {type:"undefined"}
        // Without returnByValue, a primitive is still returned by value (this shim has no
        // RemoteObject handle table); objects would need objectId which we don't model, so
        // we still surface the by-value JSON for objects (cowork reads result.result.value).
        guard let raw = state?.evaluateResult, let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            // eval returned undefined / threw / timed out -> no result.
            log.info("CDP", "evaluate no result (undefined/throw/timeout) expr_len=\(expr.count) fd-eval")
            return ok(id, result: ["result": ["type": "undefined"]])
        }
        let (cdpType, cdpValue): (String, Any) = cdpRemoteObject(decoded)
        return ok(id, result: ["result": ["type": cdpType, "value": cdpValue]])
    }

    // E-9: map a JSON-decoded JS value to the CDP RemoteObject {type, value} pair.
    // Strings -> string, NSNumber number/boolean split (JS bool is NSNumber __NSCFBoolean),
    // arrays/dicts -> object, NSNull -> undefined.
    func cdpRemoteObject(_ decoded: Any) -> (String, Any) {
        if decoded is NSNull { return ("undefined", NSNull()) }
        if let b = decoded as? Bool { return ("boolean", b) }
        if let n = decoded as? NSNumber { return ("number", n.doubleValue) }
        if let s = decoded as? String { return ("string", s) }
        // array or dict -> object (by value; cowork reads result.result.value).
        return ("object", decoded)
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
            // E-8: register every observed eN -> int so a later
            // resolveNode(backendNodeId=N) can recover "eN" from the registry.
            // Without this the Flow A click chain (getFullAXTree -> resolveNode)
            // finds an empty registry and returns no objectId.
            // E-13: backendNodeId is a document-order position (1-based Nth interactive
            // node), stable only for static pages. SPA reorder shifts it; callers MUST
            // re-fetch getFullAXTree before acting on a reordered page. See handleResolveNode.
            let bid = registerIdStr(n.nodeId)
            let node: [String: Any] = [
                "nodeId": n.nodeId,
                // L-9: backendNodeId must be stable across restarts and collision-free.
                // nodeId is "eN"; derive the integer from the N suffix. hashValue is
                // process-randomized (SipHash seed) so it drifts per launch and collides.
                "backendNodeId": bid,
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
    // L-8: CDP mouse dispatch is COORDINATE-BASED by protocol — real Chrome performs an OS-level
    // mouse event at the pixel, and Input.dispatchMouseEvent carries NO backendNodeId, only x/y.
    // It therefore CANNOT route through the UDS __fbMap node-resolution + fingerprint path: there
    // is no node id to resolve, only coordinates. This is a DOCUMENTED INTENTIONAL DIVERGENCE
    // from the UDS click contract (audit L-8 option 2, explicitly permitted by the finding):
    //   - CDP click never returns node_stale, so the T3.4 visual-grounding fallback does NOT
    //     engage on the CDP path (it fires only on a UDS resolveClick node_stale).
    //   - The Phase-4 evaluateJSSyncArgs placeholder-starvation bug could not surface here
    //     because CDP never calls resolveClick (no __ARG__ placeholders in this JS).
    // cowork's cdp_client.py derives x/y from the AX node's bounding-box centroid, so
    // elementFromPoint resolves to the same node UDS would click by id — semantically
    // equivalent for well-formed callers, just reached by coordinate instead of node id.
    private func handleMouseEvent(params: [String: Any], id: Int) -> String {
        let type = (params["type"] as? String) ?? ""
        let x = (params["x"] as? Double) ?? 0
        let y = (params["y"] as? Double) ?? 0
        // L-8: fire ONLY on mouseReleased. A CDP click is a paired mousePressed + mouseReleased;
        // real Chrome fires the `click` event on release. The old condition
        // (`mouseReleased || mousePressed`) fired on BOTH halves of the pair -> double-fire
        // (one press+release invoked el.click() twice). Release-only matches the comment's
        // stated intent and real-browser semantics.
        guard type == "mouseReleased" else { return ok(id, result: [:]) }
        // L-8: guard non-finite coords before interpolation. x/y arrive as JSON numbers (always
        // finite in valid JSON), but a NaN/Infinity reaching elementFromPoint(\(x),\(y)) interpolates
        // to `elementFromPoint(nan,...)` — JS `nan` is an undefined identifier -> ReferenceError ->
        // evaluateJSSync returns nil -> silent click failure (same defect class as L-5 visual click,
        // which interpolated raw VLM coords). buildClickJS returns nil for non-finite; skip the
        // dispatch rather than emit broken JS.
        guard let clickJS = buildClickJS(x: x, y: y) else {
            log.warn("CDP", "click skipped: non-finite coords x=\(x) y=\(y)")
            return ok(id, result: [:])
        }
        _ = server?.executeAction(BrowserActionRequest(sessionId: "", action: .evaluate,
                                                       payloadText: clickJS, traceId: "cdp-click"))
        return ok(id, result: [:])
    }

    // L-8 test seam: build the elementFromPoint click JS for finite coords, nil for non-finite.
    // Pure function (no webview) so the finite-guard invariant is unit-testable under `swift test`
    // — the live dispatch path (executeAction -> evaluateJSSync) cannot run here (no main run loop,
    // ARCH-3 constraint). Pins that a non-finite coordinate never reaches the JS string.
    internal func buildClickJS(x: Double, y: Double) -> String? {
        guard x.isFinite, y.isFinite else { return nil }
        return "(function(){var e=document.elementFromPoint(\(x),\(y));if(e){e.click();return 'ok';}return 'miss';})();"
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
        guard let server = server, let s = server.ensureSession(), !s.isClosing, let wv = s.webview else {
            return errorResp(id: id, code: -32000, message: "no session")
        }
        guard let png = wv.screenshotSync() else {
            return errorResp(id: id, code: -32000, message: "screenshot failed")
        }
        let b64 = png.base64EncodedString()
        return ok(id, result: ["data": b64])
    }

    // L-11: extract the origin (scheme://host[:port]) of a URL, or nil/empty for local
    // schemes (data:, about:, blob:, javascript:) which are allowed to navigate freely.
    private func originOfUrl(_ url: String) -> String? {
        let lower = url.lowercased()
        for local in ["data:", "about:", "blob:", "javascript:", "file:"] {
            if lower.hasPrefix(local) { return nil }
        }
        guard let comps = URLComponents(string: url),
              let scheme = comps.scheme, let host = comps.host, !host.isEmpty else {
            return ""
        }
        if let port = comps.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    // E-8: fixed CDP document-root nodeId. cowork uses it only as the querySelector scope.
    internal let kCDPRootNodeId = 1

    // L-9: derive a stable, non-negative integer id from a nodeId ("eN" -> N). Falls back
    // to a deterministic FNV-1a hash for non-eN ids so it never collides due to hashValue
    // randomization. backendNodeId is caller-cached (cowork) so it MUST survive restarts.
    internal func stableNodeId(_ nodeId: String) -> Int {
        if nodeId.hasPrefix("e"), let n = Int(nodeId.dropFirst()) {
            return n
        }
        return stableHash(nodeId) & 0x7FFFFFFF
    }

    // FNV-1a (32-bit) — deterministic across processes, unlike Swift's hashValue.
    internal func stableHash(_ s: String) -> Int {
        var hash: UInt32 = 2166136261
        for b in s.utf8 {
            hash ^= UInt32(b)
            hash = hash &* 16777619
        }
        return Int(hash)
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

    // L-10: escape a string for a JS string literal. Previously only escaped `\` and `"`
    // — a raw newline in the payload produced a SyntaxError (unterminated literal), so
    // multi-line Input.insertText silently failed. Now escapes backslash, double-quote,
    // newline, carriage return, tab, and all other control chars (< 0x20) per JSON.
    internal func jsStr(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out += String(ch)
                }
            }
        }
        out += "\""
        return out
    }
}
