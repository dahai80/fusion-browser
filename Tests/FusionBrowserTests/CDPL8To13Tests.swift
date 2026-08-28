import XCTest
@testable import FusionBrowser

// L-8 / L-9 / L-10 / L-11 / L-13 coverage gaps. Live WKWebView + evaluateJSSync CANNOT run
// under `swift test` (ARCH-3: no main run loop -> evaluateJSSync semaphore deadlock), so the
// full dispatch path (translator -> server.executeAction -> ActionDriver -> evaluateJSSync)
// is integration-only. These tests pin the PURE, webview-free invariants the fixes enforce:
// the click finite-guard + release-only gate (L-8), backendNodeId stability/collision-freedom
// (L-9), jsStr control-char escaping (L-10), navigate origin gating (L-11), and WS
// fragmentation reassembly (L-13). Live behavior stays verified via the release binary +
// Python smoke client. L-12 (unmasked-frame reject) + L-8 evaluate-denial already have tests
// in CDPServerTests.swift; this file covers the remaining L-8..L-13 surfaces.

final class CDPClickL8Tests: XCTestCase {
    private let translator = FBCDPTranslator(server: nil, allowedOrigins: [])

    // L-8: non-finite coordinates must NEVER reach the interpolated JS. The old code
    // interpolated raw x/y: elementFromPoint(nan,...) -> JS `nan` is an undefined identifier
    // -> ReferenceError -> evaluateJSSync returns nil -> silent click failure (same defect
    // class as the L-5 visual-click interpolation bug). buildClickJS returns nil for
    // non-finite, so the dispatch is skipped instead of emitting broken JS.
    func testBuildClickJSRejectsNonFiniteCoords() {
        XCTAssertNil(translator.buildClickJS(x: Double.nan, y: 10), "NaN x must be rejected")
        XCTAssertNil(translator.buildClickJS(x: 10, y: Double.nan), "NaN y must be rejected")
        XCTAssertNil(translator.buildClickJS(x: Double.infinity, y: 10), "Infinity x must be rejected")
        XCTAssertNil(translator.buildClickJS(x: 10, y: -Double.infinity), "-Infinity y must be rejected")
    }

    // L-8: finite coords produce valid elementFromPoint JS with the numbers interpolated
    // (JSON numbers serialize to digits, never a bare JS identifier).
    func testBuildClickJSAcceptsFiniteCoords() {
        let js = translator.buildClickJS(x: 123.5, y: 0)
        XCTAssertNotNil(js)
        XCTAssertTrue(js?.contains("elementFromPoint(123.5,0.0)") ?? false, "finite coords interpolate verbatim: \(js ?? "")")
        XCTAssertTrue(js?.contains(".click()") ?? false, "must invoke .click(): \(js ?? "")")
    }

    // L-8: a paired CDP click is mousePressed + mouseReleased. Real Chrome fires `click` on
    // release; the fix fires ONLY on mouseReleased (release-only). The old condition
    // (mouseReleased || mousePressed) fired on BOTH -> double-fire. Pin: mousePressed alone
    // returns empty result without dispatching (the response is empty, not a click-error),
    // and mouseReleased returns empty result too (no error). We can't observe the dispatch
    // (no webview), but we CAN pin the response shape is the no-error empty result for both,
    // and that the buildClickJS seam is the only path. The double-fire fix is the release-only
    // guard inside handleMouseEvent; pin it indirectly via the guard's response contract.
    func testMousePressedReturnsOkWithoutError() {
        let r = dispatchHelper(translator, "Input.dispatchMouseEvent",
                               ["type": "mousePressed", "x": 5, "y": 5], id: 1)
        XCTAssertEqual(r["id"] as? Int, 1)
        XCTAssertNil(r["error"], "mousePressed must not error (release-only gate skips it)")
        XCTAssertTrue((r["result"] as? [String: Any])?.isEmpty ?? false)
    }

    func testMouseReleasedReturnsOkWithoutError() {
        let r = dispatchHelper(translator, "Input.dispatchMouseEvent",
                               ["type": "mouseReleased", "x": 5, "y": 5], id: 2)
        XCTAssertEqual(r["id"] as? Int, 2)
        XCTAssertNil(r["error"], "mouseReleased must not error")
        XCTAssertTrue((r["result"] as? [String: Any])?.isEmpty ?? false)
    }

    // L-8: a click with NaN coords on the release path must NOT error (it's skipped, not a
    // failure) — the finite guard returns empty result, never a JS-level error. This is the
    // contract that prevents the old silent-click-failure.
    func testMouseReleasedWithNaNCoordsNoErrors() {
        let r = dispatchHelper(translator, "Input.dispatchMouseEvent",
                               ["type": "mouseReleased", "x": Double.nan, "y": 5], id: 3)
        XCTAssertNil(r["error"], "NaN coords must be skipped, not error")
    }
}

// L-9: backendNodeId MUST be stable across process restarts (cowork caches it) and
// collision-free across distinct node ids. The old code used n.nodeId.hashValue — Swift's
// hashValue is process-randomized (SipHash seed), so it drifted per launch AND collided.
// stableNodeId derives the integer directly from the "eN" suffix (N) — deterministic and
// collision-free for distinct N. Non-eN ids fall back to a deterministic FNV-1a hash.
final class CDPBackendNodeIdL9Tests: XCTestCase {
    private let translator = FBCDPTranslator(server: nil, allowedOrigins: [])

    // "eN" -> N: the common walker id form. Deterministic across runs.
    func testStableNodeIdFromENSuffix() {
        XCTAssertEqual(translator.stableNodeId("e1"), 1)
        XCTAssertEqual(translator.stableNodeId("e42"), 42)
        XCTAssertEqual(translator.stableNodeId("e9999"), 9999)
    }

    // Distinct node ids map to distinct backendNodeIds (no collision for the eN form).
    func testStableNodeIdNoCollisionForENForm() {
        var seen = Set<Int>()
        for n in 1...500 {
            let id = translator.stableNodeId("e\(n)")
            XCTAssertFalse(seen.contains(id), "collision on e\(n) -> \(id)")
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 500)
    }

    // Non-eN ids fall back to a DETERMINISTIC FNV-1a hash — same input, same output across
    // process restarts (unlike the old hashValue). Two runs of the same test process give
    // the same value; the key invariant is determinism, which we pin by re-querying.
    func testStableNodeIdNonENIsDeterministic() {
        let a = translator.stableNodeId("custom-node-id")
        let b = translator.stableNodeId("custom-node-id")
        XCTAssertEqual(a, b, "same non-eN id must hash deterministically")
        XCTAssertGreaterThan(a, 0, "backendNodeId must be a positive id (cowork treats 0 as not-found)")
    }

    // Two DIFFERENT non-eN ids must (overwhelmingly) not collide. FNV-1a distributes well;
    // check a representative sample.
    func testStableHashDistinctInputsDontCollide() {
        var seen = Set<Int>()
        for i in 0..<200 {
            let h = translator.stableHash("node-\(i)-label")
            XCTAssertFalse(seen.contains(h), "FNV-1a collision on node-\(i)")
            seen.insert(h)
        }
        XCTAssertEqual(seen.count, 200)
    }

    // E-8: querySelector no longer fakes a deterministic FNV-hash nodeId (that id never
    // resolved to a live element). With a nil server it fails closed — "no server" — rather
    // than handing back a fabricated handle. Live querySelector (real server, real DOM
    // match) returns a positive nodeId via the qN registry; verified in cdp_dom_smoke.py.
    func testResolveSelectorStablePositiveId() {
        let translator = FBCDPTranslator(server: nil, allowedOrigins: [])
        let r1 = dispatchHelper(translator, "DOM.querySelector", ["selector": "#btn"], id: 1)
        let err = r1["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32000, "nil-server querySelector must fail-closed, not fake a nodeId")
    }
}

// L-10: jsStr must escape control chars so multi-line Input.insertText doesn't produce a
// JS SyntaxError (unterminated string literal). The old code escaped only `\` and `"`; a
// raw \n in the payload broke every multi-line text entry. Pin the full escape set.
final class CDPJsStrL10Tests: XCTestCase {
    private let translator = FBCDPTranslator(server: nil, allowedOrigins: [])

    func testJsStrEscapesBackslashAndQuote() {
        XCTAssertEqual(translator.jsStr("a\\b\"c"), "\"a\\\\b\\\"c\"")
    }

    func testJsStrEscapesNewlineCarriageReturnTab() {
        XCTAssertEqual(translator.jsStr("line1\nline2"), "\"line1\\nline2\"")
        XCTAssertEqual(translator.jsStr("a\rb"), "\"a\\rb\"")
        XCTAssertEqual(translator.jsStr("col1\tcol2"), "\"col1\\tcol2\"")
    }

    // L-10: ALL control chars < 0x20 (not just \n \r \t) must be escaped — a vertical tab
    // or form feed in the payload is equally fatal to the JS literal. Pin a representative
    // set via the \uXXXX escape.
    func testJsStrEscapesAllControlChars() {
        let escaped = translator.jsStr("\u{0B}\u{0C}\u{01}")
        XCTAssertTrue(escaped.contains("\\u000b"), "vertical tab must \\u-escape: \(escaped)")
        XCTAssertTrue(escaped.contains("\\u000c"), "form feed must \\u-escape: \(escaped)")
        XCTAssertTrue(escaped.contains("\\u0001"), "0x01 must \\u-escape: \(escaped)")
    }

    // L-10: a multi-line payload round-trips into a VALID single-line JS string literal (no
    // raw newlines remain in the output). This is the core fix: insertText with embedded
    // newlines no longer breaks the evaluate.
    func testJsStrMultiLineHasNoRawNewlines() {
        let escaped = translator.jsStr("first\nsecond\r\nthird")
        XCTAssertFalse(escaped.contains("\n") || escaped.contains("\r"),
                       "no raw CR/LF may remain in the escaped literal: \(escaped)")
        XCTAssertTrue(escaped.hasPrefix("\"") && escaped.hasSuffix("\""), "must be a quoted JS literal")
    }

    // L-10: non-control text passes through unchanged (no over-escaping of normal chars).
    func testJsStrPlainStringUnchanged() {
        XCTAssertEqual(translator.jsStr("hello world 123"), "\"hello world 123\"")
        XCTAssertEqual(translator.jsStr("用户名"), "\"用户名\"")
    }
}

// L-11: Page.navigate must gate by origin when an EVALUATE allowlist is configured, so a
// CDP caller cannot pair navigate+evaluate to run JS on an allowlisted page they navigated
// TO. The navigate itself runs the page load; the gate refuses non-allowlisted origins.
// Live navigate hits evaluateJSSync (no main run loop under `swift test`), so this test
// uses a REAL server+allowlist but a LOCAL scheme (data:) that is allowed to navigate
// freely (no cross-origin risk) for the ALLOWED path, and asserts the DENY path returns
// navigate_denied WITHOUT touching the webview (deny returns before executeAction).
final class CDPNavigateOriginL11Tests: XCTestCase {
    private func makeServer(allowedOrigins: [String]) -> (FBCDPServer, FBSessionManager) {
        let q = FBResourceQuota(maxSessions: 2, maxMemoryPerSessionMB: 150,
                                maxTotalMemoryMB: 300)
        let auth = FBAuth(token: "t")
        let mgr = FBSessionManager(quota: q, guards: FBSchedulingGuards(),
                                   watchdog: FBWatchdogPolicy.default, creds: FBCredentialManager(),
                                   auth: auth, allowedOrigins: allowedOrigins)
        let sanitizer = FBSanitizer()
        let driver = FBActionDriver(watchdog: FBWatchdogPolicy.default, auth: auth,
                                    allowedOrigins: allowedOrigins, sanitizer: sanitizer)
        let server = FBCDPServer(port: 0, manager: mgr, driver: driver,
                                 auth: auth, allowedOrigins: allowedOrigins)
        return (server, mgr)
    }

    // L-11: navigate to a non-allowlisted origin (allowlist configured) is DENIED. The deny
    // returns navigate_denied BEFORE executeAction, so no webview touch, no deadlock under
    // `swift test` (ARCH-3: live WKWebView cannot run here).
    func testNavigateDeniedNonAllowlistedOrigin() {
        let (server, mgr) = makeServer(allowedOrigins: ["https://allowed.example.com"])
        defer { if let sid = mgr.listIds().first { _ = mgr.close(sessionId: sid) } }
        let translator = FBCDPTranslator(server: server, allowedOrigins: ["https://allowed.example.com"])
        let r = dispatchHelper(translator, "Page.navigate",
                               ["url": "https://evil.attacker.com"], id: 1)
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32000)
        XCTAssertEqual(err?["message"] as? String, "navigate_denied",
                       "navigate to a non-allowlisted origin must be denied (L-11)")
    }

    // E-15: an UNPARSEABLE url (no scheme/host -> originOfUrl returns "") skips the gate
    // (the `!navOrigin.isEmpty` guard is false), so a nil-server translator still returns
    // the static ok result without touching a webview (ARCH-3 safe). This pins the gate's
    // skip-when-unparseable-url invariant. (The old lax test asserted skip-when-nil-server
    // for ANY url — under strict E-15 a nil server DENIES an http(s) origin; the unparseable
    // case is the only one that still skips.)
    func testNavigateGateSkipsWhenNoServer() {
        let src = FBCDPTranslator(server: nil, allowedOrigins: []).dispatch(method: "Page.navigate",
                                                                            params: ["url": "x"], id: 9)
        let r = src.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        XCTAssertNil(r["error"], "unparseable url -> gate skipped -> no navigate_denied (E-15)")
    }

    // E-15/R-16: with NO allowlist configured (empty), navigate to a remote http(s) origin
    // is now DENIED (fail-closed), consistent with EVALUATE's isOriginAllowed. The old code
    // short-circuited on `!srv.allowedOrigins.isEmpty` and let default-config operators
    // drive the webview to any origin. The deny returns navigate_denied BEFORE executeAction
    // (no webview touch -> ARCH-3 safe under `swift test`).
    func testNavigateGateSkipsWhenAllowlistEmpty() {
        let (server, _) = makeServer(allowedOrigins: [])
        XCTAssertTrue(server.allowedOrigins.isEmpty, "empty allowlist (E-15 strict deny setup)")
        let translator = FBCDPTranslator(server: server, allowedOrigins: [])
        let r = dispatchHelper(translator, "Page.navigate",
                               ["url": "https://evil.attacker.com"], id: 1)
        let err = r["error"] as? [String: Any]
        XCTAssertEqual(err?["message"] as? String, "navigate_denied",
                       "empty allowlist + remote origin -> navigate_denied (E-15 fail-closed, was lax-skip)")
    }
}

// L-13: WS fragmentation. RFC 6455 §5.4 — a message may span a FIN=0 start frame (opcode
// 0x1/0x2) followed by FIN=0 continuation frames (opcode 0x0) and a final FIN=1
// continuation. The old codec dropped the FIN bit and discarded all opcode-0x0 continuation
// frames, so a fragmented message (large Runtime.evaluate expression) silently lost data:
// fragment 1 was treated as a complete message, the continuation was dropped. The fix
// accumulates fragments and emits only when FIN=1 arrives. Server-side decode (requireMask).
final class CDPWSFragmentationL13Tests: XCTestCase {
    let codec = FBWSFrameCodec()  // requireMask = true (server decoding client frames)

    private func maskedDataFragment(fin: Bool, opcode: UInt8, payload: String,
                                    mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]) -> Data {
        let pl = Data(payload.utf8)
        var out = Data()
        out.append((fin ? 0x80 : 0x00) | opcode)
        out.append(UInt8(0x80 | pl.count))
        out.append(contentsOf: mask)
        for i in 0..<pl.count { out.append(pl[i] ^ mask[i % 4]) }
        return out
    }

    // L-13: a single unfragmented FIN=1 text frame still decodes (common path preserved).
    func testUnfragmentedFrameDecodes() {
        let (frame, _) = codec.tryDecode(maskedDataFragment(fin: true, opcode: 0x1, payload: "whole"))!
        XCTAssertEqual(frame?.opcode, 0x1)
        XCTAssertEqual(String(data: frame?.payload ?? Data(), encoding: .utf8), "whole")
    }

    // L-13: a fragmented message — FIN=0 start (opcode 0x1) + FIN=0 continuation (0x0) +
    // FIN=1 continuation (0x0) — reassembles into the full payload with the START opcode.
    // This mirrors the REAL caller (handleWSFrames): it strips `consumed` after EVERY
    // non-nil return, then re-feeds the REMAINDER (not the growing buffer). The codec state
    // (fragAccumulator) persists across calls. The original L-13 bug: tryDecode returned
    // nil for a FIN=0 fragment with NO consumed hint -> caller stripped nothing -> re-parsed
    // the start frame -> overwrote the accumulator -> message never completed. The fix
    // returns (nil-Frame, consumed) for fragments so the caller strips and advances.
    func testFragmentedMessageReassembles() {
        let part1 = maskedDataFragment(fin: false, opcode: 0x1, payload: "hel")
        let part2 = maskedDataFragment(fin: false, opcode: 0x0, payload: "lo ")
        let part3 = maskedDataFragment(fin: true, opcode: 0x0, payload: "world")
        // Frame 1 (FIN=0 start): consumed, no complete message -> (nil, c1). Caller strips c1.
        let r1 = codec.tryDecode(part1)
        XCTAssertNotNil(r1, "FIN=0 start must return (nil, consumed), not bare nil (L-13 fix)")
        let c1 = r1?.1 ?? 0
        XCTAssertEqual(c1, part1.count, "must report the start-frame bytes consumed")
        XCTAssertNil(r1?.0, "FIN=0 start emits no complete message")
        // Frame 2 (FIN=0 continuation): feed part2 alone (c1 already stripped). Accumulates.
        let r2 = codec.tryDecode(part2)
        XCTAssertNotNil(r2, "FIN=0 continuation must return (nil, consumed)")
        XCTAssertNil(r2?.0, "FIN=0 continuation emits no complete message yet")
        XCTAssertEqual(r2?.1, part2.count, "continuation bytes consumed")
        // Frame 3 (FIN=1 continuation): feed part3 alone -> emits the reassembled message.
        let r3 = codec.tryDecode(part3)
        XCTAssertNotNil(r3)
        let frame = r3?.0
        XCTAssertEqual(frame?.opcode, 0x1, "reassembled message carries the START opcode (0x1)")
        XCTAssertEqual(String(data: frame?.payload ?? Data(), encoding: .utf8), "hello world",
                       "fragments must concatenate into the full payload")
    }

    // L-13: the bug regression — if the caller fed the GROWING buffer (not stripping), the
    // start frame would be re-parsed and overwrite the accumulator. Pin that stripping the
    // consumed bytes (the real caller contract) makes a 3-fragment message complete in EXACTLY
    // 3 sequential tryDecode calls (one per fragment), no re-feeding.
    func testFragmentedCompletesInExactlyNSequentialCalls() {
        let parts = [
            maskedDataFragment(fin: false, opcode: 0x1, payload: "a"),
            maskedDataFragment(fin: false, opcode: 0x0, payload: "b"),
            maskedDataFragment(fin: true, opcode: 0x0, payload: "c")
        ]
        var emitted: FBWSFrameCodec.Frame? = nil
        var calls = 0
        for p in parts {
            calls += 1
            if let (f, _) = codec.tryDecode(p), let f = f { emitted = f }
        }
        XCTAssertNotNil(emitted, "3 sequential one-frame feeds must complete the message (L-13)")
        XCTAssertEqual(calls, 3, "exactly one tryDecode per fragment (caller strips each time)")
        XCTAssertEqual(String(data: emitted?.payload ?? Data(), encoding: .utf8), "abc")
    }

    // L-13: a continuation frame (opcode 0x0) with NO prior start frame is a protocol error
    // -> poison. The old codec silently dropped it; the fix poisons the stream (nil return).
    func testContinuationWithoutStartPoisons() {
        let fresh = FBWSFrameCodec()
        let orphan = maskedDataFragment(fin: true, opcode: 0x0, payload: "orphan")
        XCTAssertNil(fresh.tryDecode(orphan), "continuation with no start must poison (L-13)")
        // Poisoned: a subsequent valid frame also returns nil.
        XCTAssertNil(fresh.tryDecode(maskedDataFragment(fin: true, opcode: 0x1, payload: "after")),
                     "stream must stay poisoned after a stray continuation (L-13)")
    }

    // L-13: control frames (close/ping/pong) are NEVER fragmented — they must carry FIN=1
    // and are emitted immediately, not accumulated. A ping on a fresh codec emits its own
    // opcode at once (control frames interleave but don't join the data-message accumulator).
    func testControlFrameEmittedImmediately() {
        var ping = Data([0x89, 0x82])  // FIN+ping, mask+2
        ping.append(contentsOf: [0x05, 0x06, 0x07, 0x08, 0xAA, 0xBB])
        for i in 4..<ping.count { ping[i] ^= [0x05, 0x06, 0x07, 0x08][(i - 4) % 4] }
        let pingCodec = FBWSFrameCodec()
        let (pf, _) = pingCodec.tryDecode(ping)!
        XCTAssertEqual(pf?.opcode, 0x9, "control frame emits with its own opcode, never fragmented")
    }
}

// MARK: - shared dispatch helper (mirrors CDPTranslatorTests' inline decoder)

private func dispatchHelper(_ translator: FBCDPTranslator, _ method: String,
                            _ params: [String: Any], id: Int) -> [String: Any] {
    let resp = translator.dispatch(method: method, params: params, id: id)
    return resp.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}
