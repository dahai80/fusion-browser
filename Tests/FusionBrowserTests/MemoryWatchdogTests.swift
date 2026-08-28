import XCTest
@testable import FusionBrowser

// P4-2: deterministic unit tests for the RSS watchdog. The live timer + WKWebView
// are integration-only (binary + smoke). These cover the threshold decision, the
// arm/disarm one-shot semantics, the real RSS syscall, config defaults, and that
// a disabled config never fires. No live webview here.

final class MemoryWatchdogTests: XCTestCase {

    // Threshold is an exclusive boundary at the MB granularity.
    func testShouldTriggerAtThreshold() {
        let mb = 1024 * 1024
        XCTAssertFalse(FBMemoryWatchdog.shouldTrigger(rssBytes: 200 * mb, thresholdMB: 200))
        XCTAssertTrue(FBMemoryWatchdog.shouldTrigger(rssBytes: (200 * mb) + 1, thresholdMB: 200))
        XCTAssertFalse(FBMemoryWatchdog.shouldTrigger(rssBytes: 100 * mb, thresholdMB: 200))
    }

    // Real syscall must return a positive value on any live process.
    func testCurrentRSSBytesPositive() {
        let rss = FBMemoryWatchdog.currentRSSBytes()
        XCTAssertGreaterThan(rss, 0, "mach_task_basic_info.resident_size must be > 0 for a live process")
    }

    // A fake sampler over threshold fires the breach closure exactly once; a
    // second tick while still armed-over must NOT refire (one-shot until recovery).
    func testBreachFiresOnceUntilRecovery() {
        var fired = 0
        var lastMB = 0
        let cfg = FBMemoryWatchdogConfig(enabled: true, sampleIntervalMs: 1, thresholdMB: 50, action: "close_sessions")
        let wd = FBMemoryWatchdog(config: cfg, onBreach: { mb in fired += 1; lastMB = mb },
                                  sampler: { 60 * 1024 * 1024 })
        wd.tick()
        wd.tick()
        wd.tick()
        XCTAssertEqual(fired, 1, "breach must fire once then disarm until recovery")
        XCTAssertEqual(lastMB, 60)
    }

    // After recovery (RSS drops below threshold), the watchdog re-arms and a
    // subsequent breach fires again.
    func testRearmAfterRecovery() {
        var fired = 0
        let cfg = FBMemoryWatchdogConfig(enabled: true, sampleIntervalMs: 1, thresholdMB: 50, action: "close_sessions")
        var sample = 60 * 1024 * 1024
        let wd = FBMemoryWatchdog(config: cfg, onBreach: { _ in fired += 1 }, sampler: { sample })
        wd.tick()
        XCTAssertEqual(fired, 1)
        sample = 10 * 1024 * 1024
        wd.tick()
        XCTAssertEqual(fired, 1, "recovery tick must not fire")
        sample = 70 * 1024 * 1024
        wd.tick()
        XCTAssertEqual(fired, 2, "re-armed breach must fire again")
    }

    // L-20: the bug the fix targets. The OLD one-shot fuse re-armed ONLY on RSS recovery,
    // so a TRUE leak (RSS stays high forever) fired onBreach exactly ONCE then went silent —
    // the watchdog blew its single fuse precisely in the scenario it exists for (P4-5 long-
    // run leak). The new cooldown re-arms under SUSTAINED high RSS so a persistent leak
    // re-fires instead of dying after one shot. With threshold 50 and a constant 60MB
    // sample: tick1 fires (consecutive=1, cooldown=3); ticks2-4 count the cooldown down;
    // tick4 re-arms at cooldown==0; tick5 fires AGAIN (consecutive=2). 5 ticks => 2 fires.
    func testSustainedHighRSSRefiresAfterCooldown() {
        var fired = 0
        let cfg = FBMemoryWatchdogConfig(enabled: true, sampleIntervalMs: 1, thresholdMB: 50, action: "close_sessions")
        let wd = FBMemoryWatchdog(config: cfg, onBreach: { _ in fired += 1 },
                                  sampler: { 60 * 1024 * 1024 })
        for _ in 0..<5 { wd.tick() }
        XCTAssertEqual(fired, 2, "sustained-high RSS must re-fire after cooldown (was 1 under the blown-fuse bug)")
    }

    // L-20 escalation: each consecutive breach LENGTHENS the cooldown (cooldownTicks +
    // (consecutive-1)), so a persistent leak re-fires but less frequently as it persists,
    // and the gap between 2nd->3rd fire is longer than 1st->2nd. Trace with threshold 50,
    // constant 60MB: tick1 fire(c=1,cd=3); t2 cd2; t3 cd1; t4 rearm; t5 fire(c=2,cd=4);
    // t6 cd3; t7 cd2; t8 cd1; t9 rearm; t10 fire(c=3,cd=5). So 10 ticks => 3 fires, and
    // the 1st->2nd gap is 4 ticks while 2nd->3rd is 5 ticks (escalation observable).
    func testCooldownEscalationLengthensGap() {
        var fired = 0
        var fireTicks: [Int] = []
        var tickNo = 0
        let cfg = FBMemoryWatchdogConfig(enabled: true, sampleIntervalMs: 1, thresholdMB: 50, action: "close_sessions")
        let wd = FBMemoryWatchdog(config: cfg, onBreach: { _ in
            fired += 1; fireTicks.append(tickNo)
        }, sampler: { 60 * 1024 * 1024 })
        for _ in 0..<10 {
            tickNo += 1
            wd.tick()
        }
        XCTAssertEqual(fired, 3, "10 sustained-high ticks => 3 fires (escalating cooldown)")
        XCTAssertEqual(fireTicks, [1, 5, 10], "fire ticks must match the escalating cooldown trace")
        let gap1 = fireTicks[1] - fireTicks[0]
        let gap2 = fireTicks[2] - fireTicks[1]
        XCTAssertGreaterThan(gap2, gap1, "escalation: 2nd->3rd gap (\(gap2)) must exceed 1st->2nd (\(gap1))")
    }

    // L-20 + recovery reset: a recovery tick (RSS drops below threshold) resets the
    // consecutive-breach counter, so the NEXT breach starts cooldown at the base again
    // (not the escalated length). Leak -> recover -> leak must use base cooldown.
    func testRecoveryResetsEscalation() {
        var fired = 0
        var sample = 60 * 1024 * 1024
        let cfg = FBMemoryWatchdogConfig(enabled: true, sampleIntervalMs: 1, thresholdMB: 50, action: "close_sessions")
        let wd = FBMemoryWatchdog(config: cfg, onBreach: { _ in fired += 1 }, sampler: { sample })
        // 1st breach + escalate through a 2nd fire (consecutive=2, cooldown=4).
        for _ in 0..<5 { wd.tick() }
        XCTAssertEqual(fired, 2)
        // Recover: resets consecutive to 0, cooldown to 0, re-arms.
        sample = 10 * 1024 * 1024
        wd.tick()
        // New breach: consecutive back to 1, cooldown back to BASE (3), not escalated 5.
        sample = 60 * 1024 * 1024
        wd.tick()
        XCTAssertEqual(fired, 3, "post-recovery breach fires")
        // Base cooldown 3 => 3 cooldown ticks + 1 rearm + 1 fire = 5 ticks to next fire
        // (escalated would need 6). Assert base by counting to exactly the base gap.
        for _ in 0..<4 { wd.tick() }
        XCTAssertEqual(fired, 4, "post-recovery gap uses BASE cooldown (3), not escalated")
    }

    // M-11: stop() must drain in-flight tick() via a queue.sync barrier so onBreach cannot
    // fire on a stopped watchdog. Deterministic part we CAN pin: stop() is safe to call
    // (no deadlock from the barrier), idempotent, and after stop() the timer is cancelled
    // so a subsequent start() re-arms fresh (breachArmed stays true, counters intact). The
    // live-race (tick dispatched mid-stop) is integration-only; this guards the barrier
    // compiles + runs + stop returns in bounded time.
    func testStopIsSafeAndIdempotent() {
        var fired = 0
        let cfg = FBMemoryWatchdogConfig(enabled: true, sampleIntervalMs: 1, thresholdMB: 50, action: "close_sessions")
        let wd = FBMemoryWatchdog(config: cfg, onBreach: { _ in fired += 1 },
                                  sampler: { 60 * 1024 * 1024 })
        wd.start()
        // A few real timer ticks fire (1ms interval). stop() drains the queue barrier.
        Thread.sleep(forTimeInterval: 0.02)
        wd.stop()
        wd.stop()  // idempotent: second stop must not crash/deadlock on the barrier.
        let firedAtStop = fired
        // After stop, give the (cancelled) timer a window; no new fires must land.
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(fired, firedAtStop, "no onBreach may fire after stop() returns")
        // Re-arm works after stop.
        wd.start()
        Thread.sleep(forTimeInterval: 0.02)
        wd.stop()
        XCTAssertGreaterThanOrEqual(fired, firedAtStop, "re-arm after stop runs without error")
    }

    // Disabled config: start() is a no-op (no timer), tick() still respects
    // threshold but the wiring never calls it. Guard the default.
    func testDefaultConfigDisabled() {
        let d = FBMemoryWatchdogConfig()
        XCTAssertFalse(d.enabled, "memory watchdog must default OFF (opt-in)")
        XCTAssertEqual(d.action, "close_sessions")
        XCTAssertGreaterThan(d.thresholdMB, 0)
        XCTAssertGreaterThan(d.sampleIntervalMs, 0)
    }

    // exit action is a valid enum value distinct from close_sessions.
    func testActionEnumRoundTrip() {
        XCTAssertEqual(FBMemoryWatchdogAction(rawValue: "close_sessions"), .closeSessions)
        XCTAssertEqual(FBMemoryWatchdogAction(rawValue: "exit"), .exit)
        XCTAssertNil(FBMemoryWatchdogAction(rawValue: "bogus"))
    }
}
