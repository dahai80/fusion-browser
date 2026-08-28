import Foundation

// H-8: per-client main-thread fair scheduling. A single client can issue execute
// requests as fast as it can read responses; without a gate the client serial
// queue (one per connection) is monopolized and other clients on the shared
// dispatch pool starve. A token-bucket rate limiter caps the admit rate per
// client while still permitting short bursts (so a legit batch of clicks is not
// throttled to the steady rate one-at-a-time).
//
// Token bucket: capacity = burst (max tokens held), refill at ratePerSec tokens/s.
// admit() takes one token if available (returns true) else rejects (returns false).
// A rejected call does NOT consume a token (so a poll loop retrying at the rate
// does not drain the bucket for the next legit caller). Time is monotonic
// (DispatchTime.uptimeNanoseconds) so wall-clock skew / NTP jumps cannot grant
// free tokens. NSLock guards the token count + last-refill timestamp against the
// concurrent admit() callers (a client's serial queue is single-threaded, but the
// limiter is shared and the watchdog/reaper threads can also query).

public final class FBRateLimiter {
    private let lock = NSLock()
    private var tokens: Double
    private var lastRefillNs: UInt64
    public let capacity: Double
    public let ratePerSec: Double
    private let log = FBLogger.shared

    public init(ratePerSec: Double, burst: Int) {
        self.capacity = Double(burst)
        self.ratePerSec = ratePerSec
        self.tokens = Double(burst)
        self.lastRefillNs = DispatchTime.now().uptimeNanoseconds
    }

    // Refill tokens based on elapsed time since the last call, capped at capacity.
    // Must be called under `lock`.
    private func refillLocked(nowNs: UInt64) {
        let elapsed = nowNs > lastRefillNs ? Double(nowNs - lastRefillNs) : 0
        lastRefillNs = nowNs
        if elapsed > 0 {
            tokens = min(capacity, tokens + elapsed / 1_000_000_000.0 * ratePerSec)
        }
    }

    // Attempt to admit one request. Returns true if a token was consumed; false if
    // the bucket is empty (rejected — no token consumed).
    public func admit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        refillLocked(nowNs: nowNs)
        if tokens >= 1 {
            tokens -= 1
            return true
        }
        return false
    }

    // Current token count (test seam). Reflects a refill up to now.
    public var availableTokens: Double {
        lock.lock()
        defer { lock.unlock() }
        refillLocked(nowNs: DispatchTime.now().uptimeNanoseconds)
        return tokens
    }
}

// H-8: rate-limit config. Default ON at 100/s burst 200 (a cooperative automation
// client rarely exceeds this; a runaway loop is throttled while a legitimate burst
// of clicks passes). enabled=false bypasses the limiter entirely (for clients that
// self-throttle or for headless benchmark runs that must not be rate-gated).
public struct FBRateLimitConfig: Codable, Equatable {
    public var enabled: Bool
    public var ratePerSec: Double
    public var burst: Int

    public init(enabled: Bool = true, ratePerSec: Double = 100, burst: Int = 200) {
        self.enabled = enabled
        self.ratePerSec = ratePerSec
        self.burst = burst
    }
}
