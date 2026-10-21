import XCTest
import SQLite3
import CommonCrypto
import CryptoKit
@testable import FusionBrowser

// Issue #25: browser cookie readers. Tests build real SQLite fixtures (the same
// schema shapes Chrome/Edge/Firefox use) and drive the importer through an injected
// config so no real browser profile is touched. E-39: assertions never log values.
final class BrowserCookieImportTests: XCTestCase {
    private var tmpDir = ""

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "fb-cookie-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private let password = Data("test-safe-storage-password".utf8)

    func testChromiumV10RowMapsAllAttrs() throws {
        let base = tmpDir + "/chrome"
        let db = base + "/Default/Network/Cookies"
        try makeChromiumDB(db)
        let key = FBChromiumCookieCrypto.deriveKey(password: password)
        let cipher = encryptV10("tok-123", key: key)
        execSQL(db, "INSERT INTO cookies (host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite) VALUES ('.example.com','sid','',\(blob(cipher)),'/',\((2_000_000_000.0 + 11644473600.0) * 1_000_000),1,1,2);")

        let importer = makeImporter(chromeDir: base)
        guard case .success(let result) = importer.importCookies(kind: .chrome) else {
            return XCTFail("expected success, got failure")
        }
        XCTAssertEqual(result.cookies.count, 1)
        let attrs = try XCTUnwrap(result.cookies.first?.attrs)
        XCTAssertEqual(attrs["name"], "sid")
        XCTAssertEqual(attrs["value"], "tok-123")
        XCTAssertEqual(attrs["domain"], ".example.com", "leading dot is preserved")
        XCTAssertEqual(attrs["path"], "/")
        XCTAssertEqual(attrs["secure"], "true")
        XCTAssertEqual(attrs["httponly"], "true")
        XCTAssertEqual(attrs["samesite"], "strict")
        XCTAssertEqual(attrs["expires"], "2000000000")
        XCTAssertEqual(result.skippedAppBound, 0)
        XCTAssertEqual(result.skippedOther, 0)
    }

    // Chrome 127+ (cookies DB meta version 24+) binds a v10/v11 value to its host by
    // prepending SHA256(host_key) (32 bytes) to the plaintext BEFORE encryption. The
    // decryptor must verify-then-strip that prefix, else every encrypted row on a modern
    // Chrome profile fails UTF-8 decode and is silently counted as skipped.
    func testChromiumV10HostKeyHashPrefixStripped() throws {
        let base = tmpDir + "/chrome"
        let db = base + "/Default/Network/Cookies"
        try makeChromiumDB(db)
        let key = FBChromiumCookieCrypto.deriveKey(password: password)
        let host = ".example.com"
        let bound = Data(SHA256.hash(data: Data(host.utf8))) + Data("tok-abc".utf8)
        let cipher = encryptV10Blob(bound, key: key)
        execSQL(db, "INSERT INTO cookies (host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite) VALUES ('\(host)','sid','',\(blob(cipher)),'/',0,0,0,0);")

        let importer = makeImporter(chromeDir: base)
        guard case .success(let result) = importer.importCookies(kind: .chrome) else {
            return XCTFail("expected success, got failure")
        }
        XCTAssertEqual(result.cookies.count, 1)
        XCTAssertEqual(result.cookies.first?.attrs["value"], "tok-abc")
        XCTAssertEqual(result.skippedOther, 0, "a host-bound value must not be skipped")
    }

    // The strip is verify-then-strip, NOT a blind 32-byte slice: a long value that does not
    // start with SHA256(host_key) must arrive intact.
    func testChromiumV10LongValueKeptWhenHashDoesNotMatch() throws {
        let base = tmpDir + "/chrome"
        let db = base + "/Default/Network/Cookies"
        try makeChromiumDB(db)
        let key = FBChromiumCookieCrypto.deriveKey(password: password)
        let plain = String(repeating: "a", count: 40)
        let cipher = encryptV10Blob(Data(plain.utf8), key: key)
        execSQL(db, "INSERT INTO cookies (host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite) VALUES ('.example.com','sid','',\(blob(cipher)),'/',0,0,0,0);")

        let importer = makeImporter(chromeDir: base)
        guard case .success(let result) = importer.importCookies(kind: .chrome) else {
            return XCTFail("expected success, got failure")
        }
        XCTAssertEqual(result.cookies.first?.attrs["value"], plain)
    }

    func testChromiumV20CountedAsAppBound() throws {
        let base = tmpDir + "/chrome"
        let db = base + "/Default/Cookies"
        try makeChromiumDB(db)
        let v20 = Data("v20-app-bound-garbage".utf8)
        execSQL(db, "INSERT INTO cookies (host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite) VALUES ('.example.com','sess','',\(blob(v20)),'/',0,0,0,-1);")

        guard case .success(let result) = makeImporter(chromeDir: base).importCookies(kind: .chrome) else {
            return XCTFail("expected success, got failure")
        }
        XCTAssertEqual(result.cookies.count, 0)
        XCTAssertEqual(result.skippedAppBound, 1)
        XCTAssertEqual(result.skippedOther, 0)
    }

    func testChromiumPlaintextValueImported() throws {
        let base = tmpDir + "/chrome"
        let db = base + "/Default/Cookies"
        try makeChromiumDB(db)
        execSQL(db, "INSERT INTO cookies (host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite) VALUES ('plain.example','lang','zh-CN',X'','/',0,0,0,1);")

        guard case .success(let result) = makeImporter(chromeDir: base).importCookies(kind: .chrome) else {
            return XCTFail("expected success, got failure")
        }
        XCTAssertEqual(result.cookies.count, 1)
        let attrs = try XCTUnwrap(result.cookies.first?.attrs)
        XCTAssertEqual(attrs["value"], "zh-CN")
        XCTAssertEqual(attrs["samesite"], "lax")
        XCTAssertEqual(attrs["expires"], "", "0 chrome epoch is a session cookie")
    }

    func testChromiumPrefersNetworkCookiesPath() throws {
        let base = tmpDir + "/chrome"
        try makeChromiumDB(base + "/Default/Network/Cookies")
        try makeChromiumDB(base + "/Default/Cookies")
        execSQL(base + "/Default/Network/Cookies", "INSERT INTO cookies (host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite) VALUES ('n.example','network_cookie','n',X'','/',0,0,0,-1);")
        execSQL(base + "/Default/Cookies", "INSERT INTO cookies (host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite) VALUES ('r.example','root_cookie','r',X'','/',0,0,0,-1);")

        guard case .success(let result) = makeImporter(chromeDir: base).importCookies(kind: .chrome) else {
            return XCTFail("expected success, got failure")
        }
        XCTAssertEqual(result.cookies.map { $0.attrs["name"] }, ["network_cookie"])
    }

    func testChromiumMissingDatabaseFailsCleanly() {
        let importer = makeImporter(chromeDir: tmpDir + "/does-not-exist")
        guard case .failure(let err) = importer.importCookies(kind: .chrome) else {
            return XCTFail("expected failure for a missing database")
        }
        XCTAssertEqual(err.code, "import_denied")
    }

    func testFirefoxRowMappingAndSameSite() throws {
        let db = tmpDir + "/firefox/abc123.default-release/cookies.sqlite"
        try makeFirefoxDB(db)
        execSQL(db, "INSERT INTO moz_cookies (name,value,host,path,expiry,isSecure,isHttpOnly,sameSite) VALUES ('a','v0','.ex.com','/',0,0,0,0);")
        execSQL(db, "INSERT INTO moz_cookies (name,value,host,path,expiry,isSecure,isHttpOnly,sameSite) VALUES ('b','v1','.ex.com','/',1800000000,1,1,1);")
        execSQL(db, "INSERT INTO moz_cookies (name,value,host,path,expiry,isSecure,isHttpOnly,sameSite) VALUES ('c','v2','.ex.com','/',1800000000,0,0,2);")

        let importer = FBBrowserCookieImporter(config: FBCookieImportConfig(
            chromeUserDataDir: tmpDir + "/chrome",
            edgeUserDataDir: tmpDir + "/edge",
            firefoxProfilesDir: tmpDir + "/firefox")) { _ in nil }
        guard case .success(let result) = importer.importCookies(kind: .firefox) else {
            return XCTFail("expected success, got failure")
        }
        let byName = Dictionary(uniqueKeysWithValues: result.cookies.map { ($0.attrs["name"] ?? "", $0.attrs) })
        XCTAssertEqual(byName["a"]?["samesite"], "", "firefox 0 = unset")
        XCTAssertEqual(byName["a"]?["expires"], "", "expiry 0 = session cookie")
        XCTAssertEqual(byName["b"]?["samesite"], "lax")
        XCTAssertEqual(byName["b"]?["secure"], "true")
        XCTAssertEqual(byName["b"]?["httponly"], "true")
        XCTAssertEqual(byName["b"]?["expires"], "1800000000")
        XCTAssertEqual(byName["c"]?["samesite"], "strict")
        XCTAssertEqual(byName["a"]?["domain"], ".ex.com")
    }

    func testFirefoxNamedProfileSelection() throws {
        try makeFirefoxDB(tmpDir + "/firefox/aaa.default/cookies.sqlite")
        try makeFirefoxDB(tmpDir + "/firefox/bbb.work/cookies.sqlite")
        execSQL(tmpDir + "/firefox/aaa.default/cookies.sqlite", "INSERT INTO moz_cookies (name,value,host,path,expiry,isSecure,isHttpOnly,sameSite) VALUES ('default_one','x','.ex.com','/',0,0,0,0);")
        execSQL(tmpDir + "/firefox/bbb.work/cookies.sqlite", "INSERT INTO moz_cookies (name,value,host,path,expiry,isSecure,isHttpOnly,sameSite) VALUES ('work_one','y','.ex.com','/',0,0,0,0);")

        let importer = FBBrowserCookieImporter(config: FBCookieImportConfig(
            chromeUserDataDir: tmpDir + "/chrome",
            edgeUserDataDir: tmpDir + "/edge",
            firefoxProfilesDir: tmpDir + "/firefox")) { _ in nil }
        guard case .success(let result) = importer.importCookies(kind: .firefox, profile: "bbb.work") else {
            return XCTFail("expected success, got failure")
        }
        XCTAssertEqual(result.cookies.map { $0.attrs["name"] }, ["work_one"])
    }

    func testEdgeUsesEdgeUserDataDir() throws {
        let base = tmpDir + "/edge"
        try makeChromiumDB(base + "/Default/Cookies")
        execSQL(base + "/Default/Cookies", "INSERT INTO cookies (host_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,samesite) VALUES ('e.example','edge_cookie','e',X'','/',0,0,0,-1);")

        let importer = FBBrowserCookieImporter(config: FBCookieImportConfig(
            chromeUserDataDir: tmpDir + "/chrome-unused",
            edgeUserDataDir: base,
            firefoxProfilesDir: tmpDir + "/firefox")) { _ in nil }
        guard case .success(let result) = importer.importCookies(kind: .edge) else {
            return XCTFail("expected success, got failure")
        }
        XCTAssertEqual(result.cookies.map { $0.attrs["name"] }, ["edge_cookie"])
    }

    // MARK: helpers

    private func makeImporter(chromeDir: String) -> FBBrowserCookieImporter {
        FBBrowserCookieImporter(config: FBCookieImportConfig(
            chromeUserDataDir: chromeDir,
            edgeUserDataDir: tmpDir + "/edge",
            firefoxProfilesDir: tmpDir + "/firefox")) { [password] _ in
                FBChromiumCookieCrypto.deriveKey(password: password)
            }
    }

    private func makeChromiumDB(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        execSQL(path, """
        CREATE TABLE cookies (creation_utc INTEGER, host_key TEXT, name TEXT, value TEXT,
            encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER,
            is_httponly INTEGER, samesite INTEGER);
        """)
    }

    private func makeFirefoxDB(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        execSQL(path, """
        CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT,
            path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER);
        """)
    }

    private func execSQL(_ path: String, _ sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK, "open \(path)")
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "exec: \(sql)")
    }

    private func blob(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }

    private func encryptV10(_ plain: String, key: Data) -> Data {
        encryptV10Blob(Data(plain.utf8), key: key)
    }

    private func encryptV10Blob(_ data: Data, key: Data) -> Data {
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var outLen = 0
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let rc = out.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count, iv,
                            inBuf.baseAddress, data.count,
                            outBuf.baseAddress, outCapacity, &outLen)
                }
            }
        }
        XCTAssertEqual(rc, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + out.prefix(outLen)
    }
}
