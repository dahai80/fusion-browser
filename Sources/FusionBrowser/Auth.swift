import Foundation
import CryptoKit

// FR-10: auth + capability model.
// Phase 1: shared-secret token. CDP :9222 default off (gate at server layer).
// EVALUATE needs evaluate capability + top-level origin in allowed_origins (checked at action layer).

public struct FBCapabilities: OptionSet, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let navigate = FBCapabilities(rawValue: 1 << 0)
    public static let click    = FBCapabilities(rawValue: 1 << 1)
    public static let type     = FBCapabilities(rawValue: 1 << 2)
    public static let scroll   = FBCapabilities(rawValue: 1 << 3)
    public static let screenshot = FBCapabilities(rawValue: 1 << 4)
    public static let evaluate = FBCapabilities(rawValue: 1 << 5)
    public static let close    = FBCapabilities(rawValue: 1 << 6)
    // R-3/B-3: read-only engine metrics. NOT in .default — an operator must opt in via
    // tokenCapabilities (e.g. ["metrics"] or ["all"]) to read counters/latency quantiles.
    // Without it the UDS metrics request + CDP Performance.getMetrics are cap-gated off.
    public static let metrics  = FBCapabilities(rawValue: 1 << 7)

    public static let all: FBCapabilities = [.navigate, .click, .type, .scroll, .screenshot, .evaluate, .close, .metrics]
    public static let `default`: FBCapabilities = [.navigate, .click, .type, .scroll, .screenshot, .close]
}

public final class FBAuth {
    // M-6: map keyed by token HASH, not raw token. Raw token never retained past init.
    private let expectedTokenHash: [UInt8]
    private let queue = DispatchQueue(label: "fusion-browser.auth")
    // hash(hex) -> capabilities. Keyed on hash so plaintext token leaves no heap footprint.
    private var tokenCaps: [String: FBCapabilities] = [:]
    private let log = FBLogger.shared
    // R-10/B-5: operator flag designating the configured token as a system-caller
    // token. When true, isSystemCaller(token:) returns true for a matching token so
    // UDSServer passes ownerId=nil → SessionManager bypasses E-34 ownership (the
    // per-call-dial proxy/scheduler case). OPERATOR CONFIG only, fail-closed false.
    private let systemCaller: Bool

    // caps: capabilities granted to the registered token. Defaults to `.default`
    // (no evaluate — H-5 scoped-token model). An operator may elevate via the
    // `tokenCapabilities` config key (e.g. ["evaluate"] or ["all"]) so the
    // evaluate action becomes reachable; without it evaluate is cap-gated off
    // (evaluate_denied). Fail-closed: an unknown cap name is dropped, never
    // broadens — `parseCaps(["bogus"])` yields the empty set, not .all.
    // systemCaller: operator config `tokenSystemCaller` — designates this token as a
    // system caller (bypasses E-34 ownership on UDS). Orthogonal to caps: a system
    // caller still needs its action caps to drive sessions.
    public init(token: String?, caps: FBCapabilities = .default, systemCaller: Bool = false) {
        self.systemCaller = systemCaller
        if let t = token, !t.isEmpty {
            let digest = SHA256.hash(data: Data(t.utf8))
            self.expectedTokenHash = Array(digest)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            tokenCaps[hex] = caps
        } else {
            // No token configured → deny-all sentinel (still fail-closed in authenticate).
            self.expectedTokenHash = []
        }
    }

    // Parse a config string list into FBCapabilities. Accepted names match the
    // FBCapabilities static members (case-insensitive); "all" → .all. Unknown
    // names are dropped with a warning (fail-closed: never silently broaden).
    // Empty list → empty set (deny-all for every action — explicit, not a default).
    public static func parseCaps(_ names: [String]) -> FBCapabilities {
        var caps: FBCapabilities = []
        for raw in names {
            let n = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch n {
            case "all": caps.formUnion(.all)
            case "navigate": caps.formUnion(.navigate)
            case "click": caps.formUnion(.click)
            case "type": caps.insert(.type)
            case "scroll": caps.insert(.scroll)
            case "screenshot": caps.insert(.screenshot)
            case "evaluate": caps.insert(.evaluate)
            case "close": caps.insert(.close)
            case "metrics": caps.insert(.metrics)
            default:
                FBLogger.shared.warn("Auth", "unknown tokenCapabilities name=\(raw) dropped (fail-closed)")
            }
        }
        return caps
    }

    // Returns capabilities if token valid, nil otherwise.
    public func authenticate(token: String?) -> FBCapabilities? {
        // Fail-closed: empty hash list = no token configured → deny all (L-19 contract).
        if expectedTokenHash.isEmpty {
            log.warn("Auth", "no token configured; denying all (UDS must be authed)")
            return nil
        }
        guard let t = token, !t.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(t.utf8))
        let candidate = Array(digest)
        // M-7: constant-time compare over hash bytes. No short-circuit on first differing
        // byte; accumulates XOR difference across the full digest before deciding.
        guard constantTimeEqual(candidate, expectedTokenHash) else {
            log.warn("Auth", "token mismatch")
            return nil
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return queue.sync { tokenCaps[hex] ?? FBCapabilities.default }
    }

    // R-10/B-5: is the supplied token the operator-designated system-caller token?
    // Returns true ONLY when the token hash matches the configured token AND
    // `systemCaller` is true. Fail-closed on every other path: no token configured,
    // empty/wrong token, or flag false → false. Reuses the same SHA256 + constant-time
    // compare as authenticate (one connection, one auth — double-hash negligible).
    // Signature kept separate from authenticate so CDPServer.verifyBearer + the test
    // call sites need zero edits (the CDP path uses nil-owner already, no flag needed).
    public func isSystemCaller(token: String?) -> Bool {
        if !systemCaller { return false }
        if expectedTokenHash.isEmpty { return false }
        guard let t = token, !t.isEmpty else { return false }
        let digest = SHA256.hash(data: Data(t.utf8))
        let candidate = Array(digest)
        return constantTimeEqual(candidate, expectedTokenHash)
    }

    // Constant-time byte compare. Length-mismatch is a public fact (digest size), not a
    // secret, so it is allowed to early-return; the byte loop itself never short-circuits.
    private func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // FR-10: EVALUATE capability + origin whitelist.
    // F-6: empty allowedOrigins denies (fail-closed), never "allow all".
    // F-7: structured origin compare — not hasPrefix (which `https://example.com.evil.com`
    // bypasses). An origin is scheme://host[:port]; compare scheme + host case-insensitively
    // and port exactly. Opaque origins (about:blank, data:, blob:, javascript:) are rejected
    // when a whitelist is configured.
    public func canEvaluate(caps: FBCapabilities, origin: String, allowedOrigins: [String]) -> Bool {
        guard caps.contains(.evaluate) else {
            log.warn("Auth", "evaluate capability missing")
            return false
        }
        return isOriginAllowed(origin, allowedOrigins: allowedOrigins)
    }

    // Structured origin match shared by EVALUATE (F-7) and the CDP WS upgrade gate (F-3).
    // Fail-closed: empty whitelist denies. Allowed entries may be `scheme://host[:port]`
    // or bare `host` (defaults to https, any port). Opaque origins are rejected.
    public func isOriginAllowed(_ origin: String, allowedOrigins: [String]) -> Bool {
        if allowedOrigins.isEmpty {
            log.warn("Auth", "evaluate origin denied: empty whitelist (fail-closed) origin=\(origin)")
            return false
        }
        guard let parsed = parseOrigin(origin) else {
            log.warn("Auth", "evaluate origin denied: opaque/invalid origin=\(origin)")
            return false
        }
        for entry in allowedOrigins {
            guard let allowed = parseOrigin(entry) else { continue }
            if parsed.scheme.lowercased() == allowed.scheme.lowercased()
                && parsed.host.lowercased() == allowed.host.lowercased()
                && (allowed.port == nil || parsed.port == allowed.port) {
                return true
            }
        }
        log.warn("Auth", "evaluate origin not allowed: \(origin)")
        return false
    }

    // Parse an origin string into (scheme, host, port). Accepts `scheme://host[:port]`
    // or a bare `host` (scheme defaults to https). Returns nil for opaque origins
    // (about:, data:, blob:, javascript:, file:) or unparseable input.
    private func parseOrigin(_ s: String) -> (scheme: String, host: String, port: Int?)? {
        let lower = s.lowercased()
        for opaque in ["about:", "data:", "blob:", "javascript:", "file:"] {
            if lower.hasPrefix(opaque) { return nil }
        }
        guard let comps = URLComponents(string: s) else { return nil }
        guard let host = comps.host, !host.isEmpty, let scheme = comps.scheme, !scheme.isEmpty else {
            // Bare host form (no scheme) — treat as https, host = the whole string trimmed.
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }
            return ("https", trimmed, nil)
        }
        return (scheme, host, comps.port)
    }
}
