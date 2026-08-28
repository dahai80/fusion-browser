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
    // E-22: session is mid-close (teardown in flight). A concurrent execute on a closing
    // session must fail fast rather than touch a half-destroyed WKWebView (stopLoading/
    // removeFromSuperview/destroy interleaved with evaluateJSSync -> JS completion never
    // fires -> watchdog timeout or trap). Not retryable: the session is gone for good;
    // the caller must create a new one.
    public static let sessionClosing = FBError(code: "session_closing", message: "session is closing; teardown in flight", retryable: false)
    public static let invalidRequest = FBError(code: "invalid_request", message: "malformed request", retryable: false)
    public static let timeout = FBError(code: "timeout", message: "action exceeded watchdog timeout", retryable: true)
    public static let navigateFailed = FBError(code: "navigate_failed", message: "navigation failed", retryable: true)
    public static let ffiPanic = FBError(code: "ffi_panic", message: "core engine panic", retryable: false)
    public static let internalError = FBError(code: "internal_error", message: "unexpected internal error", retryable: false)
    public static let replayLimit = FBError(code: "replay_limit", message: "rebuild recursion depth cap reached (1)", retryable: false)
    // H-8: per-client rate limit exceeded. Retryable — the caller should back off and retry
    // (the bucket refills at ratePerSec, so a brief wait re-admits the request).
    public static let rateLimited = FBError(code: "rate_limited", message: "per-client request rate exceeded; retry after backoff", retryable: true)
    // B-5/E-34: session ownership mismatch. A client may only operate sessions it created
    // (or system-owned sessions whose ownerId is nil). An authed client operating another
    // client's session by id is denied. Not retryable — the caller cannot gain ownership.
    public static let notOwner = FBError(code: "not_owner", message: "session owned by another client", retryable: false)
    // B-5/E-35: per-client in-flight batch cap exceeded. onReadable bounds the number of
    // frames processed per read so a single 64KB recv (~2000 small frames) cannot queue
    // 2000 blocking driver.execute on main. Not retryable as a per-frame denial — the
    // excess frames are buffered and drained on subsequent reads (lossless backpressure).
    public static let busy = FBError(code: "busy", message: "per-client in-flight batch cap reached; retry later", retryable: true)
}

public enum FBResult<T> {
    case success(T)
    case failure(FBError)
}
