import XCTest
@testable import FusionBrowser

// PRD §4.3 module 5 parity gate: the Rust core path (FBCoreBridge.compileJSON)
// must produce markdown byte-exact vs the canonical Swift FBAXTreeReducer, and
// the wire nodes / audit must round-trip. Loads the shared fixture set at
// rust/fb-core/tests/parity.json (same file cargo test consumes). A mismatch
// fails loudly (Rule 12) — Rust drift is caught here, not in production.
//
// Bypasses the useRustCore flag (calls the bridge directly) so the gate runs
// under every config. The staticlib links under swift test via the transitive
// FusionBrowser -> FBCoreRust -> plugin dependency.
final class RustCoreParityTests: XCTestCase {

    private struct Fixture: Decodable {
        let cases: [Case]
    }
    private struct Case: Decodable {
        let name: String
        let input: FBExtractResult
        let expectedMarkdown: String
        enum CodingKeys: String, CodingKey {
            case name, input
            case expectedMarkdown = "expected_markdown"
        }
    }

    // Fixture path: resolve from this test source file (#file is the real source
    // path, not an SPM-staged copy). Walk up to the package root, then into
    // rust/fb-core/tests/parity.json — the same file cargo test consumes.
    private static let fixturePath: String = {
        let here = URL(fileURLWithPath: #file)
        var url = here.deletingLastPathComponent()
        for _ in 0..<10 {
            let probe = url.appendingPathComponent("rust/fb-core/tests/parity.json")
            if FileManager.default.fileExists(atPath: probe.path) { return probe.path }
            url = url.deletingLastPathComponent()
        }
        return "rust/fb-core/tests/parity.json"
    }()

    private func loadFixture() -> Fixture {
        let url = URL(fileURLWithPath: RustCoreParityTests.fixturePath)
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Fixture.self, from: data)
    }

    // Rust markdown == pinned expected, AND == Swift reducer markdown.
    // Both must agree byte-for-byte; this is the zero-regression gate.
    func testRustMarkdownMatchesSwiftAndFixture() throws {
        guard FBCoreBridge.isAvailable else {
            // Rust core not linked in this build — skip, not fail. The cargo
            // test stack covers the Rust side; this gate only runs when the
            // staticlib is present (release + --disable-sandbox test builds).
            throw XCTSkip("FBCoreRust staticlib not linked; run swift test --disable-sandbox")
        }
        let fixture = loadFixture()
        for c in fixture.cases {
            let swiftMd = FBAXTreeReducer.toMarkdown(c.input)
            XCTAssertEqual(swiftMd, c.expectedMarkdown, "Swift reducer != fixture case=\(c.name)")
            let inputBytes = try! JSONEncoder().encode(c.input)
            guard let rust = FBCoreBridge.compileJSON(inputBytes) else {
                XCTFail("Rust compileJSON returned nil case=\(c.name)")
                continue
            }
            XCTAssertEqual(rust.markdown, c.expectedMarkdown, "Rust markdown != fixture case=\(c.name)")
            XCTAssertEqual(rust.markdown, swiftMd, "Rust markdown != Swift markdown case=\(c.name)")
        }
    }

    // Wire nodes: Rust-emitted nodes must match Swift toWireNode for every node.
    func testRustWireNodesMatchSwift() throws {
        guard FBCoreBridge.isAvailable else {
            throw XCTSkip("FBCoreRust staticlib not linked; run swift test --disable-sandbox")
        }
        let fixture = loadFixture()
        for c in fixture.cases {
            let swiftNodes = c.input.nodes.map { FBAXTreeReducer.toWireNode($0) }
            let inputBytes = try! JSONEncoder().encode(c.input)
            guard let rust = FBCoreBridge.compileJSON(inputBytes) else {
                XCTFail("Rust compileJSON returned nil case=\(c.name)")
                continue
            }
            XCTAssertEqual(rust.nodes.count, swiftNodes.count, "node count case=\(c.name)")
            for (i, rn) in rust.nodes.enumerated() {
                XCTAssertEqual(rn.nodeId, swiftNodes[i].nodeId, "nodeId case=\(c.name) idx=\(i)")
                XCTAssertEqual(rn.role, swiftNodes[i].role, "role case=\(c.name) idx=\(i)")
                XCTAssertEqual(rn.name, swiftNodes[i].name, "name case=\(c.name) idx=\(i)")
                XCTAssertEqual(rn.isDisabled, swiftNodes[i].isDisabled, "isDisabled case=\(c.name) idx=\(i)")
                XCTAssertEqual(rn.currentValue, swiftNodes[i].currentValue, "currentValue case=\(c.name) idx=\(i)")
            }
        }
    }

    // Audit fields round-trip: nodesAudited / hiddenNodesPurged / matchedRules.
    func testRustAuditMatchesSwift() throws {
        guard FBCoreBridge.isAvailable else {
            throw XCTSkip("FBCoreRust staticlib not linked; run swift test --disable-sandbox")
        }
        let fixture = loadFixture()
        for c in fixture.cases {
            let swiftAudit = SecurityAuditResult(nodesAudited: c.input.nodesAudited,
                                                 hiddenNodesPurged: c.input.hiddenNodesPurged,
                                                 matchedRules: c.input.matchedRules)
            let inputBytes = try! JSONEncoder().encode(c.input)
            guard let rust = FBCoreBridge.compileJSON(inputBytes) else {
                XCTFail("Rust compileJSON returned nil case=\(c.name)")
                continue
            }
            XCTAssertEqual(rust.audit.nodesAudited, swiftAudit.nodesAudited, "nodesAudited case=\(c.name)")
            XCTAssertEqual(rust.audit.hiddenNodesPurged, swiftAudit.hiddenNodesPurged, "hiddenNodesPurged case=\(c.name)")
            XCTAssertEqual(rust.audit.matchedRules, swiftAudit.matchedRules, "matchedRules case=\(c.name)")
        }
    }

    // Version is non-zero when the staticlib is linked (sanity: FFI reachable).
    func testVersionNonZeroWhenAvailable() throws {
        guard FBCoreBridge.isAvailable else {
            throw XCTSkip("FBCoreRust staticlib not linked")
        }
        XCTAssertNotEqual(FBCoreBridge.version(), 0)
    }

    // estimateTokens is observable + non-negative on a known markdown string.
    func testEstimateTokensNonNegative() throws {
        guard FBCoreBridge.isAvailable else {
            throw XCTSkip("FBCoreRust staticlib not linked")
        }
        let md = "# Page\nurl: https://x\ntitle: T\n\n# 交互节点\n- [@e1] button “Login”"
        let tokens = FBCoreBridge.estimateTokens(md)
        XCTAssertGreaterThan(tokens, 0)
    }
}
