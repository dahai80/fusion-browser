import XCTest
@testable import FusionBrowser

final class AuthTests: XCTestCase {
    func testValidTokenGetsDefaultCaps() {
        let auth = FBAuth(token: "secret-token")
        let caps = auth.authenticate(token: "secret-token")
        XCTAssertNotNil(caps)
        XCTAssertTrue(caps!.contains(.click))
        XCTAssertTrue(caps!.contains(.navigate))
        XCTAssertFalse(caps!.contains(.evaluate))
    }

    func testWrongTokenDenied() {
        let auth = FBAuth(token: "secret-token")
        XCTAssertNil(auth.authenticate(token: "wrong"))
    }

    func testNoTokenConfiguredDenied() {
        let auth = FBAuth(token: nil)
        XCTAssertNil(auth.authenticate(token: "anything"))
    }

    func testEvaluateOriginWhitelist() {
        let auth = FBAuth(token: "t")
        _ = auth.authenticate(token: "t")
        XCTAssertTrue(auth.canEvaluate(caps: .evaluate, origin: "https://example.com/login",
                                       allowedOrigins: ["https://example.com"]))
        XCTAssertFalse(auth.canEvaluate(caps: .evaluate, origin: "https://evil.com",
                                        allowedOrigins: ["https://example.com"]))
        XCTAssertFalse(auth.canEvaluate(caps: .default, origin: "https://example.com",
                                        allowedOrigins: []))
    }
}

final class SchedulerTests: XCTestCase {
    func testMaxActionsExceeded() {
        let g = FBSchedulingGuards(maxActions: 3, taskTimeoutMs: 60_000, repeatActionBreak: 99, rebuildDepthCap: 1)
        let s = FBScheduler(guards: g)
        XCTAssertEqual(s.admit(action: .scroll, target: nil, payload: nil), .accept)
        XCTAssertEqual(s.admit(action: .scroll, target: nil, payload: nil), .accept)
        XCTAssertEqual(s.admit(action: .scroll, target: nil, payload: nil), .accept)
        if case .rejectMaxActions = s.admit(action: .scroll, target: nil, payload: nil) {} else { XCTFail() }
    }

    func testRepeatActionBreak() {
        let g = FBSchedulingGuards(maxActions: 100, taskTimeoutMs: 60_000, repeatActionBreak: 3, rebuildDepthCap: 1)
        let s = FBScheduler(guards: g)
        for _ in 0..<2 { XCTAssertEqual(s.admit(action: .click, target: "@e1", payload: nil), .accept) }
        if case .rejectRepeatBreak = s.admit(action: .click, target: "@e1", payload: nil) {} else { XCTFail("3rd repeat must break") }
    }

    func testDifferentActionResetsRepeat() {
        let g = FBSchedulingGuards(maxActions: 100, taskTimeoutMs: 60_000, repeatActionBreak: 3, rebuildDepthCap: 1)
        let s = FBScheduler(guards: g)
        XCTAssertEqual(s.admit(action: .click, target: "@e1", payload: nil), .accept)
        XCTAssertEqual(s.admit(action: .click, target: "@e1", payload: nil), .accept)
        XCTAssertEqual(s.admit(action: .scroll, target: nil, payload: nil), .accept)
        XCTAssertEqual(s.admit(action: .click, target: "@e1", payload: nil), .accept)
    }

    func testRebuildDepthCap() {
        let g = FBSchedulingGuards(maxActions: 100, taskTimeoutMs: 60_000, repeatActionBreak: 99, rebuildDepthCap: 1)
        let s = FBScheduler(guards: g)
        XCTAssertTrue(s.canRebuild())
        XCTAssertFalse(s.canRebuild())
    }

    func testIdempotencyClassification() {
        XCTAssertTrue(FBScheduler.isIdempotent(.navigate))
        XCTAssertTrue(FBScheduler.isIdempotent(.scroll))
        XCTAssertTrue(FBScheduler.isIdempotent(.screenshot))
        XCTAssertFalse(FBScheduler.isIdempotent(.click))
        XCTAssertFalse(FBScheduler.isIdempotent(.typeText))
        XCTAssertFalse(FBScheduler.isIdempotent(.evaluate))
    }
}

final class ErrorModelTests: XCTestCase {
    func testErrorCodableRoundTrip() throws {
        let e = FBError(code: "node_stale", message: "x", retryable: true)
        let data = try JSONEncoder().encode(e)
        let d = try JSONDecoder().decode(FBError.self, from: data)
        XCTAssertEqual(e, d)
    }

    func testPredefinedErrorsDistinctCodes() {
        XCTAssertNotEqual(FBError.nodeStale.code, FBError.timeout.code)
        XCTAssertNotEqual(FBError.credentialLocked.code, FBError.credentialNotFound.code)
        XCTAssertTrue(FBError.nodeStale.retryable)
        XCTAssertFalse(FBError.evaluateDenied.retryable)
    }
}

final class QuotaTests: XCTestCase {
    func testHostQuotaScalesWithRAM() {
        let q = FBResourceQuota.forHost()
        XCTAssertGreaterThan(q.maxSessions, 0)
        XCTAssertLessThanOrEqual(q.maxSessions, 16)
        XCTAssertEqual(q.maxMemoryPerSessionMB, 150)
        XCTAssertEqual(q.maxTotalMemoryMB, q.maxSessions * 150)
    }

    // T3.2 acceptance: PRD tier table — 8GB node 4 session, 16GB node 10 session, over-limit reject.
    func testRAMTierTableDeterministic() {
        XCTAssertEqual(FBResourceQuota.forHost(ramGB: 4).maxSessions, 2)
        XCTAssertEqual(FBResourceQuota.forHost(ramGB: 7).maxSessions, 2)
        XCTAssertEqual(FBResourceQuota.forHost(ramGB: 8).maxSessions, 4, "8GB node must allow 4 sessions")
        XCTAssertEqual(FBResourceQuota.forHost(ramGB: 15).maxSessions, 4)
        XCTAssertEqual(FBResourceQuota.forHost(ramGB: 16).maxSessions, 10, "16GB node must allow 10 sessions")
        XCTAssertEqual(FBResourceQuota.forHost(ramGB: 31).maxSessions, 10)
        XCTAssertEqual(FBResourceQuota.forHost(ramGB: 32).maxSessions, 16)
        // Total memory = sessions * 150 in every tier.
        for gb in [4, 8, 16, 32, 64] {
            let q = FBResourceQuota.forHost(ramGB: gb)
            XCTAssertEqual(q.maxTotalMemoryMB, q.maxSessions * 150)
            XCTAssertEqual(q.maxWebContentProcesses, q.maxSessions)
        }
    }

    // T3.2 acceptance: over the session cap -> quota_exceeded, and the (n+1)-th
    // create does NOT burn a WKWebView alloc (pre-check rejects before main-thread create).
    func testOverSessionCapRejectsWithoutLeak() {
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300, maxWebContentProcesses: 2)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: [])
        let r1 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        let r2 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        if case .success = r1 {} else { XCTFail("1st create must succeed") }
        if case .success = r2 {} else { XCTFail("2nd create must succeed") }
        XCTAssertEqual(mgr.count(), 2)
        let r3 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        if case .failure(let e) = r3 {
            XCTAssertEqual(e.code, "quota_exceeded")
        } else {
            XCTFail("3rd create over cap must return quota_exceeded")
        }
        XCTAssertEqual(mgr.count(), 2, "rejected create must not add a session")
        for sid in mgr.listIds() { _ = mgr.close(sessionId: sid) }
    }

    // T3.2 acceptance: total-memory budget also rejects (perSession * count > cap).
    func testOverMemoryCapRejects() {
        // 3 sessions * 150 = 450 > 300 cap, so 3rd must reject.
        let q = FBResourceQuota(maxSessions: 10, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300, maxWebContentProcesses: 10)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: [])
        _ = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        _ = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        XCTAssertEqual(mgr.count(), 2)
        let r3 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        if case .failure(let e) = r3 {
            XCTAssertEqual(e.code, "quota_exceeded")
        } else {
            XCTFail("3rd create over memory cap must reject")
        }
        for sid in mgr.listIds() { _ = mgr.close(sessionId: sid) }
    }
}
