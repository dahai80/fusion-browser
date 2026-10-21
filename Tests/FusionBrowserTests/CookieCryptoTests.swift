import XCTest
import CommonCrypto
@testable import FusionBrowser

// Issue #25: Chromium cookie decryption (macOS). v10/v11 = AES-128-CBC with a key derived
// from the browser's Keychain "Safe Storage" password; v20 = M127+ app-bound encryption
// that third parties cannot decrypt (honestly reported as skipped, never "failed").
final class CookieCryptoTests: XCTestCase {
    private let fixedPassword = Data("test-safe-storage-password".utf8)

    func testKeyDerivationDeterministic() {
        let a = FBChromiumCookieCrypto.deriveKey(password: fixedPassword)
        let b = FBChromiumCookieCrypto.deriveKey(password: fixedPassword)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16, "AES-128 key")
        XCTAssertNotEqual(a, FBChromiumCookieCrypto.deriveKey(password: Data("other".utf8)))
    }

    func testRoundtripV10() {
        let key = FBChromiumCookieCrypto.deriveKey(password: fixedPassword)
        let cipher = encryptV10("session-value-123", key: key)
        let (value, status) = FBChromiumCookieCrypto.decrypt(cipher, key: key)
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(value, "session-value-123")
    }

    func testRoundtripV11Prefix() {
        let key = FBChromiumCookieCrypto.deriveKey(password: fixedPassword)
        var cipher = encryptV10("v11-value", key: key)
        cipher.replaceSubrange(0..<3, with: Data("v11".utf8))
        let (value, status) = FBChromiumCookieCrypto.decrypt(cipher, key: key)
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(value, "v11-value")
    }

    func testWrongKeyFailsCleanly() {
        let key = FBChromiumCookieCrypto.deriveKey(password: fixedPassword)
        let otherKey = FBChromiumCookieCrypto.deriveKey(password: Data("other".utf8))
        let (value, status) = FBChromiumCookieCrypto.decrypt(encryptV10("x", key: key), key: otherKey)
        XCTAssertNil(value)
        XCTAssertEqual(status, .failed)
    }

    func testAppBoundV20ReportedAsAppBound() {
        let key = FBChromiumCookieCrypto.deriveKey(password: fixedPassword)
        let (value, status) = FBChromiumCookieCrypto.decrypt(Data("v20\u{01}\u{02}garbage".utf8), key: key)
        XCTAssertNil(value)
        XCTAssertEqual(status, .appBound, "v20 must be a distinct skip reason, not a failure")
    }

    func testPlaintextBlob() {
        let (value, status) = FBChromiumCookieCrypto.decrypt(Data("plain-cookie".utf8), key: Data())
        XCTAssertEqual(value, "plain-cookie")
        XCTAssertEqual(status, .plaintext)
    }

    func testTruncatedCipherNoCrash() {
        let key = FBChromiumCookieCrypto.deriveKey(password: fixedPassword)
        let full = encryptV10("abcdefgh", key: key)
        let truncated = full.prefix(8)
        let (value, status) = FBChromiumCookieCrypto.decrypt(Data(truncated), key: key)
        XCTAssertNil(value)
        XCTAssertEqual(status, .failed, "a short body must fail closed, never trap")
    }

    // Test-only helper: Chromium-compatible encrypt (AES-128-CBC, IV = 16 x 0x20, PKCS7).
    private func encryptV10(_ plain: String, key: Data) -> Data {
        let data = Data(plain.utf8)
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var outLen = 0
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let ok = out.withUnsafeMutableBytes { outBuf in
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
        XCTAssertEqual(ok, CCCryptorStatus(kCCSuccess))
        let body = out.prefix(outLen)
        return Data("v10".utf8) + body
    }
}
