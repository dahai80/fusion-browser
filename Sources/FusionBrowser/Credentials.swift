import Foundation
import Security

// FR-05 / NFR-S2 / D11: Keychain credential hosting.
// Stores full cookie attributes, account = domain. Default retain on close; "logout" deletes.
// LLM NEVER touches plaintext; returns credential_injected: bool only.

public final class FBCredentialManager {
    private let log = FBLogger.shared
    private let service = "com.fusion.browser"

    public init() {}

    // FR-05: store full cookie attributes as JSON blob, account = domain.
    public func store(domain: String, cookieAttrs: [String: String]) -> FBError? {
        guard let blob = try? JSONSerialization.data(withJSONObject: cookieAttrs) else {
            return .invalidRequest
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: domain
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = blob
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Cred", "store failed for domain=\(domain) status=\(status)")
            return .credentialInjected
        }
        FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "store", result: "ok")
        return nil
    }

    // Returns cookie attrs for domain, or nil. Checks Keychain lock state.
    public func retrieve(domain: String) -> ([String: String]?, FBError?) {
        // Detect locked Keychain.
        if isKeychainLocked() {
            FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "inject", result: "locked")
            return (nil, .credentialLocked)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: domain,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "inject", result: "miss")
            return (nil, .credentialNotFound)
        }
        if status != errSecSuccess {
            log.error("Cred", "retrieve failed domain=\(domain) status=\(status)")
            return (nil, .credentialLocked)
        }
        guard let data = item as? Data,
              let attrs = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return (nil, .internalError)
        }
        FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "inject", result: "ok")
        return (attrs, nil)
    }

    // D11: logout mode deletes Keychain item for domain.
    public func delete(domain: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: domain
        ]
        let status = SecItemDelete(query as CFDictionary)
        FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "logout",
                                            result: status == errSecSuccess ? "ok" : "fail")
        log.info("Cred", "logout domain=\(domain) status=\(status)")
    }

    private func isKeychainLocked() -> Bool {
        // kSecAttrAccessible... items are readable after first unlock. If user hasn't unlocked
        // since boot, copies fail with errSecInteractionNotAllowed. Probe cheaply.
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(probe as CFDictionary, &item)
        return status == errSecInteractionNotAllowed
    }
}
