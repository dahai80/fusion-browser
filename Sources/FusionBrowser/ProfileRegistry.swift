import Foundation

// Issue #25: persistent-profile registry. profileId -> WKWebsiteDataStore identifier.
// Ownership is the auth-token SHA256 hex (FBAuth.ownerKey) — the only durable client
// identity the engine has (per-connection UUIDs die on reconnect; a per-call-dial proxy
// like fusion-gateway mints a new connection per op). Cross-owner use is denied
// (profile_denied) — profiles are login state and must never cross trust domains.
// Registry file is owner-only (0o600), atomically written, and a corrupt file reads as
// empty (fail-safe rebuild) rather than throwing the engine into a bad state.

// Issue #25: pure admission gate for profileId creates (unit-testable; live create is
// webview-bound and cannot run under swift test per ARCH-3). Fail-closed:
// - no profileId -> unchanged non-persistent path, ungated;
// - profileId without .persistentProfiles -> auth_denied;
// - profileId without a token identity (system caller/CDP) -> profile_denied (no owner
//   means the profile could never be attributed or deleted safely).
public enum FBProfileGate {
    public static func check(profileId: String?, caps: FBCapabilities, ownerKey: String?) -> FBError? {
        guard let id = profileId, !id.isEmpty else { return nil }
        guard caps.contains(.persistentProfiles) else { return .authDenied }
        guard ownerKey != nil else { return .profileDenied }
        return nil
    }
}

public final class FBProfileRegistry {
    public struct Entry: Codable, Equatable {
        public var storeId: String
        public var ownerTokenHash: String
        public var createdAt: Int
    }

    public static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.fusion-browser/profiles.json"
    }()

    private let path: String
    private let lock = NSLock()
    private let log = FBLogger.shared

    public init(path: String = FBProfileRegistry.defaultPath) {
        self.path = path
    }

    // Returns the store id for profileId. Creates a fresh entry on first use; reuses it
    // for the same owner; denies (profile_denied) a different owner.
    public func resolve(profileId: String, ownerTokenHash: String) -> FBResult<String> {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        if let e = map[profileId] {
            guard e.ownerTokenHash == ownerTokenHash else {
                log.warn("Profile", "resolve denied: cross-owner profileId=\(profileId)")
                return .failure(.profileDenied)
            }
            return .success(e.storeId)
        }
        let entry = Entry(storeId: UUID().uuidString,
                          ownerTokenHash: ownerTokenHash,
                          createdAt: Int(Date().timeIntervalSince1970))
        map[profileId] = entry
        save(map)
        log.info("Profile", "created profileId=\(profileId) store=\(entry.storeId)")
        return .success(entry.storeId)
    }

    // nil = deleted (or never existed); .notOwner when the caller neither owns the
    // profile nor acts as a system caller.
    public func delete(profileId: String, ownerTokenHash: String, isSystemCaller: Bool) -> FBError? {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        guard let e = map[profileId] else { return nil }
        guard isSystemCaller || e.ownerTokenHash == ownerTokenHash else {
            log.warn("Profile", "delete denied: cross-owner profileId=\(profileId)")
            return .notOwner
        }
        map.removeValue(forKey: profileId)
        save(map)
        log.info("Profile", "deleted profileId=\(profileId)")
        return nil
    }

    public func entry(profileId: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return load()[profileId]
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return load().count
    }

    // A corrupt/missing file reads as empty — rebuild on next save. Never throws.
    private func load() -> [String: Entry] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            log.error("Profile", "registry corrupt at \(path); rebuilding empty (\(error))")
            return [:]
        }
    }

    private func save(_ map: [String: Entry]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        do {
            let data = try JSONEncoder().encode(map)
            let tmp = path + ".tmp"
            try data.write(to: URL(fileURLWithPath: tmp), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                      withItemAt: URL(fileURLWithPath: tmp))
        } catch {
            log.error("Profile", "registry save failed at \(path): \(error)")
        }
    }
}
