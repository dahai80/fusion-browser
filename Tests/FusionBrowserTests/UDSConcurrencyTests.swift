import XCTest
@testable import FusionBrowser

// T-1 (1016 audit, issue #22): deterministic UDS concurrency coverage. Real AF_UNIX
// socket, real FBUDSServer, no WKWebView session driven (auth/framing/close paths
// only — no ARCH-3 conflict). Exercises: acceptOnce + onReadable + framing round-trip,
// auth fail-closed, B-4 partial-frame assembly across drips, M-7 stop() teardown.
final class UDSConcurrencyTests: XCTestCase {
    private var sock: String!
    private var server: FBUDSServer?

    override func setUp() {
        super.setUp()
        sock = "/tmp/fb-test-uds-\(UUID().uuidString).sock"
        let q = FBResourceQuota(maxSessions: 4, maxMemoryPerSessionMB: 150, maxTotalMemoryMB: 600)
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: FBAuth(token: "t"), allowedOrigins: [])
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: FBAuth(token: "t"),
                                    allowedOrigins: [], sanitizer: FBSanitizer())
        server = FBUDSServer(socketPath: sock, manager: mgr, driver: driver,
                             auth: FBAuth(token: "t"), rateLimit: FBRateLimitConfig(enabled: false))
        try? server?.start()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: sock)
        super.tearDown()
    }

    private func connect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = Data(sock.utf8)
        pathData.withUnsafeBytes { raw in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: raw.baseAddress, count: min(raw.count, 100)))
            }
        }
        let r = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertGreaterThanOrEqual(r, 0, "connect failed errno=\(errno)")
        return fd
    }

    // Send one wire frame: [u32 BE len][JSON]. `drip` splits the frame into 1-byte
    // chunks with tiny sleeps to exercise partial-frame assembly.
    private func sendFrame(_ fd: Int32, _ o: [String: Any], drip: Bool = false) {
        let data = try! JSONSerialization.data(withJSONObject: o)
        var len = UInt32(data.count).bigEndian
        let frame = withUnsafeBytes(of: &len) { Data($0) } + data
        if drip {
            for b in frame {
                var byte = b
                _ = withUnsafeBytes(of: &byte) { Darwin.send(fd, $0.baseAddress, 1, 0) }
                usleep(200)
            }
        } else {
            frame.withUnsafeBytes { raw in
                _ = Darwin.send(fd, raw.baseAddress, raw.count, 0)
            }
        }
    }

    // Receive exactly `count` bytes into `out` (false = closed/timeout).
    private func recvN(_ fd: Int32, _ out: inout [UInt8], count: Int, deadline: Date) -> Bool {
        var got = 0
        while got < count {
            guard Date() < deadline else { return false }
            let n = out.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.recv(fd, base.advanced(by: got), count - got, 0)
            }
            if n <= 0 { return false }
            got += n
        }
        return true
    }

    // Receive one wire frame (nil = connection closed / no frame).
    private func recvFrame(_ fd: Int32, timeoutMs: Int = 2_000) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var buf = [UInt8](repeating: 0, count: 4)
        guard recvN(fd, &buf, count: 4, deadline: deadline) else { return nil }
        var len: UInt32 = 0
        for b in buf { len = (len << 8) | UInt32(b) }
        var body = [UInt8](repeating: 0, count: Int(len))
        guard recvN(fd, &body, count: Int(len), deadline: deadline) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }

    // Auth + framing round-trip: real acceptOnce + onReadable + sendAuthed path.
    func testAuthRoundTrip() {
        let fd = connect()
        sendFrame(fd, ["type": "auth", "token": "t"])
        let r = recvFrame(fd)
        XCTAssertEqual(r?["type"] as? String, "auth_ack", "auth must round-trip the real UDS stack")
        close(fd)
    }

    // Auth fail-closed: wrong token -> ONE error frame (auth_denied) then the connection
    // closes. The engine sends the structured error BEFORE cancelling the read source
    // (send is a synchronous writeAll, so the frame always lands), then drops the fd —
    // the second recv must observe the close (nil).
    func testWrongTokenClosed() {
        let fd = connect()
        sendFrame(fd, ["type": "auth", "token": "wrong"])
        let r = recvFrame(fd)
        XCTAssertEqual(r?["type"] as? String, "error", "bad token must surface a structured error, not silence")
        XCTAssertEqual((r?["payload"] as? [String: Any])?["code"] as? String, "auth_denied")
        XCTAssertNil(recvFrame(fd), "connection must close after the auth error frame")
        close(fd)
    }

    // B-4/T-1: a frame dripped 1 byte at a time still assembles (partial-frame path).
    func testDrippedFrameAssembles() {
        let fd = connect()
        sendFrame(fd, ["type": "auth", "token": "t"], drip: true)
        let r = recvFrame(fd)
        XCTAssertEqual(r?["type"] as? String, "auth_ack", "1-byte-drip frame must assemble")
        close(fd)
    }

    // T-1: multiple clients concurrently — acceptOnce interleaves, each gets its own auth_ack.
    func testConcurrentClients() {
        var fds: [Int32] = []
        for _ in 0..<4 { fds.append(connect()) }
        for fd in fds { sendFrame(fd, ["type": "auth", "token": "t"]) }
        for fd in fds {
            XCTAssertEqual(recvFrame(fd)?["type"] as? String, "auth_ack",
                           "each concurrent client must get auth_ack")
        }
        for fd in fds { close(fd) }
    }

    // M-7: stop() with a live client tears down without hanging the caller.
    func testStopWithLiveClient() {
        let fd = connect()
        sendFrame(fd, ["type": "auth", "token": "t"])
        XCTAssertEqual(recvFrame(fd)?["type"] as? String, "auth_ack")
        // Fresh server instance torn down mid-connection; must return promptly.
        let t0 = Date()
        server?.stop()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0, "stop() must not hang on live clients")
        close(fd)
    }
}

// T-3 (1016 audit, issue #22): SessionManager concurrency. ARCH-3 note: the ORIGINAL
// churn test (24 threads create+close real WKWebViews) is FORBIDDEN in the unit target —
// SessionManager.create main-hops webview construction via DispatchQueue.main.sync while
// the test method blocks the main thread on group.wait -> guaranteed 60s deadlock (no
// main run loop under swift test), and CI's macos-15 unit job has no GUI session. The
// live-path residue invariant (concurrent churn leaves zero sessions + quota released)
// is verified by the release_gate live harnesses against the real binary. What IS
// deterministically testable here: the concurrent close/get API surface on unknown ids
// must complete without hang/corruption.
final class SessionManagerConcurrencyTests: XCTestCase {
    private func makeManager(maxSessions: Int = 32) -> FBSessionManager {
        let q = FBResourceQuota(maxSessions: maxSessions, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: maxSessions * 150)
        return FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                auth: FBAuth(token: "t"), allowedOrigins: [])
    }

    // 24 threads hammer close/get on unknown ids concurrently — the queue-locked dict
    // surface must not hang, crash, or corrupt state (count stays 0).
    func testConcurrentCloseUnknownNoHang() {
        let mgr = makeManager()
        let group = DispatchGroup()
        for i in 0..<24 {
            group.enter()
            DispatchQueue.global().async {
                _ = mgr.close(sessionId: "unknown-\(i)")
                _ = mgr.get("unknown-\(i)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success,
                       "concurrent close/get on unknown ids must complete")
        XCTAssertEqual(mgr.count(), 0, "no state may appear from failed lookups")
    }
}
