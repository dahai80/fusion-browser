import Foundation
import Security

// FR-05 / NFR-S2 / D11: Keychain credential hosting.
// F-10: Keychain account key = "domain|name|path" (RFC 6265 cookie uniqueness). A site
// with multiple cookies (e.g. __Secure-SESSID at / and csrf at /admin) no longer clobber
// each other. Default retain on close; "logout" deletes ALL cookies for the domain.
// LLM NEVER touches plaintext; returns credential_injected: bool only.

public final class FBCredentialManager {
    private let log = FBLogger.shared
    private let service = "com.fusion.browser"

    public init() {}

    // F-10: account key = domain|name|path. path defaults to "/" (matches injectCookies).
    private func accountKey(domain: String, name: String, path: String) -> String {
        return "\(domain)|\(name)|\(path)"
    }

    // FR-05: store full cookie attributes as JSON blob. Keyed per-cookie (F-10) so
    // multiple cookies per domain coexist without clobbering.
    public func store(domain: String, cookieAttrs: [String: String]) -> FBError? {
        guard let blob = try? JSONSerialization.data(withJSONObject: cookieAttrs) else {
            return .invalidRequest
        }
        let name = cookieAttrs["name"] ?? ""
        let path = cookieAttrs["path"] ?? "/"
        guard !name.isEmpty else {
            log.warn("Cred", "store rejected: missing name domain=\(domain)")
            return .invalidRequest
        }
        let acct = accountKey(domain: domain, name: name, path: path)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = blob
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("Cred", "store failed for domain=\(domain) name=\(name) path=\(path) status=\(status)")
            return .credentialInjected
        }
        FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "store", result: "ok")
        return nil
    }

    // Returns the FIRST cookie attrs for domain, or nil. Single-cookie convenience kept
    // for compatibility; inject-all path uses retrieveAll(domain:).
    public func retrieve(domain: String) -> ([String: String]?, FBError?) {
        let (all, err) = retrieveAll(domain: domain)
        return (all.first, err)
    }

    // F-10: returns ALL cookie attrs for a domain (one Keychain item per cookie). The
    // inject path iterates these and injects each into the session's cookie store.
    // Keychain query shape note: kSecReturnData + kSecMatchLimitAll returns errSecParam
    // (-50) on this platform, so we enumerate account keys (attributes-only, all) then
    // fetch each blob per-account (data + limit one).
    public func retrieveAll(domain: String) -> ([[String: String]], FBError?) {
        if isKeychainLocked() {
            FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "inject", result: "locked")
            return ([], .credentialLocked)
        }
        // Step 1: enumerate all service accounts (attributes only, no data — data+all
        // is rejected with errSecParam here).
        let enumQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(enumQuery as CFDictionary, &items)
        if status == errSecItemNotFound {
            FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "inject", result: "miss")
            return ([], .credentialNotFound)
        }
        if status != errSecSuccess {
            log.error("Cred", "retrieveAll enum failed domain=\(domain) status=\(status)")
            return ([], .credentialLocked)
        }
        guard let arr = items as? [[String: Any]] else {
            return ([], .internalError)
        }
        // Step 2: filter accounts by this domain (per-cookie key "domain|..." or legacy
        // bare "domain"), then fetch each blob individually.
        let prefix = "\(domain)|"
        var accounts: [String] = []
        for entry in arr {
            guard let acct = entry[kSecAttrAccount as String] as? String else { continue }
            if acct == domain || acct.hasPrefix(prefix) { accounts.append(acct) }
        }
        var out: [[String: String]] = []
        for acct in accounts {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acct,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var blob: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &blob) != errSecSuccess { continue }
            guard let d = blob as? Data,
                  let attrs = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { continue }
            out.append(attrs)
        }
        if out.isEmpty {
            FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "inject", result: "miss")
            return ([], .credentialNotFound)
        }
        FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "inject", result: "ok")
        return (out, nil)
    }

    // D11: logout mode deletes ALL Keychain items for a domain (every cookie). Also
    // covers the legacy bare-domain key for items written before F-10.
    public func delete(domain: String) {
        var deletedAny = false
        // Per-cookie items: enumerate accounts (attributes only; data+all is errSecParam
        // here), delete those keyed to this domain.
        let scan: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        if SecItemCopyMatching(scan as CFDictionary, &items) == errSecSuccess,
           let arr = items as? [[String: Any]] {
            for entry in arr {
                guard let acct = entry[kSecAttrAccount as String] as? String else { continue }
                let isThisDomain = acct == domain || acct.hasPrefix("\(domain)|")
                if !isThisDomain { continue }
                let del: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: acct
                ]
                if SecItemDelete(del as CFDictionary) == errSecSuccess { deletedAny = true }
            }
        }
        FBCredentialAuditLog.shared.record(caller: "engine", domain: domain, op: "logout",
                                            result: deletedAny ? "ok" : "fail")
        log.info("Cred", "logout domain=\(domain) deleted=\(deletedAny)")
    }

    private func isKeychainLocked() -> Bool {
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
