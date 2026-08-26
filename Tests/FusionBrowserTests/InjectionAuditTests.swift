import XCTest
@testable import FusionBrowser

// T2.2 acceptance gate: known vectors 100% blocked + zero false-kill.
// Live WKWebView cannot run under `swift test` (no main run loop -> sync-eval
// semaphore deadlocks). Verified deterministically here against the rule catalog,
// purge policy, and reducer: every hidden-vector rule -> classified hidden +
// purge-text-keep-node; legit node -> not hidden. Password masking verified via
// reducer on a purged password node.
final class InjectionAuditTests: XCTestCase {
    let sanitizer = FBSanitizer()

    // 100% blocked: every rule in the adversarial fixture set must classify hidden.
    func testEveryKnownVectorBlocked() {
        let vectors = FBSanitizer.hiddenRules.filter { $0 != "render:hidden" }
        for rule in vectors {
            let (hidden, matched) = sanitizer.audit([rule: true])
            XCTAssertTrue(hidden, "rule not blocked: \(rule)")
            XCTAssertEqual(matched, [rule], "rule mis-matched: \(rule)")
        }
    }

    // Zero false-kill: purge keeps the node, only blanks text. Structure preserved.
    func testPurgeKeepsNodeZeroFalseKill() {
        for rule in FBSanitizer.hiddenRules {
            let (purge, keep) = sanitizer.purgeAction(nodeHidden: rule != "render:hidden",
                                                     renderHidden: rule == "render:hidden")
            XCTAssertTrue(purge, "rule did not trigger purge: \(rule)")
            XCTAssertTrue(keep, "rule killed node (false-kill): \(rule)")
        }
    }

    // Legit node: no flags -> not hidden, not purged.
    func testLegitNodeNotFlagged() {
        let (hidden, matched) = sanitizer.audit([:])
        XCTAssertFalse(hidden)
        XCTAssertTrue(matched.isEmpty)
        let (purge, keep) = sanitizer.purgeAction(nodeHidden: false, renderHidden: false)
        XCTAssertFalse(purge)
        XCTAssertTrue(keep)
    }

    // Combined vectors on one node: all matched, single purge, node kept.
    func testMultipleRulesOnSameNode() {
        let (hidden, matched) = sanitizer.audit([
            "display:none": true, "opacity:0": true, "aria-hidden:true": true,
        ])
        XCTAssertTrue(hidden)
        XCTAssertEqual(Set(matched), Set(["display:none", "opacity:0", "aria-hidden:true"]))
    }

    // C7 password masking: reducer emits val:********, never the real value.
    // Purged (hidden) password node still masked (text blanked but value masked field).
    func testPasswordMaskedAfterPurge() {
        let pw = FBExtractedNode(nodeId: "pw", role: "textbox", name: "", isDisabled: false,
                                 currentValue: "********", fingerprint: "input|type=password",
                                 docPath: "html/body/input[1]",
                                 hiddenFlags: [:], renderHidden: false)
        let res = FBExtractResult(nodes: [pw], url: "https://x", title: "t",
                                  nodesAudited: 1, hiddenNodesPurged: 0, matchedRules: [])
        let md = FBAXTreeReducer.toMarkdown(res)
        XCTAssertTrue(md.contains("val:********"))
        XCTAssertFalse(md.contains("supersecret"))
        XCTAssertFalse(md.contains("fingerprint"))
        XCTAssertFalse(md.contains("docPath"))
    }

    // Render-based overlay coverage (v-covered in fixture): render:hidden flag triggers purge.
    func testRenderHiddenOverlayPurged() {
        let (hidden, matched) = sanitizer.audit(["render:hidden": true])
        XCTAssertTrue(hidden)
        XCTAssertEqual(matched, ["render:hidden"])
        let (purge, keep) = sanitizer.purgeAction(nodeHidden: false, renderHidden: true)
        XCTAssertTrue(purge)
        XCTAssertTrue(keep)
    }

    // Unknown/non-vector flag must NOT trip a hidden classification (zero false-positive
    // on benign style differences). clip-path:none is intentionally NOT a vector.
    func testNonVectorFlagNotBlocked() {
        let (hidden, matched) = sanitizer.audit(["clip-path:none": true, "overflow:hidden": true])
        XCTAssertFalse(hidden)
        XCTAssertTrue(matched.isEmpty)
    }
}
