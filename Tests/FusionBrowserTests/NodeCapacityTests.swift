import XCTest
@testable import FusionBrowser

// H-9 / R-10: per-node capacity plane — the scheduler-placement input. fusion-browser
// is a non-persistent single-node engine; cross-node scheduling/migration lands in
// fusion-gateway (this side exposes the capacity query only). Tests the Swift surface
// (FBNodeCapacity builder + freeMemoryMB probe + manager.capacity()) deterministically.
// The UDS `{type:"capacity"}` round-trip is live-verified by scripts/multinode_smoke.py
// (a live socket is not unit-testable per ARCH-3, same as the metrics route).

final class NodeCapacityTests: XCTestCase {
    // Builder fills every field from quota + live count; ramGB + freeMemoryMB from the
    // real host (non-negative — freeMemoryMB clamps to 0 on probe failure, never negative).
    func testCurrentFillsFieldsAndNonNegativeFree() {
        let quota = FBResourceQuota.forHost(ramGB: 16)
        let cap = FBNodeCapacity.current(quota: quota, liveSessions: 3)
        XCTAssertEqual(cap.maxSessions, quota.maxSessions)
        XCTAssertEqual(cap.liveSessions, 3)
        XCTAssertEqual(cap.maxTotalMemoryMB, quota.maxTotalMemoryMB)
        XCTAssertFalse(cap.nodeId.isEmpty, "nodeId minted")
        XCTAssertGreaterThanOrEqual(cap.freeMemoryMB, 0, "freeMemoryMB never negative")
        XCTAssertGreaterThan(cap.ramGB, 0, "ramGB probed from host")
    }

    // nodeId is STABLE within one engine process (lazy static) — every snapshot reports
    // the SAME id so a scheduler's placement session is consistent. (Across restarts the
    // id mints fresh — documented, honest for a non-persistent engine.)
    func testNodeIdStableWithinProcess() {
        let quota = FBResourceQuota.forHost()
        let a = FBNodeCapacity.current(quota: quota, liveSessions: 0)
        let b = FBNodeCapacity.current(quota: quota, liveSessions: 5)
        XCTAssertEqual(a.nodeId, b.nodeId, "nodeId stable within one process")
        XCTAssertEqual(a.liveSessions, 0)
        XCTAssertEqual(b.liveSessions, 5, "live count differs per snapshot")
    }

    // liveSessions reflects the count passed in (the manager.capacity() reads the real
    // live count under the queue lock; here we prove the builder threads it honestly).
    func testLiveSessionsThreaded() {
        let quota = FBResourceQuota.forHost(ramGB: 8)
        for n in [0, 1, 4, quota.maxSessions] {
            let cap = FBNodeCapacity.current(quota: quota, liveSessions: n)
            XCTAssertEqual(cap.liveSessions, n)
        }
    }

    // freeMemoryMB is a conservative floor (physmem - active - wired); never exceeds
    // physmem and never negative. The exact value is host-dependent, so this asserts the
    // invariant, not a magic number.
    func testFreeMemoryWithinPhysmem() {
        let cap = FBNodeCapacity.current(quota: FBResourceQuota.forHost(), liveSessions: 0)
        let physMB = cap.ramGB * 1024
        XCTAssertLessThanOrEqual(cap.freeMemoryMB, physMB, "free cannot exceed physmem")
        XCTAssertGreaterThanOrEqual(cap.freeMemoryMB, 0)
    }

    // FBNodeCapacity Codable round-trip: the wire shape an external scheduler parses.
    // snake_case keys via FBFrame encoder (node_id, max_sessions, live_sessions,
    // max_total_memory_mb, free_memory_mb, ram_gb).
    func testCapacityCodableRoundTrip() {
        let orig = FBNodeCapacity(nodeId: "node-xyz", maxSessions: 10, liveSessions: 2,
                                  maxTotalMemoryMB: 1500, freeMemoryMB: 4096, ramGB: 16)
        let data = try? FBFrame.encoder.encode(orig)
        XCTAssertNotNil(data)
        let json = String(data: data ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"node_id\":\"node-xyz\""), "snake_case node_id")
        XCTAssertTrue(json.contains("\"max_sessions\":10"))
        XCTAssertTrue(json.contains("\"live_sessions\":2"))
        XCTAssertTrue(json.contains("\"free_memory_mb\":4096"))
        let decoded = try? FBFrame.decoder.decode(FBNodeCapacity.self, from: data ?? Data())
        XCTAssertEqual(decoded, orig)
    }

    // manager.capacity() reports the real live-session count. A fresh manager has 0 live;
    // this proves the manager wires the quota + queue-count into the snapshot (no live
    // webview created — manager.count() works without sessions per the existing tests).
    func testManagerCapacityReportsLiveCount() {
        let mgr = FBSessionManager(quota: FBResourceQuota.forHost(ramGB: 16),
                                   guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy(),
                                   creds: FBCredentialManager(),
                                   auth: FBAuth(token: "t"),
                                   allowedOrigins: [])
        let cap = mgr.capacity()
        XCTAssertEqual(cap.liveSessions, 0, "fresh manager has 0 live sessions")
        XCTAssertEqual(cap.maxSessions, 10, "16GB host -> 10 sessions")
        XCTAssertFalse(cap.nodeId.isEmpty)
        XCTAssertGreaterThanOrEqual(cap.freeMemoryMB, 0)
    }
}
