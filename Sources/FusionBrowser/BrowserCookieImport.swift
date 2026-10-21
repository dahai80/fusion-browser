import Foundation
import SQLite3

// Issue #25: read cookies out of the user's own browsers so a cowork run can start
// already logged in. Chrome/Edge keep the value AES-encrypted (see CookieCrypto.swift)
// with the key in the macOS Keychain; Firefox keeps them plaintext in cookies.sqlite.
// Every browser holds its DB open, so the file is copied to a temp dir together with
// its -wal/-shm sidecars before reading (an uncheckpointed WAL holds recent rows).
// E-39: cookie names and values are NEVER logged — counts and error codes only.

public enum FBBrowserKind: String, Codable {
    case chrome
    case edge
    case firefox
}

public struct FBImportedCookie {
    public var attrs: [String: String]

    public init(attrs: [String: String]) {
        self.attrs = attrs
    }
}

public struct FBCookieImportConfig {
    public var chromeUserDataDir: String
    public var edgeUserDataDir: String
    public var firefoxProfilesDir: String

    public init(chromeUserDataDir: String, edgeUserDataDir: String, firefoxProfilesDir: String) {
        self.chromeUserDataDir = chromeUserDataDir
        self.edgeUserDataDir = edgeUserDataDir
        self.firefoxProfilesDir = firefoxProfilesDir
    }

    public static let `default`: FBCookieImportConfig = {
        let support = NSHomeDirectory() + "/Library/Application Support"
        return FBCookieImportConfig(
            chromeUserDataDir: support + "/Google/Chrome",
            edgeUserDataDir: support + "/Microsoft Edge",
            firefoxProfilesDir: support + "/Firefox/Profiles")
    }()
}

public final class FBBrowserCookieImporter {
    public struct ImportResult {
        public var cookies: [FBImportedCookie]
        public var skippedAppBound: Int
        public var skippedOther: Int

        public init(cookies: [FBImportedCookie] = [], skippedAppBound: Int = 0, skippedOther: Int = 0) {
            self.cookies = cookies
            self.skippedAppBound = skippedAppBound
            self.skippedOther = skippedOther
        }
    }

    // Chromium's epoch is 1601-01-01 in microseconds; Unix is 1970-01-01 in seconds.
    private static let chromiumEpochOffsetSeconds = 11_644_473_600.0

    private let config: FBCookieImportConfig
    private let keyProvider: (FBBrowserKind) -> Data?
    private let log = FBLogger.shared

    public init(config: FBCookieImportConfig = .default, keyProvider: @escaping (FBBrowserKind) -> Data?) {
        self.config = config
        self.keyProvider = keyProvider
    }

    public func importCookies(kind: FBBrowserKind, profile: String? = nil) -> FBResult<ImportResult> {
        switch kind {
        case .chrome, .edge:
            return importChromium(kind: kind, profile: profile)
        case .firefox:
            return importFirefox(profile: profile)
        }
    }

    private func importChromium(kind: FBBrowserKind, profile: String?) -> FBResult<ImportResult> {
        let baseDir = kind == .chrome ? config.chromeUserDataDir : config.edgeUserDataDir
        let profileDir = baseDir + "/" + (profile ?? "Default")
        let candidates = [profileDir + "/Network/Cookies", profileDir + "/Cookies"]
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            log.warn("CookieImport", "\(kind.rawValue) db missing profileDir=\(profileDir)")
            return .failure(.importDenied)
        }
        let key = keyProvider(kind)
        if key == nil {
            log.warn("CookieImport", "\(kind.rawValue) key unavailable; encrypted rows will be skipped")
        }
        return withTempCopy(source) { dbPath in
            var result = ImportResult()
            let sql = """
            SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite
            FROM cookies
            """
            let rc = query(dbPath, sql) { stmt in
                let host = text(stmt, 0)
                let name = text(stmt, 1)
                let plainValue = text(stmt, 2)
                let encrypted = blobData(stmt, 3)
                let path = text(stmt, 4)
                let expiresUtc = sqlite3_column_int64(stmt, 5)
                let secure = sqlite3_column_int(stmt, 6) != 0
                let httponly = sqlite3_column_int(stmt, 7) != 0
                let sameSite = Int(sqlite3_column_int(stmt, 8))

                var value = plainValue
                if !encrypted.isEmpty {
                    guard let key = key else {
                        result.skippedOther += 1
                        return
                    }
                    let (decrypted, status) = FBChromiumCookieCrypto.decrypt(encrypted, key: key)
                    switch status {
                    case .ok, .plaintext:
                        value = decrypted ?? ""
                    case .appBound:
                        result.skippedAppBound += 1
                        return
                    case .failed:
                        result.skippedOther += 1
                        return
                    }
                }
                guard !name.isEmpty, !value.isEmpty else {
                    result.skippedOther += 1
                    return
                }
                result.cookies.append(FBImportedCookie(attrs: [
                    "name": name,
                    "value": value,
                    "domain": host,
                    "path": path.isEmpty ? "/" : path,
                    "secure": secure ? "true" : "false",
                    "httponly": httponly ? "true" : "false",
                    "samesite": chromeSameSite(sameSite),
                    "expires": chromeExpiry(expiresUtc),
                ]))
            }
            if rc != SQLITE_OK {
                log.error("CookieImport", "\(kind.rawValue) read failed rc=\(rc)")
                return .failure(.importDenied)
            }
            log.info("CookieImport", "\(kind.rawValue) imported=\(result.cookies.count) appBound=\(result.skippedAppBound) other=\(result.skippedOther)")
            return .success(result)
        }
    }

    private func importFirefox(profile: String?) -> FBResult<ImportResult> {
        let profilesDir = config.firefoxProfilesDir
        guard let profileDir = resolveFirefoxProfile(profilesDir: profilesDir, profile: profile) else {
            log.warn("CookieImport", "firefox profile not found dir=\(profilesDir) named=\(profile ?? "-")")
            return .failure(.importDenied)
        }
        let source = profileDir + "/cookies.sqlite"
        guard FileManager.default.fileExists(atPath: source) else {
            log.warn("CookieImport", "firefox cookies.sqlite missing profileDir=\(profileDir)")
            return .failure(.importDenied)
        }
        return withTempCopy(source) { dbPath in
            var result = ImportResult()
            let sql = """
            SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite
            FROM moz_cookies
            """
            let rc = query(dbPath, sql) { stmt in
                let host = text(stmt, 0)
                let name = text(stmt, 1)
                let value = text(stmt, 2)
                let path = text(stmt, 3)
                let expiry = sqlite3_column_int64(stmt, 4)
                let secure = sqlite3_column_int(stmt, 5) != 0
                let httponly = sqlite3_column_int(stmt, 6) != 0
                let sameSite = Int(sqlite3_column_int(stmt, 7))
                guard !name.isEmpty else {
                    result.skippedOther += 1
                    return
                }
                result.cookies.append(FBImportedCookie(attrs: [
                    "name": name,
                    "value": value,
                    "domain": host,
                    "path": path.isEmpty ? "/" : path,
                    "secure": secure ? "true" : "false",
                    "httponly": httponly ? "true" : "false",
                    "samesite": firefoxSameSite(sameSite),
                    "expires": Self.unixExpiry(Double(expiry)),
                ]))
            }
            if rc != SQLITE_OK {
                log.error("CookieImport", "firefox read failed rc=\(rc)")
                return .failure(.importDenied)
            }
            log.info("CookieImport", "firefox imported=\(result.cookies.count) other=\(result.skippedOther)")
            return .success(result)
        }
    }

    // profile nil -> the first *.default* profile dir, else the first dir holding
    // cookies.sqlite. Named profiles match the full dir name, then a suffix match.
    private func resolveFirefoxProfile(profilesDir: String, profile: String?) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: profilesDir) else { return nil }
        let dirs = entries.filter { name in
            var isDir: ObjCBool = false
            let p = profilesDir + "/" + name
            return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
        if let profile = profile, !profile.isEmpty {
            if dirs.contains(profile) { return profilesDir + "/" + profile }
            if let suffix = dirs.first(where: { $0.hasSuffix("." + profile) }) {
                return profilesDir + "/" + suffix
            }
            return nil
        }
        if let preferred = dirs.first(where: { $0.contains(".default") }) {
            return profilesDir + "/" + preferred
        }
        return dirs.first { fm.fileExists(atPath: profilesDir + "/" + $0 + "/cookies.sqlite") }
            .map { profilesDir + "/" + $0 }
    }

    private func chromeSameSite(_ raw: Int) -> String {
        switch raw {
        case 0: return "none"
        case 1: return "lax"
        case 2: return "strict"
        default: return ""
        }
    }

    private func firefoxSameSite(_ raw: Int) -> String {
        switch raw {
        case 1: return "lax"
        case 2: return "strict"
        default: return ""
        }
    }

    // Chrome microseconds-since-1601 -> Unix seconds. 0 or already-expired = session
    // cookie (empty expires, so the injector omits the Expires property).
    private func chromeExpiry(_ us: Int64) -> String {
        guard us > 0 else { return "" }
        let unix = Double(us) / 1_000_000.0 - Self.chromiumEpochOffsetSeconds
        return Self.unixExpiry(unix)
    }

    // Session cookies are reported as an empty expires, never as a past timestamp.
    private static func unixExpiry(_ unix: Double) -> String {
        guard unix > Date().timeIntervalSince1970 else { return "" }
        return String(Int64(unix))
    }

    private func withTempCopy(_ source: String, _ body: (String) -> FBResult<ImportResult>) -> FBResult<ImportResult> {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "fb-cookies-\(UUID().uuidString)"
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            log.error("CookieImport", "temp dir create failed: \(error)")
            return .failure(.importDenied)
        }
        defer { try? fm.removeItem(atPath: dir) }
        let dest = dir + "/" + (source as NSString).lastPathComponent
        do {
            try fm.copyItem(atPath: source, toPath: dest)
            for sidecar in ["-wal", "-shm"] where fm.fileExists(atPath: source + sidecar) {
                try? fm.copyItem(atPath: source + sidecar, toPath: dest + sidecar)
            }
        } catch {
            log.error("CookieImport", "db copy failed: \(error)")
            return .failure(.importDenied)
        }
        return body(dest)
    }

    private func query(_ path: String, _ sql: String, row: (OpaquePointer) -> Void) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return SQLITE_CANTOPEN
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return SQLITE_ERROR
        }
        defer { sqlite3_finalize(stmt) }
        var stepRC = sqlite3_step(stmt)
        while stepRC == SQLITE_ROW {
            row(stmt!)
            stepRC = sqlite3_step(stmt)
        }
        return stepRC == SQLITE_DONE ? SQLITE_OK : stepRC
    }

    private func text(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: cstr)
    }

    private func blobData(_ stmt: OpaquePointer, _ idx: Int32) -> Data {
        let len = Int(sqlite3_column_bytes(stmt, idx))
        guard len > 0, let bytes = sqlite3_column_blob(stmt, idx) else { return Data() }
        return Data(bytes: bytes, count: len)
    }
}
