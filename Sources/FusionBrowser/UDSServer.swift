import Foundation
import Darwin

// FR-09 + FR-10: UDS server via POSIX socket (NWListener unreliable for AF_UNIX accept).
// Per-client serial dispatch queue (no HOL blocking across clients), token auth, length-prefixed framing.

public final class FBUDSServer {
    private let socketPath: String
    private let manager: FBSessionManager
    private let driver: FBActionDriver
    private let auth: FBAuth
    private let rateLimitConfig: FBRateLimitConfig
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let log = FBLogger.shared
    // Retain clients so they aren't deallocated before their read source fires.
    // ObjectIdentifier does NOT hold a strong ref; must store the object itself.
    private var clients: [ObjectIdentifier: FBClientConnection] = [:]
    private let clientsLock = NSLock()

    public init(socketPath: String, manager: FBSessionManager, driver: FBActionDriver,
                auth: FBAuth, rateLimit: FBRateLimitConfig = FBRateLimitConfig()) {
        self.socketPath = socketPath
        self.manager = manager
        self.driver = driver
        self.auth = auth
        self.rateLimitConfig = rateLimit
    }

    public func start() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FBError.internalError }
        // F-9: socket file must be 0o600 at CREATION, not chmod'd after bind (TOCTOU).
        // Set umask 0o077 before bind so the inode is born with 0o600; restore after.
        // Belt-and-suspenders: fchmod(fd) post-bind closes by fd (no path race).
        let savedUmask = umask(0o077)
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
        _ = umask(savedUmask)
        guard bindRes == 0 else { Darwin.close(fd); log.error("UDSServer", "bind failed errno=\(errno)"); throw FBError.internalError }
        _ = fchmod(fd, 0o600)
        guard Darwin.listen(fd, 128) == 0 else { Darwin.close(fd); log.error("UDSServer", "listen failed"); throw FBError.internalError }
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
        let client = FBClientConnection(fd: clientFd, manager: manager, driver: driver, auth: auth,
                                         rateLimitConfig: rateLimitConfig) { [weak self] in
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
    // H-8: .userInitiated QoS so a client's execute requests are not deprioritized
    // behind background work on the shared dispatch pool (fair scheduling to the
    // main-thread webview path). The serial label still isolates one client's frames.
    private let queue = DispatchQueue(label: "fusion-browser.client", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var authed = false
    private var caps: FBCapabilities = []
    private let log = FBLogger.shared
    private let onDone: (FBClientConnection) -> Void
    // H-8: per-client token-bucket rate limiter. nil when disabled (bypass).
    private let rateLimiter: FBRateLimiter?
    // B-5/E-34: stable per-connection owner id. Minted at init (UUID, not the reusable fd),
    // recorded on every session this client creates and verified on execute/close. Lets the
    // route deny a client operating another client's session (not_owner) without trusting fd
    // reuse or socket identity.
    private let ownerId: String
    // B-5/E-35: per-client in-flight batch cap. onReadable bounds the frames processed per
    // read so a 64KB recv (~2000 small frames) cannot queue 2000 blocking driver.execute on
    // main in one shot. Excess complete frames are buffered here and drained on subsequent
    // reads (lossless backpressure — no frame is dropped, just deferred).
    private var pendingFrames: [Data] = []
    private let maxBatch: Int

    init(fd: Int32, manager: FBSessionManager, driver: FBActionDriver, auth: FBAuth,
         rateLimitConfig: FBRateLimitConfig,
         onDone: @escaping (FBClientConnection) -> Void) {
        self.fd = fd
        self.manager = manager
        self.driver = driver
        self.auth = auth
        self.onDone = onDone
        if rateLimitConfig.enabled {
            self.rateLimiter = FBRateLimiter(ratePerSec: rateLimitConfig.ratePerSec,
                                             burst: rateLimitConfig.burst)
        } else {
            self.rateLimiter = nil
        }
        self.ownerId = UUID().uuidString
        // B-5/E-35: bound per-read frame processing. 64 caps a single onReadable to at most
        // 64 blocking driver.execute on main before deferring; a flood is drained across many
        // reads rather than monopolizing the shared main-thread webview path in one burst.
        self.maxBatch = 64
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
        let (frames, overflow, timeout) = reader.append(Data(bytes: buf, count: n))
        log.debug("Client", "recv \(n) bytes frames=\(frames.count) overflow=\(overflow) timeout=\(timeout)")
        if overflow { send(error: .invalidRequest); readSource?.cancel(); return }
        // B-4/R-6: partial frame overstayed frameTimeoutMs -> drop the slow-drip client.
        if timeout { send(error: .invalidRequest); readSource?.cancel(); return }
        // B-5/E-35: lossless per-read batch cap. Append freshly-decoded frames to the pending
        // queue, then drain at most maxBatch this turn. Excess frames stay queued and are
        // drained on the next readable event (the socket is level-triggered via
        // DispatchSourceRead, so a still-pending buffer re-fires onReadable). No frame is
        // dropped — a flooding client is simply spread across reads instead of monopolizing
        // main in one burst.
        pendingFrames.append(contentsOf: frames)
        drainPending()
    }

    // B-5/E-35: process up to maxBatch pending frames per call. Called from onReadable after
    // appending new frames; also re-invoked inline if the queue still has work (bounded by
    // maxBatch each pass, so a huge backlog yields between batches rather than looping
    // unboundedly on one onReadable — the dispatch source will re-fire for the remainder).
    private func drainPending() {
        let toProcess = Self.splitBatch(&pendingFrames, max: maxBatch)
        for frame in toProcess { handleFrame(frame) }
        if !pendingFrames.isEmpty {
            log.debug("Client", "batch cap deferred \(pendingFrames.count) frames fd=\(fd)")
            // Re-arm: schedule another drain pass on this client's serial queue. The queue is
            // serial so this cannot race onReadable; it just continues the bounded drain.
            queue.async { [weak self] in self?.drainPending() }
        }
    }

    // B-5/E-35: pure slicing primitive — removes and returns up to `max` frames from the
    // front of `pending`, leaving the rest. Extracted so the batch cap is unit-testable
    // without a live socket/handleFrame (the bound is the security property; the drain loop
    // just applies it). A 200-frame flood yields <= max per call, deferring the remainder.
    static func splitBatch(_ pending: inout [Data], max: Int) -> [Data] {
        guard max > 0, !pending.isEmpty else { return [] }
        let take = Swift.min(max, pending.count)
        let slice = Array(pending.prefix(take))
        pending.removeFirst(take)
        return slice
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
            switch manager.create(req: r, traceId: req.traceId, ownerId: ownerId) {
            case .success(let cr): send(resp: .createSession(cr))
            case .failure(let e): send(error: e)
            }
        case .execute(let r):
            guard caps.contains(cap(for: r.action)) else { send(error: .authDenied); return }
            // H-8: per-client rate gate. A rejected request does NOT consume a token,
            // so a retry-poll loop does not drain the bucket for the next legit caller.
            if let limiter = rateLimiter, !limiter.admit() {
                log.warn("Client", "rate_limited fd=\(fd) action=\(r.action.rawValue)")
                send(error: .rateLimited)
                return
            }
            // B-5/E-34: owner-aware get. A client may only execute on sessions it created
            // (or system-owned sessions). Mismatch -> not_owner (not sessionNotFound, so the
            // caller can distinguish "doesn't exist" from "not yours" for audit/telemetry).
            switch manager.get(r.sessionId, ownerId: ownerId) {
            case .success(let session):
                // H-5: pass the token's actual caps to the driver (authoritative per-action gate).
                let state = driver.execute(session: session, req: r, caps: caps)
                send(resp: .state(state))
            case .failure(let e): send(error: e)
            }
        case .close(let sid):
            // F-8: top-level .close must respect .close capability (cross-session DoS
            // if a navigate-only client can tear down any session by id).
            guard caps.contains(.close) else { send(error: .authDenied); return }
            // B-5/E-34: owner-aware close. A client cannot tear down another client's session.
            let err = manager.close(sessionId: sid, ownerId: ownerId)
            if let e = err { send(error: e) }
            else { send(resp: .closed(sessionId: sid)) }
        case .metrics:
            // R-3/B-3: read-only engine metrics. Capability-gated (.metrics, NOT in .default —
            // operator opts in via tokenCapabilities). Returns counters + latency quantiles.
            // Split by suffix: latency triples end in .count/.p50_ms/.p95_ms (derived from
            // recordLatency keys); raw increment() counters never use those suffixes.
            guard caps.contains(.metrics) else { send(error: .authDenied); return }
            let arr = FBMetrics.shared.metricsArray()
            let isLatency = { (n: String) in
                n.hasSuffix(".p50_ms") || n.hasSuffix(".p95_ms") || n.hasSuffix(".count")
            }
            let counters = arr.filter { !isLatency($0.name) }
            let latency = arr.filter { isLatency($0.name) }
            send(resp: .metrics(MetricsResponse(counters: counters, latency: latency)))
        case .capacity:
            // H-9: per-node capacity report — the scheduler-placement input for an external
            // scheduler (fusion-gateway; cross-node scheduling/migration lands there per
            // audit R-10). Read-only resource info (node id + max/live sessions + free
            // memory), lower-sensitivity than metrics counters, so it reuses the .metrics
            // cap (an operator exposing metrics already exposes resource shape). System
            // caller (no owner needed). Logs node-id + live-count for ops placement audit,
            // never session contents.
            guard caps.contains(.metrics) else { send(error: .authDenied); return }
            let cap = manager.capacity()
            log.info("Client", "capacity query node=\(cap.nodeId.prefix(8)) live=\(cap.liveSessions)/\(cap.maxSessions) freeMB=\(cap.freeMemoryMB)")
            send(resp: .capacity(cap))
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

    // P-2: bounded backpressure. fd is non-blocking; on EAGAIN we poll(POLLOUT) with a
    // per-call deadline instead of busy-spinning (usleep spin pins the queue thread
    // unbounded on a slow client). A client that never drains is dropped after the
    // deadline rather than starving the shared dispatch pool.
    private static let writeDeadlineMs: Int32 = 5000
    private func writeAll(_ data: Data) {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: sent)
                return Darwin.write(fd, p, data.count - sent)
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if !awaitWritable() {
                        log.warn("Client", "write timeout fd=\(fd), dropping slow client")
                        readSource?.cancel()
                        return
                    }
                    continue
                }
                log.warn("Client", "write err errno=\(errno) fd=\(fd)")
                readSource?.cancel(); return
            }
            if n == 0 { readSource?.cancel(); return }
            sent += n
        }
    }

    // Block up to writeDeadlineMs for the fd to become writable. Returns false on
    // timeout (caller should drop the client) or poll error.
    private func awaitWritable() -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let r = withUnsafeMutablePointer(to: &pfd) { ptr in
            Darwin.poll(ptr, nfds_t(1), Self.writeDeadlineMs)
        }
        return r > 0 && (pfd.revents & Int16(POLLOUT)) != 0
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
