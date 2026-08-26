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
