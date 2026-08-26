import Foundation

public struct FBError: Error, Codable, Equatable {
    public let code: String
    public let message: String
    public let retryable: Bool

    public init(code: String, message: String, retryable: Bool) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public static let nodeStale = FBError(code: "node_stale", message: "target node no longer exists; re-extract AXTree", retryable: true)
    public static let credentialLocked = FBError(code: "credential_locked", message: "Keychain locked or credential missing", retryable: true)
    public static let credentialNotFound = FBError(code: "credential_not_found", message: "no Keychain item for domain", retryable: false)
    public static let credentialInjected = FBError(code: "credential_injection_failed", message: "credential injection failed", retryable: false)
    public static let quotaExceeded = FBError(code: "quota_exceeded", message: "resource quota exceeded", retryable: false)
    public static let evaluateDenied = FBError(code: "evaluate_denied", message: "EVALUATE not permitted: capability or origin not allowed", retryable: false)
    public static let authDenied = FBError(code: "auth_denied", message: "authentication token invalid or missing", retryable: false)
    public static let sessionNotFound = FBError(code: "session_not_found", message: "session id unknown or already closed", retryable: false)
    public static let invalidRequest = FBError(code: "invalid_request", message: "malformed request", retryable: false)
    public static let timeout = FBError(code: "timeout", message: "action exceeded watchdog timeout", retryable: true)
    public static let navigateFailed = FBError(code: "navigate_failed", message: "navigation failed", retryable: true)
    public static let ffiPanic = FBError(code: "ffi_panic", message: "core engine panic", retryable: false)
    public static let internalError = FBError(code: "internal_error", message: "unexpected internal error", retryable: false)
    public static let replayLimit = FBError(code: "replay_limit", message: "rebuild recursion depth cap reached (1)", retryable: false)
}

public enum FBResult<T> {
    case success(T)
    case failure(FBError)
}
