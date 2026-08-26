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

    public static let all: FBCapabilities = [.navigate, .click, .type, .scroll, .screenshot, .evaluate, .close]
    public static let `default`: FBCapabilities = [.navigate, .click, .type, .scroll, .screenshot, .close]
}

public final class FBAuth {
    private let expectedTokenHash: String?
    private let queue = DispatchQueue(label: "fusion-browser.auth")
    // token -> capabilities (Phase 1: single token, all-default; map ready for multi-client)
    private var tokenCaps: [String: FBCapabilities] = [:]
    private let log = FBLogger.shared

    public init(token: String?) {
        if let t = token, !t.isEmpty {
            let hash = SHA256.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined()
            self.expectedTokenHash = hash
            tokenCaps[t] = FBCapabilities.default
        } else {
            self.expectedTokenHash = nil
        }
    }

    // Returns capabilities if token valid, nil otherwise.
    public func authenticate(token: String?) -> FBCapabilities? {
        guard let expected = expectedTokenHash else {
            log.warn("Auth", "no token configured; denying all (UDS must be authed)")
            return nil
        }
        guard let t = token, !t.isEmpty else { return nil }
        let hash = SHA256.hash(data: Data(t.utf8)).map { String(format: "%02x", $0) }.joined()
        guard hash == expected else {
            log.warn("Auth", "token mismatch")
            return nil
        }
        return queue.sync { tokenCaps[t] ?? FBCapabilities.default }
    }

    // FR-10: EVALUATE capability + origin whitelist.
    public func canEvaluate(caps: FBCapabilities, origin: String, allowedOrigins: [String]) -> Bool {
        guard caps.contains(.evaluate) else {
            log.warn("Auth", "evaluate capability missing")
            return false
        }
        if allowedOrigins.isEmpty { return true }
        let matched = allowedOrigins.contains { origin.hasPrefix($0) }
        if !matched { log.warn("Auth", "evaluate origin not allowed: \(origin)") }
        return matched
    }
}
