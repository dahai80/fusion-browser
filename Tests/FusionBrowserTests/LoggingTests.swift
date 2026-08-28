import XCTest
@testable import FusionBrowser

final class LoggingTests: XCTestCase {

    // P-5: setMinLevel must gate log() — a level below minLevel must NOT reach the sink.
    // Exercises the atomic level read path that replaced the per-call queue.sync. Uses an
    // ISOLATED logger (makeForTest) so the global .shared sink/level is never touched — a
    // test swapping .shared's sink would silently break every other test in the suite.
    func testMinLevelGatesSink() {
        let logger = FBLogger.makeForTest()
        let box = BoxStringArray()
        logger.setSink { _, _, line in box.append(line) }
        logger.setMinLevel(.error)
        logger.debug("Tag", "debug-msg")
        logger.info("Tag", "info-msg")
        logger.warn("Tag", "warn-msg")
        logger.error("Tag", "error-msg")
        let collected = box.snapshot()
        XCTAssertTrue(collected.contains { $0.contains("error-msg") }, "error must pass the gate")
        XCTAssertFalse(collected.contains { $0.contains("debug-msg") }, "debug must be gated out at error level")
        XCTAssertFalse(collected.contains { $0.contains("info-msg") }, "info must be gated out at error level")
        XCTAssertFalse(collected.contains { $0.contains("warn-msg") }, "warn must be gated out at error level")
    }

    // P-5: raising minLevel back to debug lets debug through — the atomic read sees the
    // update without a queue hop, and the gate is re-evaluated each call.
    func testLowerMinLevelReopensDebug() {
        let logger = FBLogger.makeForTest()
        let box = BoxStringArray()
        logger.setSink { _, _, line in box.append(line) }
        logger.setMinLevel(.error)
        logger.debug("Tag", "should-drop")
        logger.setMinLevel(.debug)
        logger.debug("Tag", "should-pass")
        let collected = box.snapshot()
        XCTAssertFalse(collected.contains { $0.contains("should-drop") })
        XCTAssertTrue(collected.contains { $0.contains("should-pass") })
    }

    // P-5: setSink must not race with concurrent log() writes. The sink is guarded by a
    // plain lock now (no serial-queue sync); hammer log() from many threads while swapping
    // the sink. Must not crash and every emitted line must reach SOME sink (no dropped
    // closure due to a torn read). This is the concurrency invariant the queue.sync
    // removal had to preserve. Isolated logger; sink counts (no stderr write) so the test
    // cannot block on a full pipe from 1000 synchronous FileHandle writes.
    func testSetSinkConcurrentWithLogNoCrash() {
        let logger = FBLogger.makeForTest()
        logger.setMinLevel(.debug)
        let counter = BoxCounter()
        // Install a counting sink FIRST so the default stderr sink never runs (1000 sync
        // stderr writes to a captured pipe can block — keep the sink pure-counter).
        let counting: (FBLogLevel, String, String) -> Void = { _, _, _ in counter.inc() }
        logger.setSink(counting)
        let altCounting: (FBLogLevel, String, String) -> Void = { _, _, _ in counter.inc() }
        let grp = DispatchGroup()
        grp.enter()
        DispatchQueue.global().async {
            for _ in 0..<200 { logger.setSink(counting); logger.setSink(altCounting) }
            grp.leave()
        }
        grp.enter()
        DispatchQueue.global().async {
            for i in 0..<500 { logger.debug("Tag", "msg\(i)") }
            grp.leave()
        }
        grp.enter()
        DispatchQueue.global().async {
            for i in 0..<500 { logger.error("Tag", "err\(i)") }
            grp.leave()
        }
        grp.wait()
        // Every logged line (1000) must have hit a sink increment; no crash, no torn read.
        XCTAssertGreaterThanOrEqual(counter.value(), 1000, "every log call must reach a sink")
    }
}

// Tiny thread-safe wrappers so the closures capture a stable reference type while the
// value they guard is mutated under a lock — mirrors the CaptureBox pattern used elsewhere.
private final class BoxStringArray {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); let v = items; lock.unlock(); return v }
}

private final class BoxCounter {
    private let lock = NSLock()
    private var n = 0
    func inc() { lock.lock(); n += 1; lock.unlock() }
    func value() -> Int { lock.lock(); let v = n; lock.unlock(); return v }
}
