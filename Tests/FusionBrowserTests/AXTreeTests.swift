import XCTest
@testable import FusionBrowser

final class AXTreeReducerTests: XCTestCase {

    // T2.1 acceptance: compact markdown, no style noise, password masked.
    func testMarkdownCompressionStripsNoise() {
        let res = FBExtractResult(
            nodes: [
                FBExtractedNode(nodeId: "e1", role: "textbox", name: "用户名", isDisabled: false,
                                currentValue: "", fingerprint: "input|x", docPath: "html/body/form[1]/input[1]",
                                hiddenFlags: [:], renderHidden: false),
                FBExtractedNode(nodeId: "e2", role: "textbox", name: "密码", isDisabled: false,
                                currentValue: "********", fingerprint: "input|type=password", docPath: "html/body/form[1]/input[2]",
                                hiddenFlags: [:], renderHidden: false),
                FBExtractedNode(nodeId: "e3", role: "button", name: "", isDisabled: false,
                                currentValue: "", fingerprint: "button", docPath: "html/body/form[1]/button[1]",
                                hiddenFlags: ["display:none": true], renderHidden: false),
            ],
            url: "https://login.example.com", title: "登录",
            nodesAudited: 3, hiddenNodesPurged: 1, matchedRules: ["display:none"])
        let md = FBAXTreeReducer.toMarkdown(res)
        XCTAssertTrue(md.contains("[@e1]"))
        XCTAssertTrue(md.contains("“用户名”"))
        XCTAssertTrue(md.contains("[@e2]"))
        XCTAssertTrue(md.contains("val:********"))
        XCTAssertFalse(md.contains("fingerprint"))
        XCTAssertFalse(md.contains("docPath"))
        XCTAssertTrue(md.contains("{purged:display:none}"))
    }

    func testToWireNodePreservesFields() {
        let n = FBExtractedNode(nodeId: "e5", role: "link", name: "忘记密码", isDisabled: true,
                                currentValue: "", fingerprint: "a|href=x", docPath: "p",
                                hiddenFlags: [:], renderHidden: false)
        let w = FBAXTreeReducer.toWireNode(n)
        XCTAssertEqual(w.nodeId, "e5")
        XCTAssertEqual(w.role, "link")
        XCTAssertTrue(w.isDisabled)
        XCTAssertEqual(w.name, "忘记密码")
    }

    // Issue #9: bbox threads FBExtractedNode -> AXTreeNode (wire) for SOM/visual grounding.
    func testToWireNodePreservesBBox() {
        let n = FBExtractedNode(nodeId: "e6", role: "button", name: "Go", isDisabled: false,
                                currentValue: "", fingerprint: "button", docPath: "p",
                                hiddenFlags: [:], renderHidden: false,
                                bbox: FBBBox(x: 10, y: 20, width: 100, height: 40))
        let w = FBAXTreeReducer.toWireNode(n)
        XCTAssertEqual(w.bbox?.x, 10)
        XCTAssertEqual(w.bbox?.y, 20)
        XCTAssertEqual(w.bbox?.width, 100)
        XCTAssertEqual(w.bbox?.height, 40)
    }

    // Issue #9: AXTreeNode Codable round-trip emits snake_case-free numeric bbox; a node
    // without bbox decodes to nil (backward compat — additive field).
    func testAXTreeNodeBBoxCodableRoundTrip() throws {
        let node = AXTreeNode(nodeId: "e7", role: "link", name: "x", isDisabled: false,
                              currentValue: "", bbox: FBBBox(x: 1.5, y: 2.5, width: 3, height: 4))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(AXTreeNode.self, from: data)
        XCTAssertEqual(decoded.bbox, node.bbox)

        let noBbox = AXTreeNode(nodeId: "e8", role: "link", name: "y", isDisabled: false, currentValue: "")
        let data2 = try JSONEncoder().encode(noBbox)
        let decoded2 = try JSONDecoder().decode(AXTreeNode.self, from: data2)
        XCTAssertNil(decoded2.bbox)
    }
}

final class SanitizerTests: XCTestCase {
    let sanitizer = FBSanitizer()

    // T2.2: static rules classify hidden.
    func testStaticRulesClassifyHidden() {
        let (hidden, matched) = sanitizer.audit(["display:none": true, "opacity:0": false])
        XCTAssertTrue(hidden)
        XCTAssertEqual(matched, ["display:none"])
    }

    func testNoFlagsNotHidden() {
        let (hidden, _) = sanitizer.audit([:])
        XCTAssertFalse(hidden)
    }

    // T2.2: purge text but keep node (for locate).
    func testPurgeKeepsNodeBlanksText() {
        let (purge, keep) = sanitizer.purgeAction(nodeHidden: true, renderHidden: false)
        XCTAssertTrue(purge)
        XCTAssertTrue(keep)
        let (purge2, keep2) = sanitizer.purgeAction(nodeHidden: false, renderHidden: true)
        XCTAssertTrue(purge2)
        XCTAssertTrue(keep2)
    }

    func testRenderHiddenIsInRuleCatalog() {
        XCTAssertTrue(FBSanitizer.hiddenRules.contains("render:hidden"))
        XCTAssertTrue(FBSanitizer.hiddenRules.contains("clip-path:none") == false)
    }
}

final class StableMappingTests: XCTestCase {
    // B1: install + resolve + invalidate.
    func testInstallResolveInvalidate() {
        let m = FBStableMapping()
        let nodes = [
            FBExtractedNode(nodeId: "e1", role: "button", name: "OK", isDisabled: false,
                            currentValue: "", fingerprint: "button|OK", docPath: "p",
                            hiddenFlags: [:], renderHidden: false),
        ]
        m.install(nodes)
        XCTAssertEqual(m.count(), 1)
        XCTAssertEqual(m.resolve("e1")?.fingerprint, "button|OK")
        XCTAssertNil(m.resolve("e99"))
        m.invalidate()
        XCTAssertEqual(m.count(), 0)
    }

    // T2.1 node-id format contract: markdown advertises [@e1] but the stable mapping
    // + JS __fbMap key the node BARE (e1). A caller passing the markdown form "@e1"
    // MUST NOT resolve directly — that is the gap the ActionDriver leading-@ strip
    // closes. Pin both facts so the normalization stays load-bearing.
    func testNodeIdBareKeyMarkdownAtPrefixDoesNotResolve() {
        let m = FBStableMapping()
        m.install([
            FBExtractedNode(nodeId: "e1", role: "button", name: "Login", isDisabled: false,
                            currentValue: "", fingerprint: "button|Login", docPath: "p",
                            hiddenFlags: [:], renderHidden: false),
        ])
        XCTAssertEqual(m.resolve("e1")?.name, "Login")
        XCTAssertNil(m.resolve("@e1"))
    }
}
