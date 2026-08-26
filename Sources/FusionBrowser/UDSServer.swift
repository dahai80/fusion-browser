import Foundation
import Darwin

// FR-09 + FR-10: UDS server via POSIX socket (NWListener unreliable for AF_UNIX accept).
// Per-client serial dispatch queue (no HOL blocking across clients), token auth, length-prefixed framing.

public final class FBUDSServer {
    private let socketPath: String
    private let manager: FBSessionManager
    private let driver: FBActionDriver
    private let auth: FBAuth
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let log = FBLogger.shared
    // Retain clients so they aren't deallocated before their read source fires.
    // ObjectIdentifier does NOT hold a strong ref; must store the object itself.
    private var clients: [ObjectIdentifier: FBClientConnection] = [:]
    private let clientsLock = NSLock()

    public init(socketPath: String, manager: FBSessionManager, driver: FBActionDriver, auth: FBAuth) {
        self.socketPath = socketPath
        self.manager = manager
        self.driver = driver
        self.auth = auth
    }

    public func start() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FBError.internalError }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let pathCap = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCap) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, min(pathBytes.count, pathCap))
                }
            }
        }
        let bindRes = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else { Darwin.close(fd); log.error("UDSServer", "bind failed errno=\(errno)"); throw FBError.internalError }
        guard Darwin.listen(fd, 16) == 0 else { Darwin.close(fd); log.error("UDSServer", "listen failed"); throw FBError.internalError }
        chmod(socketPath, 0o600)
        self.listenFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            self?.acceptOnce()
        }
        source.setCancelHandler { [weak self] in
            if let f = self?.listenFd, f >= 0 { Darwin.close(f) }
            self?.listenFd = -1
        }
        source.resume()
        self.acceptSource = source
        log.info("UDSServer", "listening at \(socketPath)")
    }

    private func acceptOnce() {
        let clientFd = Darwin.accept(listenFd, nil, nil)
        guard clientFd >= 0 else { return }
        // Set non-blocking so DispatchSourceRead read never blocks the queue.
        let flags = fcntl(clientFd, F_GETFL, 0)
        _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)
        log.info("UDSServer", "connection accepted fd=\(clientFd)")
        let client = FBClientConnection(fd: clientFd, manager: manager, driver: driver, auth: auth) { [weak self] in
            // onDone: remove from retain set
            self?.releaseClient(ObjectIdentifier($0))
        }
        clientsLock.lock()
        clients[ObjectIdentifier(client)] = client
        clientsLock.unlock()
        client.start()
    }

    private func releaseClient(_ id: ObjectIdentifier) {
        clientsLock.lock()
        clients.removeValue(forKey: id)
        clientsLock.unlock()
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        log.info("UDSServer", "stopped")
    }
}

final class FBClientConnection {
    private let fd: Int32
    private let manager: FBSessionManager
    private let driver: FBActionDriver
    private let auth: FBAuth
    private let reader = FBFrameReader()
    private let queue = DispatchQueue(label: "fusion-browser.client")
    private var readSource: DispatchSourceRead?
    private var authed = false
    private var caps: FBCapabilities = []
    private let log = FBLogger.shared
    private let onDone: (FBClientConnection) -> Void

    init(fd: Int32, manager: FBSessionManager, driver: FBActionDriver, auth: FBAuth,
         onDone: @escaping (FBClientConnection) -> Void) {
        self.fd = fd
        self.manager = manager
        self.driver = driver
        self.auth = auth
        self.onDone = onDone
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.onReadable()
        }
        source.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { Darwin.close(f) }
            self?.log.info("Client", "disconnected fd=\(self?.fd ?? -1)")
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
        if n == 0 {
            log.debug("Client", "EOF fd=\(fd)")
            readSource?.cancel()
            return
        }
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            log.warn("Client", "read err errno=\(errno) fd=\(fd)")
            readSource?.cancel()
            return
        }
        let (frames, overflow) = reader.append(Data(bytes: buf, count: n))
        log.debug("Client", "recv \(n) bytes frames=\(frames.count) overflow=\(overflow)")
        if overflow { send(error: .invalidRequest); readSource?.cancel(); return }
        for frame in frames { handleFrame(frame) }
    }

    private func handleFrame(_ frame: Data) {
        if !authed {
            if let authMsg = try? FBFrame.decode(frame, as: AuthMessage.self) {
                guard let c = auth.authenticate(token: authMsg.token) else {
                    log.warn("Client", "auth failed")
                    send(error: .authDenied)
                    readSource?.cancel()
                    return
                }
                authed = true
                caps = c
                log.info("Client", "auth ok caps=\(c.rawValue)")
                sendAuthed()
                return
            }
            log.warn("Client", "first frame not auth")
            send(error: .authDenied)
            readSource?.cancel()
            return
        }

        guard let req = try? FBFrame.decode(frame, as: FBRequest.self) else {
            send(error: .invalidRequest)
            return
        }
        route(req)
    }

    private func route(_ req: FBRequest) {
        switch req {
        case .createSession(let r):
            switch manager.create(req: r, traceId: req.traceId) {
            case .success(let cr): send(resp: .createSession(cr))
            case .failure(let e): send(error: e)
            }
        case .execute(let r):
            guard caps.contains(cap(for: r.action)) else { send(error: .authDenied); return }
            guard let session = manager.get(r.sessionId) else { send(error: .sessionNotFound); return }
            let state = driver.execute(session: session, req: r)
            send(resp: .state(state))
        case .close(let sid):
            let err = manager.close(sessionId: sid)
            if let e = err { send(error: e) }
            else { send(resp: .closed(sessionId: sid)) }
        }
    }

    private func send(resp: FBResponse) {
        do {
            let data = try FBFrame.encode(resp)
            writeAll(data)
        } catch {
            log.error("Client", "encode failed: \(error)")
        }
    }

    private func send(error: FBError) {
        send(resp: .error(error))
    }

    private func sendAuthed() {
        let ack = AuthAck(caps: caps.rawValue)
        if let data = try? FBFrame.encode(ack) { writeAll(data) }
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

    private func cap(for action: ActionType) -> FBCapabilities {
        switch action {
        case .navigate: return .navigate
        case .click: return .click
        case .typeText: return .type
        case .scroll: return .scroll
        case .screenshot: return .screenshot
        case .evaluate: return .evaluate
        case .close: return .close
        }
    }
}

struct AuthMessage: Codable {
    let token: String?
}
struct AuthAck: Codable {
    let type: String = "auth_ack"
    let caps: Int
}
