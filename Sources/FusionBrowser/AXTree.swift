import Foundation

// FR-02 / B1 / T2.1: AXTree extractor. Injects FBWalkerScript.extract, parses result,
// builds stable mapping, emits Markdown reduction.
// FR-03 / C4 / T2.2: sanitizer — static rules + render-based visibility test (in JS walk).
// Audit C7: password masking done in JS walker.

public struct FBNodeMapping {
    public let nodeId: String
    public let role: String
    public let name: String
    public let fingerprint: String
}

public final class FBAXTreeExtractor {
    private let log = FBLogger.shared
    public let mapping = FBStableMapping()

    public init() {}

    // T2.1: run injected walker via FBWebView, parse FBExtractResult.
    // Sync wrapper: blocks on semaphore (called from ActionDriver watchdog block on bg queue).
    public func extract(webview: FBWebView) -> (result: FBExtractResult?, markdown: String, audit: SecurityAuditResult, error: FBError?) {
        guard let raw = webview.evaluateJSSync(FBWalkerScript.extract) as? String else {
            log.warn("AXTree", "walker returned non-string")
            return (nil, "", SecurityAuditResult(), .internalError)
        }
        guard let data = raw.data(using: .utf8) else {
            return (nil, "", SecurityAuditResult(), .internalError)
        }
        let res: FBExtractResult
        do {
            res = try JSONDecoder().decode(FBExtractResult.self, from: data)
        } catch {
            log.warn("AXTree", "decode walker failed: \(error)")
            return (nil, "", SecurityAuditResult(), .internalError)
        }
        // Install stable mapping from extracted nodes.
        mapping.install(res.nodes)
        // Build reduced interactive nodes for the wire schema (T2.1 compression).
        let reduced = res.nodes.map { FBAXTreeReducer.toWireNode($0) }
        let md = FBAXTreeReducer.toMarkdown(res)
        let audit = SecurityAuditResult(nodesAudited: res.nodesAudited,
                                        hiddenNodesPurged: res.hiddenNodesPurged,
                                        matchedRules: res.matchedRules)
        _ = reduced
        log.info("AXTree", "extracted nodes=\(res.nodes.count) purged=\(res.hiddenNodesPurged) rules=\(res.matchedRules)")
        return (res, md, audit, nil)
    }

    // B1: resolve @eN to mapping. Caller (ActionDriver) re-checks liveness via JS WeakRef.
    public func resolve(_ nodeId: String) -> FBNodeMapping? {
        return mapping.resolve(nodeId)
    }

    public func invalidate() {
        mapping.invalidate()
    }
}

// T2.1: Markdown reduction + compression. Drop non-essential fields, emit compact list.
public enum FBAXTreeReducer {
    public static func toWireNode(_ n: FBExtractedNode) -> AXTreeNode {
        return AXTreeNode(nodeId: n.nodeId, role: n.role, name: n.name,
                          isDisabled: n.isDisabled, currentValue: n.currentValue)
    }

    // Compact Markdown: one line per node. Header + nodes only (no style noise).
    // T2.1 acceptance: Token P95 <= 1500, compression P50 >= 90%.
    public static func toMarkdown(_ res: FBExtractResult) -> String {
        var lines: [String] = ["# Page", "url: \(res.url)", "title: \(res.title)", "", "# 交互节点"]
        for n in res.nodes {
            var line = "- [@\(n.nodeId)] \(n.role)"
            if !n.name.isEmpty { line += " “\(n.name)”" }
            if !n.currentValue.isEmpty { line += " (val:\(n.currentValue))" }
            if n.isDisabled { line += " [disabled]" }
            if n.renderHidden || !n.hiddenFlags.isEmpty {
                let hits = n.hiddenFlags.keys.sorted() + (n.renderHidden ? ["render:hidden"] : [])
                line += " {purged:" + hits.joined(separator: ",") + "}"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// FR-03 / C4 / T2.2: sanitizer — static rules + render-based visibility test.
// The actual audit runs inside the JS walker (FBWalkerScript.extract).
// This Swift side classifies a node's flags and exposes the rule catalog for tests/reports.
public final class FBSanitizer {
    private let log = FBLogger.shared

    public static let hiddenRules: [String] = [
        "display:none", "visibility:hidden", "opacity:0", "font-size:0",
        "aria-hidden:true", "hidden-attr", "offscreen", "color==bg",
        "text-indent:<-9999", "transform:scale(0)", "filter:opacity(0)",
        "render:hidden"
    ]

    public init() {}

    // Classify a node's computed style flags as hidden or not (static rules).
    // Used by tests + audit reporting; the live audit is the JS walker.
    public func audit(_ flags: [String: Bool]) -> (hidden: Bool, matched: [String]) {
        var matched: [String] = []
        for rule in FBSanitizer.hiddenRules {
            if flags[rule] == true { matched.append(rule) }
        }
        return (!matched.isEmpty, matched)
    }

    // T2.2: decide purge action — always keep node structure (for locate), blank text only.
    public func purgeAction(nodeHidden: Bool, renderHidden: Bool) -> (purgeText: Bool, keepNode: Bool) {
        let hidden = nodeHidden || renderHidden
        return (hidden, true)
    }
}
