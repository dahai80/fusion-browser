import Foundation

// P4-2: process-level memory watchdog (OOM self-heal). Periodically samples the
// host process resident size (RSS) via mach_task_basic_info and, on a sustained
// breach of the configured threshold, fires a recovery closure (drain all
// sessions or exit for an external supervisor to restart).
//
// Scope note: WKWebView renders in separate WebContent processes whose RSS is
// NOT counted here. This watchdog guards host-side growth (AXTree strings, JS
// injection buffers, session maps); WebContent bloat is bounded indirectly by
// the per-session quota (FR-08). It is best-effort self-heal, not a substitute
// for quota enforcement.

public struct FBMemoryWatchdogConfig: Codable, Equatable {
    public var enabled: Bool
    public var sampleIntervalMs: Int
    public var thresholdMB: Int
    public var action: String

    public init(enabled: Bool = false, sampleIntervalMs: Int = 30_000,
                thresholdMB: Int = 200, action: String = "close_sessions") {
        self.enabled = enabled
        self.sampleIntervalMs = sampleIntervalMs
        self.thresholdMB = thresholdMB
        self.action = action
    }
}

public enum FBMemoryWatchdogAction: String, Codable, Equatable {
    case closeSessions = "close_sessions"
    case exit = "exit"
}

public final class FBMemoryWatchdog {
    public let config: FBMemoryWatchdogConfig
    private let onBreach: (Int) -> Void
    private let sampler: () -> Int
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fusion-browser.memwatchdog")
    private let log = FBLogger.shared
    private var breachArmed: Bool = true

    public init(config: FBMemoryWatchdogConfig,
                onBreach: @escaping (Int) -> Void,
                sampler: @escaping () -> Int = FBMemoryWatchdog.currentRSSBytes) {
        self.config = config
        self.onBreach = onBreach
        self.sampler = sampler
    }

    public func start() {
        guard config.enabled else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(config.sampleIntervalMs)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        log.info("MemWatchdog", "started interval=\(config.sampleIntervalMs)ms threshold=\(config.thresholdMB)MB action=\(config.action)")
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    // One sample + decision. Public so the decision path is unit-testable without
    // a live timer or WKWebView (RSS syscall works under swift test).
    public func tick() {
        let bytes = sampler()
        let mb = bytes / (1024 * 1024)
        log.debug("MemWatchdog", "rss=\(mb)MB threshold=\(config.thresholdMB)MB")
        if FBMemoryWatchdog.shouldTrigger(rssBytes: bytes, thresholdMB: config.thresholdMB) {
            if breachArmed {
                breachArmed = false
                log.error("MemWatchdog", "RSS breach \(mb)MB > \(config.thresholdMB)MB action=\(config.action)")
                FBMetrics.shared.increment("memwatchdog.breach")
                onBreach(mb)
            } else {
                log.warn("MemWatchdog", "RSS still \(mb)MB > \(config.thresholdMB)MB (disarmed until recovery)")
            }
        } else if !breachArmed {
            log.info("MemWatchdog", "RSS recovered to \(mb)MB, re-arming")
            breachArmed = true
        }
    }

    public static func shouldTrigger(rssBytes: Int, thresholdMB: Int) -> Bool {
        return rssBytes > Int(thresholdMB) * 1024 * 1024
    }

    // mach_task_basic_info.resident_size = RSS in bytes for the calling task.
    public static func currentRSSBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        if kr != KERN_SUCCESS { return 0 }
        return Int(info.resident_size)
    }
}
