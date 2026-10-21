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
    // Issue #25: screenshot stream hub shared by every connection (nil = streaming off).
    private let streamHub: FBStreamHub?
    private var listenFd: Int32 = -1
    // C-4 (1016 audit): listenFd is written by stop() (cancel handler on the source queue)
    // and read by acceptOnce() (same source queue — but the cancel handler + a concurrent
    // acceptOnce can interleave). NSLock-guarded so a closed fd can never be re-accept()ed
    // (accept on closed fd = EMFILE/-1 or, worse, accept on a REUSED fd number = hijacking
    // an unrelated client socket).
    private let fdLock = NSLock()
    private var acceptSource: DispatchSourceRead?
    private let log = FBLogger.shared
    // Retain clients so they aren't deallocated before their read source fires.
    // ObjectIdentifier does NOT hold a strong ref; must store the object itself.
    private var clients: [ObjectIdentifier: FBClientConnection] = [:]
    private let clientsLock = NSLock()

    public init(socketPath: String, manager: FBSessionManager, driver: FBActionDriver,
                auth: FBAuth, rateLimit: FBRateLimitConfig = FBRateLimitConfig(),
                streamHub: FBStreamHub? = nil) {
        self.socketPath = socketPath
        self.manager = manager
        self.driver = driver
        self.auth = auth
        self.rateLimitConfig = rateLimit
        self.streamHub = streamHub
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
        // M-4 (1016 audit): the old memcpy silently TRUNCATED a socket path longer than
        // sun_path (104 bytes) — a long path bound a DIFFERENT socket file than requested
        // (e.g. two truncated paths colliding on one socket). Fail loud instead.
        guard pathBytes.count <= pathCap else {
            Darwin.close(fd)
            log.error("UDSServer", "socketPath exceeds sun_path cap (\(pathBytes.count) > \(pathCap)): \(socketPath)")
            throw FBError.internalError
        }
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
        // C-4: read the listen fd under the lock; accept runs outside the lock (accept can
        // block? no — fd is non-blocking + level-triggered source, safe outside). The lock
        // only serializes against stop()'s cancel+close.
        fdLock.lock()
        let fd = listenFd
        fdLock.unlock()
        guard fd >= 0 else { return }
        let clientFd = Darwin.accept(fd, nil, nil)
        guard clientFd >= 0 else { return }
        // Set non-blocking so DispatchSourceRead read never blocks the queue.
        let flags = fcntl(clientFd, F_GETFL, 0)
        _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)
        log.info("UDSServer", "connection accepted fd=\(clientFd)")
        let client = FBClientConnection(fd: clientFd, manager: manager, driver: driver, auth: auth,
                                         rateLimitConfig: rateLimitConfig, streamHub: streamHub) { [weak self] in
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
        // M-7 (1016 audit): stop() cancelled the accept source but left live client
        // connections (their DispatchSourceRead sources kept firing on a server that is
        // shutting down, serving requests against a closing engine). Tear down clients
        // first, then the accept source.
        var live: [FBClientConnection] = []
        clientsLock.lock()
        live = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()
        for c in live { c.teardown() }
        acceptSource?.cancel()
        acceptSource = nil
        try? FileManager.default.removeItem(atPath: socketPath)
        log.info("UDSServer", "stopped clients=\(live.count)")
    }
}

// C-4 + #25: one owner for a connection's socket number. The cancel handler closes the
// fd while onReadable may be reading and (since the screenshot push path) the stream hub's
// capture thread may be writing. A check-then-syscall on a bare Int raced that close: the
// number could be REUSED by a new accept between the validity check and the syscall, so a
// frame intended for client A landed in client B's socket and desynchronized its
// length-prefixed stream. Every syscall now runs inside `withFd`, which holds the lock the
// close path needs — a close cannot interleave with a read or write, and a closed guard
// never hands out its number.
final class FBAtomicFd {
    private let lock = NSLock()
    private var fd: Int32

    init(_ fd: Int32) {
        self.fd = fd
    }

    // Current number, or -1 once closed. For logging / poll only — never syscall on it.
    var value: Int32 {
        lock.lock(); defer { lock.unlock() }
        return fd
    }

    // Runs body with a live fd while close() is blocked. nil when already closed.
    func withFd<T>(_ body: (Int32) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return nil }
        return body(fd)
    }

    func close() {
        lock.lock()
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        lock.unlock()
    }
}

final class FBClientConnection {
    // C-4 (1016 audit) + #25: the fd is owned by FBAtomicFd so the cancel handler, a queued
    // read, and the stream hub's write thread can never operate a closed or reused number.
    private let socket: FBAtomicFd
    private func validFd() -> Int32 { socket.value }
    private func closeFd() { socket.close() }
    // Logging/diagnostic view of the socket number (-1 once closed). NEVER syscall on this:
    // it can be closed and reused between the read and the call.
    private var fd: Int32 { socket.value }
    private let manager: FBSessionManager
    private let driver: FBActionDriver
    private let auth: FBAuth
    // Issue #25: stream hub (frame pushes from the capture thread) + browser cookie keys
    // cached per connection (one Keychain consent prompt per browser, not per import).
    private let streamHub: FBStreamHub?
    private var cookieKeys: [FBBrowserKind: Data] = [:]
    private let reader = FBFrameReader()
    // Issue #25: serializes socket writes. Stream frames are written from the hub's
    // capture completion thread while responses are written from this client's queue —
    // two concurrent writeAll calls would interleave halves of two frames on the wire.
    private let writeLock = NSLock()
    // H-8: .userInitiated QoS so a client's execute requests are not deprioritized
    // behind background work on the shared dispatch pool (fair scheduling to the
    // main-thread webview path). The serial label still isolates one client's frames.
    private let queue = DispatchQueue(label: "fusion-browser.client", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    // C-6: partial-frame watchdog timer (see start()).
    private var partialTimer: DispatchSourceTimer?
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
    // R-10: a system-caller token (operator config `tokenSystemCaller`) makes this connection
    // pass ownerId=nil to create/execute/close so SessionManager bypasses E-34 ownership —
    // the per-call-dial proxy/scheduler case (fusion-gateway dials a fresh UDS conn per op,
    // so create's ownerId != execute's ownerId → not_owner without the bypass). Mirrors the
    // nil-owner path CDP already uses. ownerId stays the non-system identity for logging;
    // effectiveOwner returns nil when isSystemCaller is on.
    private let ownerId: String
    // R-10: set true on auth success when the token is the operator-designated system-caller
    // token. Drives effectiveOwner (nil → SessionManager bypass).
    private var isSystemCaller = false
    // Issue #25: durable owner identity for persistent profiles (auth-token SHA256 hex).
    // nil when the token has no identity (no token configured) — profile creates fail closed.
    private var connectionOwnerKey: String?
    // B-5/E-35: per-client in-flight batch cap. onReadable bounds the frames processed per
    // read so a 64KB recv (~2000 small frames) cannot queue 2000 blocking driver.execute on
    // main in one shot. Excess complete frames are buffered here and drained on subsequent
    // reads (lossless backpressure — no frame is dropped, just deferred).
    private var pendingFrames: [Data] = []
    private let maxBatch: Int

    init(fd: Int32, manager: FBSessionManager, driver: FBActionDriver, auth: FBAuth,
         rateLimitConfig: FBRateLimitConfig, streamHub: FBStreamHub? = nil,
         onDone: @escaping (FBClientConnection) -> Void) {
        self.socket = FBAtomicFd(fd)
        self.manager = manager
        self.driver = driver
        self.auth = auth
        self.streamHub = streamHub
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
        // C-6 (1016 audit): append-time staleness check only fired on the client's NEXT
        // bytes — a silent slow-drip client held the partial buffer forever. A watchdog
        // timer on this client's serial queue polls the reader's partial-frame state every
        // frameTimeoutMs/2; a partial frame past the deadline drops the connection even
        // with no further appends. Cancelled with the read source (same queue — no race).
        let partialTimer = DispatchSource.makeTimerSource(queue: queue)
        partialTimer.schedule(deadline: .now() + .milliseconds(reader.frameTimeoutMs / 2),
                              repeating: .milliseconds(reader.frameTimeoutMs / 2))
        partialTimer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.reader.checkPartialTimeout() {
                self.log.warn("Client", "partial-frame timeout (timer) fd=\(self.fd)")
                self.send(error: .invalidRequest)
                self.readSource?.cancel()
            }
        }
        partialTimer.resume()
        self.partialTimer = partialTimer
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            // C-4: close + invalidate under the lock so a queued onReadable can never
            // operate a closed (or reused) fd.
            self.closeFd()
            // C-6: stop the partial-frame watchdog with the connection.
            self.partialTimer?.cancel()
            self.partialTimer = nil
            // Issue #25: a disconnected stream subscriber must not leak — drop every
            // subscription this connection held (frames would otherwise write to a
            // closed fd until the next close/reaper).
            self.streamHub?.unsubscribeAll(key: self.ownerId)
            self.log.info("Client", "disconnected fd=\(self.fd)")
            self.onDone(self)
        }
        source.resume()
        self.readSource = source
    }

    // M-7: synchronous teardown used by FBUDSServer.stop() — cancels the read source
    // (cancel handler closes the fd + releases from the server's client set) + the
    // partial-frame watchdog timer.
    func teardown() {
        readSource?.cancel()
        partialTimer?.cancel()
        partialTimer = nil
    }

    private func onReadable() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        // C-4 + #25: read inside the fd guard so a concurrent cancel cannot close/reuse the
        // number between the check and the syscall (nil = the socket is gone).
        let got: Int? = buf.withUnsafeMutableBufferPointer { ptr in
            socket.withFd { Darwin.read($0, ptr.baseAddress, ptr.count) }
        }
        guard let n = got else { readSource?.cancel(); return }
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
                // R-10: detect a system-caller token so the route passes nil ownerId and
                // SessionManager bypasses E-34 ownership (per-call-dial proxy case).
                self.isSystemCaller = auth.isSystemCaller(token: authMsg.token)
                self.connectionOwnerKey = auth.ownerKey(token: authMsg.token)
                log.info("Client", "auth ok caps=\(c.rawValue) systemCaller=\(isSystemCaller)")
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
        // R-10: effective owner is nil for a system-caller token (SessionManager bypass),
        // else this connection's UUID. System callers operate any session (proxy/scheduler).
        let effectiveOwner: String? = isSystemCaller ? nil : ownerId
        switch req {
        case .createSession(let r):
            // M-6 (1016 audit): createSession was rate-limit EXEMPT — a flood of creates
            // (each spawning a WKWebView + WebContent process) bypassed the limiter, the
            // fastest route to exhausting FR-08's session quota. Rate-gate it like .execute;
            // a rejected create consumes no token (same bucket-refill retry semantics).
            if let limiter = rateLimiter, !limiter.admit() {
                log.warn("Client", "rate_limited fd=\(fd) op=create_session")
                send(error: .rateLimited)
                return
            }
            // Issue #25: profileId admission (cap + token attribution). Fail-closed:
            // a system caller has no token identity, so it cannot own a profile.
            if let gateErr = FBProfileGate.check(profileId: r.profileId, caps: caps,
                                                 ownerKey: connectionOwnerKey) {
                log.warn("Client", "create profile gate denied code=\(gateErr.code) fd=\(fd)")
                send(error: gateErr)
                return
            }
            switch manager.create(req: r, traceId: req.traceId, ownerId: effectiveOwner,
                                  ownerKey: connectionOwnerKey) {
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
            switch manager.get(r.sessionId, ownerId: effectiveOwner) {
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
            let err = manager.close(sessionId: sid, ownerId: effectiveOwner)
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
        case .importCookies(let r):
            // Issue #25: cookie import touches the user's Keychain + browser profiles, so
            // it needs its OWN capability (.importCookies, NOT in .default).
            guard caps.contains(.importCookies) else { send(error: .authDenied); return }
            guard let kind = FBBrowserKind(rawValue: r.browser.lowercased()) else {
                log.warn("Client", "import_cookies unknown browser fd=\(fd)")
                send(error: .invalidRequest)
                return
            }
            switch manager.get(r.sessionId, ownerId: effectiveOwner) {
            case .failure(let e):
                send(error: e)
            case .success(let session):
                guard let wv = session.webview else { send(error: .sessionClosing); return }
                let importer = FBBrowserCookieImporter(config: manager.cookieImport) { [weak self] kind in
                    self?.cookieKey(kind)
                }
                guard case .success(let imported) = importer.importCookies(kind: kind, profile: r.profile) else {
                    send(error: .importDenied)
                    return
                }
                var injected = 0
                for cookie in imported.cookies {
                    let domain = cookie.attrs["domain"] ?? ""
                    if wv.injectCookies(cookie.attrs, domain: domain) { injected += 1 }
                }
                // Cookies read but rejected by WKWebView count as skipped, never as
                // imported — the response reports what the session actually holds.
                let failedInject = imported.cookies.count - injected
                log.info("Client", "import_cookies browser=\(kind.rawValue) read=\(imported.cookies.count) injected=\(injected) appBound=\(imported.skippedAppBound) other=\(imported.skippedOther + failedInject) sess=\(r.sessionId)")
                send(resp: .importCookies(ImportCookiesResponse(
                    sessionId: r.sessionId, browser: kind.rawValue, imported: injected,
                    skippedAppBound: imported.skippedAppBound,
                    skippedOther: imported.skippedOther + failedInject)))
            }
        case .streamScreenshots(let r):
            // Push needs .screenshot (same data class as the pull path) + an owner match.
            guard caps.contains(.screenshot) else { send(error: .authDenied); return }
            guard let hub = streamHub else { send(error: .invalidRequest); return }
            // Issue #25: the side panel subscribes from its OWN connection, so the
            // connection-UUID owner (E-34) cannot match. Streaming is read-only, so admit
            // the same PRINCIPAL (equal token hash) too — control stays UUID-scoped.
            switch manager.get(r.sessionId, ownerId: nil) {
            case .failure(let e):
                send(error: e)
            case .success(let session):
                guard let wv = session.webview else { send(error: .sessionClosing); return }
                guard FBStreamAccess.allowsRead(sessionOwnerId: session.ownerId,
                                                sessionOwnerKey: session.ownerKey,
                                                callerOwnerId: effectiveOwner,
                                                callerOwnerKey: connectionOwnerKey) else {
                    log.warn("Client", "stream_screenshots not_owner sess=\(r.sessionId) fd=\(fd)")
                    send(error: .notOwner)
                    return
                }
                if r.enabled {
                    // Ack BEFORE subscribing so the caller's first read is the ack (a
                    // capture-triggered frame can otherwise win the race on the socket).
                    send(resp: .streamAck(StreamAckResponse(sessionId: r.sessionId, active: true)))
                    let listeners = hub.subscribe(sessionId: r.sessionId, key: ownerId) { [weak self] data in
                        self?.writeAll(data)
                    }
                    log.info("Client", "stream_screenshots on sess=\(r.sessionId) listeners=\(listeners) fd=\(fd)")
                    // Immediate first frame so the panel is not blank until the next action.
                    hub.publish(sessionId: r.sessionId, webview: wv)
                } else {
                    hub.unsubscribe(sessionId: r.sessionId, key: ownerId)
                    log.info("Client", "stream_screenshots off sess=\(r.sessionId) fd=\(fd)")
                    send(resp: .streamAck(StreamAckResponse(sessionId: r.sessionId, active: false)))
                }
            }
        case .deleteProfile(let r):
            // Issue #25: a profile is login state — deleting another token's profile is
            // denied (profile_denied / not_owner). System callers may delete any profile.
            guard caps.contains(.persistentProfiles) else { send(error: .authDenied); return }
            guard isSystemCaller || connectionOwnerKey != nil else { send(error: .profileDenied); return }
            // Capture the store id BEFORE the registry entry is removed — the delete path
            // needs it to free the on-disk WebKit store after the fact.
            let entry = manager.profiles.entry(profileId: r.profileId)
            if let err = manager.profiles.delete(profileId: r.profileId,
                                                 ownerTokenHash: connectionOwnerKey ?? "",
                                                 isSystemCaller: isSystemCaller) {
                log.warn("Client", "delete_profile denied code=\(err.code) fd=\(fd)")
                send(error: err)
                return
            }
            manager.markProfileDeleted(profileId: r.profileId)
            if let storeId = entry?.storeId, let uuid = UUID(uuidString: storeId) {
                manager.purgeProfileStore(uuid: uuid)
            }
            log.info("Client", "delete_profile profileId=\(r.profileId) existed=\(entry != nil) fd=\(fd)")
            send(resp: .profileDeleted(ProfileDeletedResponse(profileId: r.profileId, deleted: entry != nil)))
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

    // Issue #25: derived cookie key per browser, cached for this connection so repeated
    // imports prompt the Keychain at most once. nil = key unavailable (encrypted rows skip).
    private func cookieKey(_ browser: FBBrowserKind) -> Data? {
        if let cached = cookieKeys[browser] { return cached }
        guard let password = FBBrowserKeychain.safeStoragePassword(kind: browser) else { return nil }
        let key = FBChromiumCookieCrypto.deriveKey(password: password)
        cookieKeys[browser] = key
        return key
    }

    private func sendAuthed() {
        let ack = AuthAck(caps: caps.rawValue)
        // M-5 (1016 audit): the old `try?` swallowed an encode failure — the client then
        // hung waiting for an auth_ack that never comes until its socket timeout. Fail
        // loud; the read source is cancelled so the client sees an EOF instead.
        do {
            let data = try FBFrame.encode(ack)
            writeAll(data)
        } catch {
            log.error("Client", "auth_ack encode failed: \(error)")
            readSource?.cancel()
        }
    }

    // P-2: bounded backpressure. fd is non-blocking; on EAGAIN we poll(POLLOUT) with a
    // per-call deadline instead of busy-spinning (usleep spin pins the queue thread
    // unbounded on a slow client). A client that never drains is dropped after the
    // deadline rather than starving the shared dispatch pool.
    private static let writeDeadlineMs: Int32 = 5000
    private func writeAll(_ data: Data) {
        // Serialize whole frames: stream pushes arrive on the hub capture thread while
        // responses come from this client's queue.
        writeLock.lock()
        defer { writeLock.unlock() }
        var sent = 0
        while sent < data.count {
            // C-4 + #25: the write syscall runs INSIDE the fd guard, so a concurrent cancel
            // cannot close (and a new accept cannot reuse) the number between the check and
            // the write. nil = the socket is gone; drop out without writing.
            let wrote: Int? = data.withUnsafeBytes { raw -> Int? in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: sent)
                return socket.withFd { Darwin.write($0, p, data.count - sent) }
            }
            guard let n = wrote else { return }
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
    // timeout (caller should drop the client) or poll error. poll only WATCHES the number —
    // the actual write re-validates under the guard (FBAtomicFd.withFd), so a close that
    // lands during the wait is picked up there instead of being written through.
    private func awaitWritable() -> Bool {
        let curFd = validFd()
        guard curFd >= 0 else { return false }
        var pfd = pollfd(fd: curFd, events: Int16(POLLOUT), revents: 0)
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
