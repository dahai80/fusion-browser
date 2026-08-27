import Foundation
#if canImport(FBCoreRust)
import FBCoreRust
#endif

// PRD §4.3 module 5 bridge: Swift -> Rust AXTree compiler over C-ABI FFI.
// Ownership = Rust-allocates / Rust-frees: fb_core_compile returns a Rust-owned
// buffer; we copy into a Swift Data then fb_core_free the Rust buffer BEFORE
// returning (never Data(bytesNoCopy:) — that defers free past lifetime and races
// the Rust allocator). Every FFI path degrades visibly on panic/decode fail;
// callers fall back to the Swift reducer — never crash the host on a Rust bug.
public enum FBCoreBridge {
    // fb_core_version: packed 0xMM_mm_pp. Always available (no input).
    public static func version() -> Int32 {
        #if canImport(FBCoreRust)
        return fb_core_version()
        #else
        return 0
        #endif
    }

    // True when the Rust staticlib is linked + importable. Used by the dispatch
    // point to decide whether the Rust path is even available (flag-gated).
    public static var isAvailable: Bool {
        #if canImport(FBCoreRust)
        return true
        #else
        return false
        #endif
    }

    // fb_core_compile: decode walker JSON -> combined {markdown,nodes,audit} JSON.
    // Returns nil on panic (FB_ERR_PANIC) or decode failure (FB_ERR_DECODE) —
    // caller logs + falls back to the Swift reducer.
    public static func compile(_ input: Data) -> Data? {
        #if canImport(FBCoreRust)
        return input.withUnsafeBytes { (inBuf: UnsafeRawBufferPointer) -> Data? in
            guard let inBase = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), !inBuf.isEmpty else {
                return compileEmpty()
            }
            var outPtr: UnsafeMutablePointer<UInt8>? = nil
            var outLen: UInt = 0
            let rc = fb_core_compile(inBase, UInt(inBuf.count), &outPtr, &outLen)
            guard rc == 0 else {
                FBLogger.shared.warn("FBCoreBridge", "fb_core_compile rc=\(rc) (1=panic,2=decode); falling back to Swift")
                return nil
            }
            guard let out = outPtr else {
                FBLogger.shared.warn("FBCoreBridge", "fb_core_compile ok but null out ptr")
                return nil
            }
            // Copy Rust buffer into Swift-owned Data, then free the Rust buffer.
            let copied = Data(bytes: out, count: Int(outLen))
            fb_core_free(out, outLen)
            return copied
        }
        #else
        FBLogger.shared.warn("FBCoreBridge", "FBCoreRust not linked; Rust path unavailable")
        return nil
        #endif
    }

    // Empty-input path: walker JSON is never empty in practice, but guard it.
    private static func compileEmpty() -> Data? {
        #if canImport(FBCoreRust)
        var outPtr: UnsafeMutablePointer<UInt8>? = nil
        var outLen: UInt = 0
        let rc = fb_core_compile(nil, 0, &outPtr, &outLen)
        guard rc == 0, let out = outPtr else { return nil }
        let copied = Data(bytes: out, count: Int(outLen))
        fb_core_free(out, outLen)
        return copied
        #else
        return nil
        #endif
    }

    // Combined-output decode shape (camelCase, matches Rust CombinedOut).
    private struct CombinedOut: Decodable {
        let markdown: String
        let nodes: [WireNode]
        let audit: AuditOut
    }
    private struct WireNode: Decodable {
        let nodeId: String
        let role: String
        let name: String
        let isDisabled: Bool
        let currentValue: String
    }
    private struct AuditOut: Decodable {
        let nodesAudited: Int
        let hiddenNodesPurged: Int
        let matchedRules: [String]
    }

    // High-level: decode walker JSON -> (markdown, wireNodes, audit).
    // Returns nil on any failure (FFI or JSON decode); caller falls back to Swift.
    public static func compileJSON(_ data: Data) -> (markdown: String, nodes: [AXTreeNode], audit: SecurityAuditResult)? {
        guard let out = compile(data) else { return nil }
        do {
            let combined = try JSONDecoder().decode(CombinedOut.self, from: out)
            let nodes = combined.nodes.map {
                AXTreeNode(nodeId: $0.nodeId, role: $0.role, name: $0.name,
                           isDisabled: $0.isDisabled, currentValue: $0.currentValue)
            }
            let audit = SecurityAuditResult(nodesAudited: combined.audit.nodesAudited,
                                            hiddenNodesPurged: combined.audit.hiddenNodesPurged,
                                            matchedRules: combined.audit.matchedRules)
            return (combined.markdown, nodes, audit)
        } catch {
            FBLogger.shared.warn("FBCoreBridge", "combined-output decode failed: \(error); falling back to Swift")
            return nil
        }
    }

    // fb_core_estimate_tokens: coarse token heuristic for a markdown string.
    // Benchmark/observability consumer; NOT on the live extract() path.
    public static func estimateTokens(_ md: String) -> UInt {
        #if canImport(FBCoreRust)
        let bytes = Array(md.utf8)
        return bytes.withUnsafeBufferPointer { buf -> UInt in
            guard let base = buf.baseAddress else { return 0 }
            return UInt(fb_core_estimate_tokens(base, UInt(buf.count)))
        }
        #else
        return 0
        #endif
    }
}
