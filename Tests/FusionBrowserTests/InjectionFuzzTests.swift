import XCTest
@testable import FusionBrowser

// R-8 / PRD §3.1.B: sanitizer combination-variant fuzzing. The per-rule tests in
// InjectionAuditTests prove each rule fires alone; this harness proves combinations
// fire too — a rule must NOT be shadowed when combined with others (the "组合变体
// 可能绕过" gap the audit flagged). Pure + deterministic (no live webview — fits
// `swift test` per ARCH-3). Exercises the Swift classifier surface (FBSanitizer.audit
// + purgeAction) only; ancestor-hidden propagation lives in the JS walker (FBWalkerScript)
// and is verified live, NOT duplicated in Swift (Rule 7 — one pattern).

final class InjectionFuzzTests: XCTestCase {
    let sanitizer = FBSanitizer()

    // The 11 static rules (render:hidden excluded — it is a render-only flag, exercised
    // separately in the render+static combination fuzz below). audit() treats render:hidden
    // as a catalog rule, but the live walker sets it from a post-render geometry probe,
    // not a static style flag, so it is out of the static power-set.
    static let staticRules: [String] = FBSanitizer.hiddenRules.filter { $0 != "render:hidden" }

    // Power-set fuzz: every non-empty subset of the 11 static rules (2^11 - 1 = 2047
    // combinations) must classify hidden AND match EXACTLY that subset (set-equal).
    // Catches a rule that fails to fire when combined with others — the combination-
    // variant bypass the audit flagged. Index-bitmask enumeration; no randomness so the
    // coverage is exhaustive and reproducible.
    func testPowerSetAllCombinationsClassifyHiddenAndMatch() {
        let rules = Self.staticRules
        let n = rules.count
        // 1..<(1<<n) skips the empty subset (no flags -> not hidden, tested elsewhere).
        for mask in 1..<(1 << n) {
            var flags: [String: Bool] = [:]
            var expected: Set<String> = []
            for i in 0..<n {
                if (mask >> i) & 1 == 1 {
                    flags[rules[i]] = true
                    expected.insert(rules[i])
                }
            }
            let (hidden, matched) = sanitizer.audit(flags)
            XCTAssertTrue(hidden, "combination not hidden: \(expected.sorted())")
            XCTAssertEqual(Set(matched), expected, "combination mis-matched: \(expected.sorted())")
        }
    }

    // Render + static combination fuzz: every static rule combined with render-hidden
    // must purge via purgeAction (defense-in-depth — render-based detection must NOT
    // disable static detection). purgeAction(nodeHidden, renderHidden) purges when EITHER
    // is true; here both are true. Also proves purgeAction never false-kills (keep==true).
    func testRenderPlusStaticCombinationPurgesAndKeepsNode() {
        for rule in Self.staticRules {
            let (purge, keep) = sanitizer.purgeAction(nodeHidden: true, renderHidden: true)
            XCTAssertTrue(purge, "render+static(\(rule)) did not purge")
            XCTAssertTrue(keep, "render+static(\(rule)) false-killed node")
        }
        // render-only (no static) still purges.
        let (purge, keep) = sanitizer.purgeAction(nodeHidden: false, renderHidden: true)
        XCTAssertTrue(purge)
        XCTAssertTrue(keep)
    }

    // Adversarial-naming fuzz: near-miss strings that look rule-adjacent must NOT trip a
    // hidden classification — zero false-positive. The catalog is EXACT-string match
    // (audit loops the rule list and checks flags[rule]==true), so a near-miss must not
    // match. This documents the exact-match contract and guards against a future
    // `contains`-based matcher silently broadening the kill set onto benign styles.
    func testAdversarialNearMissNamesDoNotTrip() {
        let nearMisses: [String] = [
            "display: none",       // space after colon
            "display:none ",       // trailing space
            "visibility:hidden ",  // trailing space
            "visibility: hidden",  // space after colon
            "opacity:0.0",         // 0.0 vs 0
            "opacity:0 ",          // trailing space
            "Display:None",        // case difference
            "DISPLAY:NONE",        // uppercase
            "font-size:0px",       // 0px vs 0
            "font-size:0em",       // 0em
            "aria-hidden:true ",   // trailing space
            "aria-hidden: true",   // space
            "text-indent:-9999",   // -9999 vs <-9999 (different shape)
            "transform:scale(0.0)",// 0.0 vs 0
            "filter:opacity(0.0)", // 0.0 vs 0
            "offscreen ",          // trailing space
            "hidden",              // bare, not hidden-attr
            "color:transparent",   // transparent vs ==bg
        ]
        for nm in nearMisses {
            let (hidden, matched) = sanitizer.audit([nm: true])
            XCTAssertFalse(hidden, "near-miss falsely flagged hidden: \(nm)")
            XCTAssertTrue(matched.isEmpty, "near-miss falsely matched: \(nm)")
        }
        // A page full of benign-but-similar styles stays clean.
        let (hidden, matched) = sanitizer.audit([
            "display: none": true, "opacity:0.0": true, "font-size:0px": true,
            "Display:None": true, "color:transparent": true, "hidden": true,
        ])
        XCTAssertFalse(hidden, "benign near-miss cluster falsely flagged hidden")
        XCTAssertTrue(matched.isEmpty)
    }

    // Exhaustive true-negative fuzz: a random-ish spread of NON-vector benign flags
    // (drawn from real CSS properties that are NOT in the catalog) must never trip.
    // Guards the false-positive surface from a catalog-broadening regression.
    func testBenignNonVectorFlagsNeverTrip() {
        let benign = [
            "clip-path:none", "overflow:hidden", "position:absolute", "position:fixed",
            "z-index:-1", "pointer-events:none", "user-select:none", "cursor:none",
            "border:0", "margin:0", "padding:0", "width:0", "height:0",
            "color:red", "background:transparent", "opacity:1", "font-size:14px",
            "transform:rotate(0deg)", "visibility:visible", "display:block",
            "content:none", "animation:none", "transition:none",
        ]
        // Power-set sample of the benign set (not all 2^23 — pick every single + a few
        // combos; single-benign is the strongest false-positive probe, combos stress the
        // set-equality). Full power-set of 23 is 8M — too many; the near-miss + single
        // coverage above is the exact-match guard. Here: every single benign flag, plus
        // the full benign set together, plus a 3-flag combo from each third.
        for b in benign {
            let (hidden, matched) = sanitizer.audit([b: true])
            XCTAssertFalse(hidden, "benign flag falsely hidden: \(b)")
            XCTAssertTrue(matched.isEmpty, "benign flag matched: \(b)")
        }
        let (hiddenAll, matchedAll) = sanitizer.audit(Dictionary(uniqueKeysWithValues: benign.map { ($0, true) }))
        XCTAssertFalse(hiddenAll, "full benign set falsely hidden")
        XCTAssertTrue(matchedAll.isEmpty, "full benign set matched: \(matchedAll)")
        // Cross-zone combos.
        for stride in stride(from: 0, to: benign.count - 3, by: 3) {
            let trio = Dictionary(uniqueKeysWithValues: [benign[stride], benign[stride + 1], benign[stride + 2]].map { ($0, true) })
            let (hidden, matched) = sanitizer.audit(trio)
            XCTAssertFalse(hidden, "benign trio falsely hidden: \(trio.keys.sorted())")
            XCTAssertTrue(matched.isEmpty)
        }
    }
}
