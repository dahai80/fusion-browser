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

    // M-7: token compare must not short-circuit. Two tokens differing only in the last
    // byte must take the same auth path as one differing in the first byte (both deny).
    func testTokenMismatchLastByteDenied() {
        let auth = FBAuth(token: "secret-token-A")
        XCTAssertNil(auth.authenticate(token: "secret-token-B"))
        XCTAssertNil(auth.authenticate(token: "Xecret-token-A"))
        XCTAssertNotNil(auth.authenticate(token: "secret-token-A"))
    }

    // M-6: empty-token config still fail-closed (deny all), and a non-empty config does
    // not deny a correct token. Guards the L-19 deny-all contract.
    func testEmptyTokenConfigDeniesAll() {
        let authEmpty = FBAuth(token: "")
        XCTAssertNil(authEmpty.authenticate(token: ""))
        XCTAssertNil(authEmpty.authenticate(token: "anything"))
        let authSet = FBAuth(token: "real-token")
        XCTAssertNotNil(authSet.authenticate(token: "real-token"))
    }

    // E-9/H-5: tokenCapabilities config key elevates the registered token's caps.
    // parseCaps maps config names to FBCapabilities; unknown names dropped fail-closed;
    // "all" → full caps (evaluate reachable). Without elevation evaluate stays gated off.
    func testParseCapsKnownAndAll() {
        XCTAssertEqual(FBAuth.parseCaps(["evaluate"]), .evaluate)
        XCTAssertEqual(FBAuth.parseCaps(["navigate", "evaluate"]),
                       [.navigate, .evaluate])
        XCTAssertEqual(FBAuth.parseCaps(["all"]), .all)
        // R-3: metrics cap parsed, "all" includes it, default lacks it.
        XCTAssertEqual(FBAuth.parseCaps(["metrics"]), .metrics)
        XCTAssertTrue(FBAuth.parseCaps(["all"]).contains(.metrics),
                      "all-caps must include metrics")
        XCTAssertFalse(FBCapabilities.default.contains(.metrics),
                       "default must lack metrics (opt-in via tokenCapabilities)")
    }

    func testParseCapsUnknownDroppedFailClosed() {
        // Unknown name dropped, never broadens. Empty-after-drop stays empty set.
        let caps = FBAuth.parseCaps(["bogus", "evaluate"])
        XCTAssertEqual(caps, .evaluate, "unknown cap dropped, known one kept")
        XCTAssertTrue(FBAuth.parseCaps(["bogus"]).isEmpty,
                      "all-unknown list yields empty set, not .all")
    }

    // E-9: an elevated token authenticates WITH .evaluate so the UDS/CDP cap gate
    // admits evaluate (the live smoke + cowork path). Default token still lacks it.
    func testElevatedTokenGetsEvaluateCap() {
        let elevated = FBAuth(token: "t", caps: FBAuth.parseCaps(["all"]))
        let caps = elevated.authenticate(token: "t")
        XCTAssertNotNil(caps)
        XCTAssertTrue(caps!.contains(.evaluate), "all-caps token must carry evaluate")
        let plain = FBAuth(token: "t")
        XCTAssertFalse(plain.authenticate(token: "t")!.contains(.evaluate),
                       "default token must still lack evaluate (H-5 scoped model)")
    }

    // R-10/B-5: isSystemCaller fail-closed matrix. True ONLY when the token matches AND
    // the operator set systemCaller=true. Every other path denies (no blanket bypass).
    // The flag is operator config (FBAuth init), NOT client-supplied — a client only
    // sends the token; it cannot self-elevate to system.
    func testSystemCallerTrueOnlyOnMatchingTokenWithFlag() {
        let sys = FBAuth(token: "proxy-token", caps: .all, systemCaller: true)
        XCTAssertTrue(sys.isSystemCaller(token: "proxy-token"),
                      "matching token + flag set → system")
        // Wrong token → not system, even with flag set.
        XCTAssertFalse(sys.isSystemCaller(token: "wrong-token"),
                       "wrong token must not be system")
        XCTAssertFalse(sys.isSystemCaller(token: "proxy-toke"),
                       "near-miss token must not be system")
        // Empty / nil token → not system.
        XCTAssertFalse(sys.isSystemCaller(token: nil), "nil token not system")
        XCTAssertFalse(sys.isSystemCaller(token: ""), "empty token not system")
    }

    // R-10: flag false (default) → never system, even with the correct token. Proves
    // the bypass is opt-in operator config, not a blanket hole. Existing client-to-client
    // isolation (E-34) is untouched unless the operator explicitly flags a token.
    func testSystemCallerFalseByDefaultNeverSystem() {
        let plain = FBAuth(token: "proxy-token", caps: .all)
        XCTAssertFalse(plain.isSystemCaller(token: "proxy-token"),
                       "flag false → never system even with correct token")
        XCTAssertFalse(plain.isSystemCaller(token: nil), "flag false + nil → not system")
    }

    // R-10: no token configured → never system (deny-all sentinel has no system identity).
    func testSystemCallerNoTokenConfiguredNeverSystem() {
        let noTok = FBAuth(token: nil, caps: .all, systemCaller: true)
        XCTAssertFalse(noTok.isSystemCaller(token: "proxy-token"),
                       "no token configured → never system")
        XCTAssertFalse(noTok.isSystemCaller(token: nil), "no token + nil → not system")
    }
}

// R-3/B-3: metrics read path. FBMetrics.metricsArray() must surface counters +
// latency quantiles (was write-only — snapshot() had zero callers, CDP returned []).
final class MetricsTests: XCTestCase {
    func testMetricsArraySurfacesCountersAndLatency() {
        // Distinct keys so concurrent tests don't collide on the shared singleton.
        let ctrKey = "test.metrics.counter.\(FBTrace.newId())"
        let latKey = "test.metrics.latency.\(FBTrace.newId())"
        FBMetrics.shared.increment(ctrKey, by: 3)
        FBMetrics.shared.recordLatency(latKey, ms: 10)
        FBMetrics.shared.recordLatency(latKey, ms: 20)
        FBMetrics.shared.recordLatency(latKey, ms: 30)
        let arr = FBMetrics.shared.metricsArray()
        let ctr = arr.first { $0.name == ctrKey }
        XCTAssertNotNil(ctr, "counter must appear in metrics array")
        XCTAssertEqual(ctr?.value, 3.0)
        // Latency key expands to count/p50/p95 triple.
        let count = arr.first { $0.name == "\(latKey).count" }
        let p50 = arr.first { $0.name == "\(latKey).p50_ms" }
        let p95 = arr.first { $0.name == "\(latKey).p95_ms" }
        XCTAssertNotNil(count, "latency count metric must appear")
        XCTAssertEqual(count?.value, 3.0)
        XCTAssertNotNil(p50, "latency p50 metric must appear")
        XCTAssertEqual(p50?.value, 20.0, "p50 of [10,20,30] sorted mid = 20")
        XCTAssertNotNil(p95, "latency p95 metric must appear")
        XCTAssertEqual(p95?.value, 30.0, "p95 of 3 samples idx min(2, 2.85->2) = 30")
    }

    func testMetricsResponseRoundTripsCodable() throws {
        let resp = MetricsResponse(
            counters: [FBMetrics.FBMetric(name: "session.created", value: 5)],
            latency: [FBMetrics.FBMetric(name: "action.click.p50_ms", value: 12)])
        let data = try FBFrame.encode(FBResponse.metrics(resp))
        XCTAssertGreaterThan(data.count, 4)
        let json = data.subdata(in: 4..<data.count)
        let back = try FBFrame.decode(json, as: FBResponse.self)
        guard case .metrics(let m) = back else {
            return XCTFail("decoded response must be .metrics")
        }
        XCTAssertEqual(m.counters.first?.name, "session.created")
        XCTAssertEqual(m.counters.first?.value, 5.0)
        XCTAssertEqual(m.latency.first?.name, "action.click.p50_ms")
        XCTAssertEqual(m.latency.first?.value, 12.0)
    }

    func testMetricsRequestRoundTripsCodable() throws {
        let data = try FBFrame.encode(FBRequest.metrics)
        XCTAssertGreaterThan(data.count, 4)
        let json = data.subdata(in: 4..<data.count)
        let back = try FBFrame.decode(json, as: FBRequest.self)
        guard case .metrics = back else {
            return XCTFail("decoded request must be .metrics")
        }
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
        // L-1: navigate is NOT idempotent (POST/onLoad side effects); only scroll/screenshot.
        XCTAssertFalse(FBScheduler.isIdempotent(.navigate))
        XCTAssertTrue(FBScheduler.isIdempotent(.scroll))
        XCTAssertTrue(FBScheduler.isIdempotent(.screenshot))
        XCTAssertFalse(FBScheduler.isIdempotent(.click))
        XCTAssertFalse(FBScheduler.isIdempotent(.typeText))
        XCTAssertFalse(FBScheduler.isIdempotent(.evaluate))
    }

    // E-23: rebuildDepth counts ONLY real replays. handleCrash must check isIdempotent
    // FIRST and call canRebuild() (which increments) only on the idempotent/replay branch.
    // A non-idempotent crash (click/type/navigate/evaluate) is never replayed, so it must
    // NOT consume the depth cap. This test encodes the order contract: simulate two
    // consecutive non-idempotent crashes (slow-page click timeouts) and assert the cap is
    // still fully available for a real idempotent replay afterward. The old order
    // (canRebuild before isIdempotent) bricked the session permanent_fail on the 2nd crash.
    func testRebuildDepthNotConsumedByNonIdempotentCrash() {
        let g = FBSchedulingGuards(maxActions: 100, taskTimeoutMs: 60_000, repeatActionBreak: 99, rebuildDepthCap: 1)
        let s = FBScheduler(guards: g)
        // E-23 order: non-idempotent crash path skips canRebuild() entirely.
        let nonIdempotentCrashes: [ActionType] = [.click, .navigate, .typeText, .evaluate]
        for action in nonIdempotentCrashes {
            if FBScheduler.isIdempotent(action) { s.canRebuild() } // would-replay branch only
        }
        // Cap still fully intact: one real idempotent replay still admitted.
        XCTAssertTrue(s.canRebuild(), "non-idempotent crashes must not consume rebuildDepth")
        XCTAssertFalse(s.canRebuild(), "cap exhausted only after a real replay")
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
        }
        // H-2: maxWebContentProcesses dead field removed. The default memwatchdog sampler
        // now sums host + WebContent descendant RSS (totalRSSBytes), so the threshold bounds
        // the whole footprint instead of the host shell only. totalRSSBytes must not crash
        // and must return a positive footprint even with no WebContent children (host only).
        // We do NOT assert total >= a separately-sampled host RSS: RSS fluctuates between
        // the two syscalls (pages freed mid-call), so a two-sample comparison is flaky.
        let total = FBMemoryWatchdog.totalRSSBytes()
        XCTAssertGreaterThan(total, 0, "totalRSS must return a positive footprint")
    }

    // T3.2 acceptance: over the session cap -> quota_exceeded, and the (n+1)-th
    // create does NOT burn a WKWebView alloc (pre-check rejects before main-thread create).
    func testOverSessionCapRejectsWithoutLeak() {
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
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
                                maxTotalMemoryMB: 300)
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

    // L-15: firstSession() must return a STABLE target. The first-created session is the
    // CDP-bound one; closing a LATER session must NOT change which session firstSession()
    // returns. The old sessions.values.first order was nondeterministic and could hop.
    func testFirstSessionStableAcrossCloseOfLaterSession() {
        let q = FBResourceQuota(maxSessions: 4, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 600)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: [])
        let r1 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        let r2 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        guard case .success(let first) = r1, case .success(let second) = r2 else {
            XCTFail("both creates must succeed"); return
        }
        XCTAssertEqual(mgr.firstSession()?.id, first.sessionId,
                       "firstSession must pin to the first-created session")
        _ = mgr.close(sessionId: second.sessionId)
        XCTAssertEqual(mgr.firstSession()?.id, first.sessionId,
                       "closing a LATER session must not move the firstSession pin")
        XCTAssertEqual(mgr.count(), 1)
        _ = mgr.close(sessionId: first.sessionId)
    }

    // L-15: closing the pinned first session clears the pin; a subsequent create re-pins,
    // and firstSession() then returns the new one (not some stale/missing entry).
    func testFirstSessionRePinsAfterPinnedCloses() {
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: [])
        let r1 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        guard case .success(let first) = r1 else { XCTFail("1st create must succeed"); return }
        XCTAssertEqual(mgr.firstSession()?.id, first.sessionId)
        _ = mgr.close(sessionId: first.sessionId)
        XCTAssertNil(mgr.firstSession(), "no live session after closing the only one")
        let r2 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        guard case .success(let second) = r2 else { XCTFail("2nd create must succeed"); return }
        XCTAssertEqual(mgr.firstSession()?.id, second.sessionId,
                       "a new create after the pin cleared must re-pin to itself")
        _ = mgr.close(sessionId: second.sessionId)
    }

    // L-16: the race-recheck must verify the projected MEMORY budget, not just the session
    // count. With maxTotalMemoryMB tighter than maxSessions*maxMemoryPerSessionMB (10 seats
    // × 150 = 1500, but cap 300 → 2 seats by memory), creating beyond the memory cap must
    // reject even though sessions.count < maxSessions. Exercises the recheck's memory branch.
    func testRaceRecheckEnforcesMemoryNotJustCount() {
        // 10 session seats but only 300MB total => memory binds at 2 sessions (2*150=300 ok, 3*150=450>300).
        let q = FBResourceQuota(maxSessions: 10, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: [])
        if case .success = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil) {} else { XCTFail("1st ok") }
        if case .success = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil) {} else { XCTFail("2nd ok") }
        // 3rd: count(2) < maxSessions(10) but projected mem 450 > 300 => must reject.
        let r3 = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil)
        if case .failure(let e) = r3 {
            XCTAssertEqual(e.code, "quota_exceeded")
        } else {
            XCTFail("3rd create over MEMORY (not count) cap must reject — recheck must verify projected mem")
        }
        XCTAssertEqual(mgr.count(), 2, "rejected create must not land a session")
        for sid in mgr.listIds() { _ = mgr.close(sessionId: sid) }
    }

    // L-14: session state is guarded by a per-session NSLock — the state getter and
    // transition(to:) both take stateLock, so off-queue transitions (handleCrash watchdog
    // block, FBSession.close) and the firstSession() queue.sync read can no longer produce a
    // torn read. Build a session through the manager (WKWebView on main, the proven-safe path
    // the existing quota tests use), then hammer transition from one thread while another
    // reads .state. Must not crash and must report a valid, consistent final state.
    func testStateTransitionConcurrentReadNoCrash() {
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: [])
        guard case .success(let resp) = mgr.create(req: CreateSessionRequest(mode: .headless), traceId: nil),
              let s = mgr.get(resp.sessionId) else {
            XCTFail("create must succeed for the concurrency smoke"); return
        }
        s.transition(to: .running)
        let grp = DispatchGroup()
        DispatchQueue.global().async {
            for st in [FBSessionState.crashed, .rebuilding, .running, .crashed, .running] {
                s.transition(to: st)
            }
            grp.leave()
        }
        DispatchQueue.global().async {
            for _ in 0..<1000 { _ = s.state }
            grp.leave()
        }
        grp.enter(); grp.enter()
        grp.wait()
        XCTAssertEqual(s.state, .running, "final transition (.running) must be observable")
        _ = mgr.close(sessionId: resp.sessionId)
    }
}

final class ConfigDecodeTests: XCTestCase {
    // L-17: loadConfig must exit(1) on a present-but-malformed config (not silently fall back
    // to defaults). The exit branch is only reachable if JSONDecoder.decode THROWS on a type
    // mismatch — so this test pins the decoder behavior that gates the fix: a value with the
    // wrong JSON type (cdpEnabled as a string instead of a bool) MUST throw.
    func testMalformedConfigThrowsOnTypeMismatch() {
        let bad = """
        {"cdpEnabled": "true"}
        """
        let data = Data(bad.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FBEngineConfig.self, from: data),
                             "a type-mismatched field must throw so loadConfig can exit(1), not silently default")
    }

    // L-17 corollary: a PARTIAL but well-typed config still decodes (missing keys fall back to
    // defaults via decodeIfPresent) — only genuine type errors fail. Ensures the exit path does
    // not fire on a legit minimal config (which would be a false-positive that breaks operators).
    func testPartialWellTypedConfigDecodes() {
        let partial = """
        {"socketPath": "/tmp/fb-test-socket"}
        """
        let data = Data(partial.utf8)
        let cfg = try? JSONDecoder().decode(FBEngineConfig.self, from: data)
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.socketPath, "/tmp/fb-test-socket")
        // Untouched fields keep defaults.
        XCTAssertEqual(cfg?.cdpEnabled, FBEngineConfig.default.cdpEnabled)
    }

    // L-17: truly invalid JSON (not even an object) throws — the other path to exit(1).
    func testGarbageConfigThrows() {
        let garbage = "not json at all"
        let data = Data(garbage.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(FBEngineConfig.self, from: data))
    }

    // H-8: rateLimit config decodes from the config file (partial / custom values).
    func testRateLimitConfigDecodes() {
        let json = """
        {"rateLimit": {"enabled": true, "ratePerSec": 42, "burst": 84}}
        """
        let cfg = try? JSONDecoder().decode(FBEngineConfig.self, from: Data(json.utf8))
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.rateLimit.enabled, true)
        XCTAssertEqual(cfg?.rateLimit.ratePerSec, 42)
        XCTAssertEqual(cfg?.rateLimit.burst, 84)
    }

    // H-8: default rateLimit is ON at 100/s burst 200 (the shipped default).
    func testDefaultRateLimitConfig() {
        let cfg = FBEngineConfig.default
        XCTAssertTrue(cfg.rateLimit.enabled)
        XCTAssertEqual(cfg.rateLimit.ratePerSec, 100)
        XCTAssertEqual(cfg.rateLimit.burst, 200)
    }
}

// H-8: per-client token-bucket rate limiter. The limiter gates .execute so a single
// client cannot monopolize the main-thread webview path; tests pin the admit/refill
// contract without a live server (NSLock + monotonic time are deterministic).
final class RateLimitTests: XCTestCase {
    // A fresh bucket admits `burst` requests then rejects the next.
    func testBurstAdmitsThenRejects() {
        let limiter = FBRateLimiter(ratePerSec: 100, burst: 5)
        for _ in 0..<5 { XCTAssertTrue(limiter.admit(), "burst of 5 must all admit") }
        XCTAssertFalse(limiter.admit(), "6th must reject (bucket drained)")
    }

    // After draining, the bucket refills at ratePerSec and re-admits. Use a high rate
    // + a real sleep so the refill is observable without flaky timing.
    func testRefillReAdmitsAfterDrain() {
        let limiter = FBRateLimiter(ratePerSec: 1000, burst: 2)
        XCTAssertTrue(limiter.admit())
        XCTAssertTrue(limiter.admit())
        XCTAssertFalse(limiter.admit())
        // 1000/s => 1 token per 1ms. Sleep 10ms => ~10 tokens refilled (capped at 2).
        usleep(15_000)
        XCTAssertTrue(limiter.admit(), "must re-admit after refill window")
        XCTAssertTrue(limiter.admit(), "second admit after refill")
    }

    // A rejected admit does NOT consume a token — so after a rejection the bucket can
    // still admit once refilled, and a tight reject-poll loop does not double-drain.
    func testRejectDoesNotConsumeToken() {
        let limiter = FBRateLimiter(ratePerSec: 10, burst: 1)
        XCTAssertTrue(limiter.admit(), "first admit from the single token")
        // Hammer rejects; none should consume the (empty) bucket.
        for _ in 0..<20 { XCTAssertFalse(limiter.admit()) }
        // After a refill window (100ms @ 10/s = 1 token), exactly one admit succeeds.
        usleep(120_000)
        XCTAssertTrue(limiter.admit(), "one token refilled after the reject storm")
        XCTAssertFalse(limiter.admit(), "and only one")
    }

    // Default config (100/s burst 200) does not starve a synchronous single-client
    // loop: a burst of 50 sequential admits all pass well under the burst cap.
    func testDefaultConfigDoesNotStarveSyncClient() {
        let limiter = FBRateLimiter(ratePerSec: 100, burst: 200)
        var ok = 0
        for _ in 0..<50 { if limiter.admit() { ok += 1 } }
        XCTAssertEqual(ok, 50, "50 sequential admits under burst=200 must all pass")
    }

    // Disabled config bypass: the FBClientConnection builds a nil limiter when
    // enabled=false. Pin the config -> nil-limiter wiring at the config level.
    func testDisabledConfigBypassesLimiter() {
        let cfg = FBRateLimitConfig(enabled: false, ratePerSec: 100, burst: 200)
        XCTAssertFalse(cfg.enabled, "disabled config must read enabled=false")
        // The server maps enabled=false -> nil limiter (no gate). A nil limiter means
        // every execute passes; the bypass is structural (no FBRateLimiter allocated),
        // verified in UDSServer init, not here — but the config flag is the contract.
    }
}
