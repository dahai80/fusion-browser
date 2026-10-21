import Foundation
import CommonCrypto

// Issue #25: Chromium (Chrome/Edge) macOS cookie blob decryption.
// macOS Chromium encrypts the `value` column of the Cookies SQLite DB with
// AES-128-CBC. The key is PBKDF2-HMAC-SHA1(password = Keychain "Safe Storage"
// entry, salt = "saltysalt", iterations = 1003, 16 bytes). The synthetic IV is
// 16 x 0x20 and the body is PKCS7 padded. A "v10"/"v11" prefix precedes the
// ciphertext; "v20" is M127+ app-bound encryption, which no third-party process
// can decrypt (it needs the app's own binding key) — reported as .appBound so
// the caller can count it as a skip, not a failure. A blob with no prefix is
// legacy plaintext. E-39: values are NEVER logged — only length/status.

public enum FBDecryptStatus: String {
    case ok
    case appBound
    case plaintext
    case failed
}

public enum FBChromiumCookieCrypto {
    private static let salt = Data("saltysalt".utf8)
    private static let ivBytes = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    private static let log = FBLogger.shared

    public static func deriveKey(password: Data, iterations: Int = 1003, keyLength: Int = 16) -> Data {
        guard !password.isEmpty, keyLength > 0 else {
            log.warn("Cookie", "key derivation skipped emptyPassword=\(password.isEmpty) keyLength=\(keyLength)")
            return Data(count: max(keyLength, 0))
        }
        var key = Data(count: keyLength)
        let rc = key.withUnsafeMutableBytes { keyBuf in
            password.withUnsafeBytes { passBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passBuf.bindMemory(to: Int8.self).baseAddress, password.count,
                                         saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(iterations),
                                         keyBuf.bindMemory(to: UInt8.self).baseAddress, keyLength)
                }
            }
        }
        if rc != kCCSuccess {
            log.error("Cookie", "PBKDF2 failed rc=\(rc)")
        }
        return key
    }

    public static func decrypt(_ blob: Data, key: Data) -> (value: String?, status: FBDecryptStatus) {
        if blob.count >= 3, blob.prefix(3) == Data("v20".utf8) {
            log.info("Cookie", "v20 app-bound cookie skipped len=\(blob.count)")
            return (nil, .appBound)
        }
        let prefix = blob.prefix(3)
        if prefix == Data("v10".utf8) || prefix == Data("v11".utf8) {
            return decryptCBC(Data(blob.dropFirst(3)), key: key)
        }
        guard let plain = String(data: blob, encoding: .utf8) else {
            log.warn("Cookie", "undecryptable blob noPrefix nonUTF8 len=\(blob.count)")
            return (nil, .failed)
        }
        return (plain, .plaintext)
    }

    private static func decryptCBC(_ body: Data, key: Data) -> (value: String?, status: FBDecryptStatus) {
        let validKey = key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES192 || key.count == kCCKeySizeAES256
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0, validKey else {
            log.warn("Cookie", "cipher shape invalid len=\(body.count) keyLen=\(key.count)")
            return (nil, .failed)
        }
        let outCapacity = body.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var outLen = 0
        let rc = out.withUnsafeMutableBytes { outBuf in
            body.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count, ivBytes,
                            inBuf.baseAddress, body.count,
                            outBuf.baseAddress, outCapacity, &outLen)
                }
            }
        }
        guard rc == CCCryptorStatus(kCCSuccess) else {
            log.warn("Cookie", "CBC decrypt failed rc=\(rc) len=\(body.count)")
            return (nil, .failed)
        }
        guard let value = String(data: out.prefix(outLen), encoding: .utf8) else {
            log.warn("Cookie", "decrypted bytes not UTF-8 len=\(outLen)")
            return (nil, .failed)
        }
        log.debug("Cookie", "decrypted cookie len=\(outLen)")
        return (value, .ok)
    }
}
