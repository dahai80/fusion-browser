import XCTest
import Network
@testable import FusionBrowser

// Integration smoke: SessionManager create/close lifecycle (no real WKWebView navigation,
// but exercises quota enforcement, scheduler reset, state transitions).

final class IntegrationTests: XCTestCase {
    private func makeManager(maxSessions: Int = 4) -> FBSessionManager {
        let q = FBResourceQuota(maxSessions: maxSessions, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: maxSessions * 150)
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

// E-21/E-22: session lifecycle lock + close barrier. webview is a lock-backed field (no
// data race between a reader thread and close()'s nil write); close() flips an atomic
// isClosing flag + nils the webview BEFORE the main-hop teardown so a concurrent execute
// fails fast instead of touching a half-destroyed WKWebView. These run under swift test
// (no live WKWebView navigation) — the close-barrier fast-fail path returns BEFORE any
// webview op, so the execute test exercises the gate without a live eval.
final class SessionLifecycleConcurrencyTests: XCTestCase {
    private func makeManager(maxSessions: Int = 4) -> FBSessionManager {
        let q = FBResourceQuota(maxSessions: maxSessions, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: maxSessions * 150)
        return FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                auth: FBAuth(token: "t"), allowedOrigins: [])
    }

    // E-21: hammer `session.webview` reads from a background thread while the main thread
    // closes() (nils the field under the webviewLock). The old plain `private(set) var` was
    // a data race (UB / Swift 6 compile error); the lock-backed getter/setter make this safe.
    // close() runs on the TEST thread (main) so destroy() takes the isMainThread direct path
    // (no main.sync — a main.sync from here while waitForExpectations spins the run loop is
    // safe, but direct is simplest). The background reader races the nil write. Must not
    // crash; final read is nil.
    func testWebfieldConcurrentReadAndCloseNoCrash() {
        let mgr = makeManager()
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil),
              let s = mgr.get(resp.sessionId) else {
            XCTFail("create must succeed"); return
        }
        let readerDone = XCTestExpectation(description: "reader done")
        DispatchQueue.global().async {
            for _ in 0..<2000 { _ = s.webview }
            readerDone.fulfill()
        }
        // close() on the main thread (test thread) -> isMainThread direct destroy, no main.sync.
        s.close()
        wait(for: [readerDone], timeout: 5.0)
        XCTAssertNil(s.webview, "close must nil the webview field")
        XCTAssertTrue(s.isClosing, "close must flip the is-closing flag")
    }

    // E-22: close() is terminal + idempotent. A second close() on an already-closing session
    // is a no-op (no double destroy, no second main-hop). isClosing stays true.
    func testCloseIsIdempotentAndSetsClosingFlag() {
        let mgr = makeManager()
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil),
              let s = mgr.get(resp.sessionId) else {
            XCTFail("create must succeed"); return
        }
        XCTAssertFalse(s.isClosing, "fresh session not closing")
        s.close()
        XCTAssertTrue(s.isClosing, "close flips isClosing")
        XCTAssertNil(s.webview, "close nils webview")
        // Second close must not crash / double-destroy.
        s.close()
        XCTAssertTrue(s.isClosing, "isClosing stays true after re-close")
    }

    // E-22: manager.get must NOT hand out a closing session. After close(sessionId:) the
    // session is removed from the dict, so get returns nil (sessionNotFound at the route).
    // The isClosing re-check is a belt-and-suspenders guard for the teardown window.
    func testGetReturnsNilForClosedSession() {
        let mgr = makeManager()
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil) else {
            XCTFail("create must succeed"); return
        }
        XCTAssertNotNil(mgr.get(resp.sessionId), "live session retrievable")
        XCTAssertNil(mgr.close(sessionId: resp.sessionId), "close succeeds")
        XCTAssertNil(mgr.get(resp.sessionId), "closed session not retrievable")
    }

    // E-22: the close-barrier fast-fails execute. Build a driver, create a session, close it
    // (isClosing=true, webview=nil), then call execute DIRECTLY on the closed session object.
    // The execute-entry re-check returns sessionClosing BEFORE touching the (nil) webview, so
    // no WKWebView eval runs — safe under swift test (no main run loop needed for the gate).
    func testExecuteOnClosingSessionFailsFast() {
        let mgr = makeManager()
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil),
              let s = mgr.get(resp.sessionId) else {
            XCTFail("create must succeed"); return
        }
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: FBAuth(token: "t"),
                                    allowedOrigins: [], sanitizer: FBSanitizer())
        // Capture the session, THEN close so the object is still held but isClosing=true.
        s.close()
        XCTAssertTrue(s.isClosing)
        let req = BrowserActionRequest(sessionId: s.id, action: .screenshot, traceId: "t-closing")
        // H-5: execute() now takes the token's caps. Pass .all so the cap gate passes and the
        // test reaches the E-22 close-barrier (the point under test). A scoped token would
        // fail at the cap gate first — covered separately in CapabilityTests.
        let state = driver.execute(session: s, req: req, caps: .all)
        XCTAssertNotNil(state.error, "execute on closing session must error")
        XCTAssertEqual(state.error?.code, "session_closing",
                       "must fail fast with session_closing, not touch the webview")
    }
}

// H-5: capability-model enforcement. execute() must take the token's actual caps and enforce
// the per-action cap as the authoritative gate (the old hardcoded `.all` let a navigate-only
// scoped token EVALUATE). These run under swift test — the cap gate fails fast BEFORE the
// scheduler/webview are touched, so no live WKWebView eval runs (ARCH-3 safe).
final class CapabilityEnforcementTests: XCTestCase {
    private func makeManager(maxSessions: Int = 4) -> FBSessionManager {
        let q = FBResourceQuota(maxSessions: maxSessions, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: maxSessions * 150)
        return FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                auth: FBAuth(token: "t"), allowedOrigins: [])
    }

    // A token with the DEFAULT caps (navigate/click/type/scroll/screenshot/close — NO .evaluate)
    // must be DENIED evaluate with evaluateDenied, even on a live allowlisted origin. This is
    // the core H-5 contract: a scoped token cannot EVALUATE. Fails at the cap gate, no webview.
    func testScopedTokenDeniedEvaluate() {
        let mgr = makeManager()
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil),
              let s = mgr.get(resp.sessionId) else {
            XCTFail("create must succeed"); return
        }
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: FBAuth(token: "t"),
                                    allowedOrigins: ["https://example.com"], sanitizer: FBSanitizer())
        let req = BrowserActionRequest(sessionId: s.id, action: .evaluate,
                                       payloadText: "document.cookie", traceId: "t-eval")
        // .default lacks .evaluate (confirmed in AuthTests).
        let state = driver.execute(session: s, req: req, caps: FBCapabilities.default)
        XCTAssertNotNil(state.error, "scoped token must be denied evaluate")
        XCTAssertEqual(state.error?.code, "evaluate_denied",
                       "default-caps token -> evaluate_denied at the cap gate, not origin")
    }

    // A token MISSING .click must be denied click with authDenied (generic per-action denial,
    // distinct from evaluate's own code). Fails at the cap gate before node resolution.
    func testMissingClickCapDeniedAuth() {
        let mgr = makeManager()
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil),
              let s = mgr.get(resp.sessionId) else {
            XCTFail("create must succeed"); return
        }
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: FBAuth(token: "t"),
                                    allowedOrigins: [], sanitizer: FBSanitizer())
        let req = BrowserActionRequest(sessionId: s.id, action: .click,
                                       targetNodeId: "e1", traceId: "t-click")
        // Caps with navigate+scroll but NOT click.
        let capsNoClick: FBCapabilities = [.navigate, .scroll, .screenshot]
        let state = driver.execute(session: s, req: req, caps: capsNoClick)
        XCTAssertNotNil(state.error, "token without .click must be denied click")
        XCTAssertEqual(state.error?.code, "auth_denied",
                       "missing non-evaluate cap -> auth_denied")
    }

    // A token with .all (full caps) passes the cap gate — this is the legitimate full-token
    // path. Evaluate then falls through to the origin check (empty allowlist -> evaluate_denied
    // at the origin half). Confirms the cap gate does NOT spuriously deny a full token.
    func testFullCapsPassesCapGate() {
        let mgr = makeManager()
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil),
              let s = mgr.get(resp.sessionId) else {
            XCTFail("create must succeed"); return
        }
        // Empty allowlist -> evaluate denied at the ORIGIN gate (not the cap gate).
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: FBAuth(token: "t"),
                                    allowedOrigins: [], sanitizer: FBSanitizer())
        let req = BrowserActionRequest(sessionId: s.id, action: .evaluate,
                                       payloadText: "1+1", traceId: "t-eval2")
        let state = driver.execute(session: s, req: req, caps: .all)
        // .all passes the cap gate; empty allowlist denies at origin -> evaluate_denied.
        XCTAssertEqual(state.error?.code, "evaluate_denied",
                       "full caps pass cap gate; empty allowlist denies at origin")
    }

    // Empty caps (no client authed, e.g. CDP before WS upgrade) denies EVERY action. This is
    // the fail-closed contract for the CDP path: currentCaps() returns [] until a client auths.
    func testEmptyCapsDeniesAll() {
        let mgr = makeManager()
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil),
              let s = mgr.get(resp.sessionId) else {
            XCTFail("create must succeed"); return
        }
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: FBAuth(token: "t"),
                                    allowedOrigins: [], sanitizer: FBSanitizer())
        let req = BrowserActionRequest(sessionId: s.id, action: .navigate,
                                       payloadText: "https://example.com", traceId: "t-nav")
        let state = driver.execute(session: s, req: req, caps: [])
        XCTAssertNotNil(state.error, "empty caps must deny navigate")
        XCTAssertEqual(state.error?.code, "auth_denied", "no caps -> auth_denied (fail-closed)")
    }
}
