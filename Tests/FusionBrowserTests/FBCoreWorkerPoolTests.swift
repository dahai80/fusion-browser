import XCTest
@testable import FusionBrowser

// PRD §4.2 Rust Worker Pool tests: bounded concurrency, inline fallback, metrics.
// Deterministic — no WKWebView, no live timing assertions. The pool wraps the
// stateless FBCoreBridge.compileJSON; these tests exercise the bounding/fallback
// behavior, not the Rust compile itself (covered by RustCoreParityTests).
final class FBCoreWorkerPoolTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FBCoreWorkerPool.shared.resetForTest()
    }

    // Pool capacity is at least 2 (floor) and never exceeds cores-2+floor.
    func testCapacityBoundedSanely() {
        let cap = FBCoreWorkerPool.shared.capacity
        XCTAssertGreaterThanOrEqual(cap, 2)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        XCTAssertLessThanOrEqual(cap, max(2, cores - 2))
    }

    // Snapshot reports the three FR-12 fields (workers/active/pending).
    func testSnapshotHasExpectedKeys() {
        let snap = FBCoreWorkerPool.shared.snapshot()
        XCTAssertEqual(snap["workers"], FBCoreWorkerPool.shared.capacity)
        XCTAssertGreaterThanOrEqual(snap["active"] ?? -1, 0)
        XCTAssertGreaterThanOrEqual(snap["pending"] ?? -1, 0)
    }

    // Shutdown makes compile fall back to inline (non-nil result on valid input
    // when the staticlib is linked; skip otherwise).
    func testShutdownFallsBackInline() throws {
        guard FBCoreBridge.isAvailable else {
            throw XCTSkip("FBCoreRust staticlib not linked; run swift test --disable-sandbox")
        }
        let data = Self.minimalWalkerJSON
        FBCoreWorkerPool.shared.shutdownPool()
        // Even with the pool shut down, a valid walker JSON must still compile
        // via the inline fallback path (the pool is a perf guard, not correctness).
        let result = FBCoreWorkerPool.shared.compile(data)
        XCTAssertNotNil(result, "inline fallback should still compile after shutdown")
        FBCoreWorkerPool.shared.resetForTest()
    }

    // Many concurrent compiles all return (none lost). Validates the per-task
    // done semaphore: every caller wakes. Uses a barrier to wait for all.
    func testConcurrentSubmitsAllComplete() throws {
        guard FBCoreBridge.isAvailable else {
            throw XCTSkip("FBCoreRust staticlib not linked; run swift test --disable-sandbox")
        }
        let data = Self.minimalWalkerJSON
        let n = 20 // exceeds pool capacity to exercise queueing
        let group = DispatchGroup()
        let lock = NSLock()
        var completed = 0
        var nilResults = 0
        for _ in 0..<n {
            group.enter()
            DispatchQueue.global().async {
                let r = FBCoreWorkerPool.shared.compile(data)
                lock.lock()
                if r == nil { nilResults += 1 } else { completed += 1 }
                lock.unlock()
                group.leave()
            }
        }
        let ok = group.wait(timeout: .now() + .seconds(30))
        XCTAssertEqual(ok, .success, "all concurrent compiles must complete")
        XCTAssertEqual(completed, n, "every submit must return a non-nil result")
        XCTAssertEqual(nilResults, 0)
    }

    // Minimal walker JSON: one textbox node. Enough for compileJSON to decode
    // + produce markdown; we do not assert the markdown here (parity tests do).
    private static let minimalWalkerJSON: Data = {
        let s = """
        {"url":"https://x","title":"T","nodesAudited":1,"hiddenNodesPurged":0,
         "matchedRules":[],
         "nodes":[{"nodeId":"e1","role":"textbox","name":"u","fingerprint":"fp",
                   "docPath":"html>body>form>input","hiddenFlags":{},"renderHidden":false,
                   "currentValue":"","isDisabled":false}]}
        """
        return s.data(using: .utf8)!
    }()
}
