import XCTest
@testable import FusionBrowser

// 1016-audit fix pins. Deterministic (no WKWebView, no live sockets) per ARCH-3.
final class Audit1016Tests: XCTestCase {

    // MARK: S-3 isValidDomain

    func testIsValidDomainAcceptsHostname() {
        let m = FBCredentialManager()
        XCTAssertTrue(m.isValidDomain("example.com"))
        XCTAssertTrue(m.isValidDomain("a-b.c.d"))
        XCTAssertTrue(m.isValidDomain("localhost"))
    }

    func testIsValidDomainRejectsSeparatorAndControl() {
        let m = FBCredentialManager()
        XCTAssertFalse(m.isValidDomain("a|b"))          // key-separator injection
        XCTAssertFalse(m.isValidDomain(""))
        XCTAssertFalse(m.isValidDomain("exa mple.com")) // space
        XCTAssertFalse(m.isValidDomain("ex\nample.com")) // control char
        XCTAssertFalse(m.isValidDomain(String(repeating: "a", count: 254)))
    }

    // MARK: S-1/S-2: invalid domain fail-closed before Keychain

    func testStoreRejectsInvalidDomain() {
        let m = FBCredentialManager()
        XCTAssertEqual(m.store(domain: "a|b", cookieAttrs: ["name": "x", "value": "v"]),
                       .invalidRequest, "S-3: separator domain rejected before keychain write")
        XCTAssertEqual(m.store(domain: "", cookieAttrs: ["name": "x", "value": "v"]),
                       .invalidRequest)
    }

    func testDeleteByCookieRejectsInvalidDomain() {
        let m = FBCredentialManager()
        XCTAssertFalse(m.delete(domain: "a|b", cookieAttrs: ["name": "x"]),
                       "S-2: invalid domain never touches keychain delete")
    }

    // MARK: A-5 mdSafe

    func testMdSafeStripsControlCharsAndNewlines() {
        let dirty = "line1\nline2\r\ttab\u{7F}del"
        let clean = FBAXTreeReducer.mdSafe(dirty)
        XCTAssertFalse(clean.contains("\n"))
        XCTAssertFalse(clean.contains("\r"))
        XCTAssertFalse(clean.contains("\t"))
        XCTAssertFalse(clean.contains("\u{7F}"))
        XCTAssertEqual(clean, "line1line2tabdel")
    }

    func testMdSafeTruncatesTo200() {
        let s = String(repeating: "a", count: 500)
        XCTAssertEqual(FBAXTreeReducer.mdSafe(s).count, 200)
    }

    func testMdSafeKeepsNormalText() {
        XCTAssertEqual(FBAXTreeReducer.mdSafe("hello world 123"), "hello world 123")
    }

    // MARK: M-13 stableNodeId fallback out of eN space

    func testStableNodeIdENPassthrough() {
        let t = FBCDPTranslator(server: nil, allowedOrigins: [])
        XCTAssertEqual(t.stableNodeId("e1"), 1)
        XCTAssertEqual(t.stableNodeId("e531"), 531)
    }

    func testStableNodeIdHashFallbackOutOfENSpace() {
        let t = FBCDPTranslator(server: nil, allowedOrigins: [])
        // qN + arbitrary ids land >= 0x1000000 — cannot collide with any eN (< 2^23).
        for id in ["q5", "q1000", "fb-obj-7", "weird"] {
            let v = t.stableNodeId(id)
            XCTAssertGreaterThanOrEqual(v, 0x1000000, "\(id) must be out of eN space")
        }
        // deterministic
        XCTAssertEqual(t.stableNodeId("q5"), t.stableNodeId("q5"))
    }

    // MARK: C-6/T-4 FBFrameReader.checkPartialTimeout

    func testCheckPartialTimeoutFalseWhenNoPartial() {
        let r = FBFrameReader(frameTimeoutMs: 50)
        XCTAssertFalse(r.checkPartialTimeout())
        _ = r.append(Data([0, 0, 0, 5]) + Data("hello".utf8))
        XCTAssertFalse(r.checkPartialTimeout(), "drained to frame boundary -> no pending partial")
    }

    func testCheckPartialTimeoutFiresWhenSilentPartialOverstays() {
        let r = FBFrameReader(frameTimeoutMs: 1)
        _ = r.append(Data([0, 0, 0, 100])) // claims 100B body, sends none, goes silent
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertTrue(r.checkPartialTimeout(), "silent partial past frameTimeoutMs -> timer fires")
        // Buffer cleared: appending the SAME length prefix again starts a fresh partial
        // (no residual 100B expectation from the dropped frame).
        let res = r.append(Data([0, 0, 0, 5]) + Data("hello".utf8))
        XCTAssertEqual(res.frames.count, 1, "stale partial buffer was cleared, no frame drop")
    }

    func testCheckPartialTimeoutNotFiredWhenWithinWindow() {
        let r = FBFrameReader(frameTimeoutMs: 5_000)
        _ = r.append(Data([0, 0, 0, 100]))
        XCTAssertFalse(r.checkPartialTimeout(), "fresh partial within window -> no timeout")
    }

    // MARK: M-11 rate limiter clamp

    func testRateLimiterInvalidConfigNotBlackHole() {
        let l = FBRateLimiter(ratePerSec: 0, burst: 0)
        XCTAssertTrue(l.admit(), "M-11: zero/negative config clamps to workable, not deny-all")
        let l2 = FBRateLimiter(ratePerSec: -5, burst: -1)
        XCTAssertTrue(l2.admit())
    }

    // MARK: M-3 watchdog default threshold

    func testWatchdogDefaultThreshold1024() {
        XCTAssertEqual(FBMemoryWatchdogConfig().thresholdMB, 1024,
                       "M-3: idle WKWebView host exceeds 200MB; default must not self-drain")
    }

    // MARK: M-2 watchdog start/stop idempotent

    func testWatchdogStartStopIdempotent() {
        let cfg = FBMemoryWatchdogConfig(enabled: true, sampleIntervalMs: 50, thresholdMB: 1_000_000)
        let fired = XCTestExpectation(description: "breach")
        fired.isInverted = true
        let w = FBMemoryWatchdog(config: cfg, onBreach: { _ in fired.fulfill() })
        w.start()
        w.start() // M-2: re-start must not leak a second timer
        Thread.sleep(forTimeInterval: 0.15)
        w.stop()
        w.stop()  // M-1: stop from arbitrary queue must not deadlock
        wait(for: [fired], timeout: 0.3)
    }
}

// MARK: A-1 (#15) resolver verdict classification

final class ResolverVerdictTests: XCTestCase {
    // Pinned contract: only ok:true is success; stale -> node_stale; anything else
    // (ok:false stale:false, nil, non-String, unparseable JSON) must FAIL LOUD — the
    // old code fell through to a success state response and agent loops advanced on
    // wrong state. Pure function so this needs no live WKWebView (ARCH-3).

    func testOkVerdict() {
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: #"{"ok":true}"#), .ok)
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: #"{"ok":true,"stale":false}"#), .ok)
    }

    func testStaleVerdict() {
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: #"{"ok":false,"stale":true}"#), .stale)
    }

    func testNonContractVerdict() {
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: #"{"ok":false,"stale":false}"#), .nonContract)
        // Missing keys default to false — not ok, not stale: non-contract.
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: #"{}"#), .nonContract)
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: #"{"ok":"yes"}"#), .nonContract)
    }

    func testNoAnswerVerdict() {
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: nil), .noAnswer)
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: 42), .noAnswer)
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: "not json"), .noAnswer)
        XCTAssertEqual(FBActionDriver.classifyResolver(raw: #"[1,2]"#), .noAnswer)
    }
}

extension FBActionDriver.ResolverVerdict: Equatable {}
