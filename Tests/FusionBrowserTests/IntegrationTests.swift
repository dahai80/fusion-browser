import XCTest
import Network
@testable import FusionBrowser

// Integration smoke: SessionManager create/close lifecycle (no real WKWebView navigation,
// but exercises quota enforcement, scheduler reset, state transitions).

final class IntegrationTests: XCTestCase {
    private func makeManager(maxSessions: Int = 4) -> FBSessionManager {
        let q = FBResourceQuota(maxSessions: maxSessions, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: maxSessions * 150, maxWebContentProcesses: maxSessions)
        return FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                auth: FBAuth(token: "t"), allowedOrigins: [])
    }

    func testCreateAndClose() {
        let mgr = makeManager()
        let res = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: "trace1")
        if case .success(let cr) = res {
            XCTAssertFalse(cr.sessionId.isEmpty)
            XCTAssertEqual(mgr.count(), 1)
            XCTAssertNil(mgr.close(sessionId: cr.sessionId))
            XCTAssertEqual(mgr.count(), 0)
        } else { XCTFail("create failed") }
    }

    func testQuotaExceeded() {
        let mgr = makeManager(maxSessions: 1)
        _ = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        let res2 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        if case .failure(let e) = res2 {
            XCTAssertEqual(e.code, "quota_exceeded")
        } else { XCTFail("expected quota_exceeded") }
    }

    func testCloseUnknownSession() {
        let mgr = makeManager()
        let err = mgr.close(sessionId: "nope")
        XCTAssertNotNil(err)
        XCTAssertEqual(err?.code, "session_not_found")
    }
}
