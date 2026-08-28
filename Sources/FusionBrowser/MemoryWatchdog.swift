import Foundation

// P4-2: process-level memory watchdog (OOM self-heal). Periodically samples total
// resident size (RSS) via mach_task_basic_info and, on a sustained breach of the
// configured threshold, fires a recovery closure (drain all sessions or exit for
// an external supervisor to restart).
//
// H-2: the old default sampled mach_task_self_ ONLY — the host shell — and the
// scope note explicitly excluded WebContent, the actual memory hog (JS heap,
// decoded images, layer trees). A leaky page pushed WebContent RSS to 4GB while
// host RSS stayed under threshold, so the watchdog never fired and the system
// jetsam-killed the node silently. The default sampler is now totalRSSBytes:
// host RSS + the RSS of every WebContent process that is a descendant of this
// process (the WKWebView renderers), summed. The threshold now applies to the
// WHOLE browser footprint, which is what the operator actually needs bounded.
// The host-only sampler (currentRSSBytes) stays available for callers that want
// to guard host-side growth only; it is no longer the default.

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
                sampler: @escaping () -> Int = FBMemoryWatchdog.totalRSSBytes) {
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
        // M-11: a tick() already dispatched to `queue` can still run after cancel(), firing
        // onBreach on a stopped watchdog (e.g. exit(0) mid-shutdown, or closing an already-
        // drained session list). Drain the queue: a sync barrier waits for any in-flight tick
        // to finish and blocks new timer-driven ticks (timer is nil) before we return.
        queue.sync {}
    }

    // L-20: re-arm policy. The old code only re-armed on RSS recovery (!breachArmed && RSS<=
    // threshold). A TRUE leak — RSS stays high — left breachArmed false forever, so onBreach
    // fired exactly once and the watchdog became a blown fuse precisely in the scenario it
    // exists for (P4-5 long-run leak). Fix: after a breach, start a cooldown counter; while
    // the counter ticks down under sustained high RSS, stay disarmed (don't spam onBreach
    // every sample); when the counter reaches zero, RE-ARM unconditionally so the next
    // sustained-high sample fires onBreach again — the watchdog recycles. Recovery below
    // threshold still re-arms immediately and resets the cooldown. Cooldown length scales
    // with consecutive breaches so repeated leaks eventually fire more often (escalation
    // without a hard one-shot).
    private var breachCooldown: Int = 0
    private var consecutiveBreaches: Int = 0
    private static let cooldownTicks = 3

    // One sample + decision. Public so the decision path is unit-testable without
    // a live timer or WKWebView (RSS syscall works under swift test).
    public func tick() {
        let bytes = sampler()
        let mb = bytes / (1024 * 1024)
        log.debug("MemWatchdog", "rss=\(mb)MB threshold=\(config.thresholdMB)MB")
        if FBMemoryWatchdog.shouldTrigger(rssBytes: bytes, thresholdMB: config.thresholdMB) {
            if breachArmed {
                breachArmed = false
                consecutiveBreaches += 1
                // L-20: arm a cooldown so the NEXT re-arm happens after a few samples, not
                // immediately (avoids firing onBreach every interval on a sustained leak) nor
                // never (the old bug). Escalate: each consecutive breach lengthens the cooldown
                // so a persistent leak re-fires, just less frequently.
                breachCooldown = FBMemoryWatchdog.cooldownTicks + (consecutiveBreaches - 1)
                log.error("MemWatchdog", "RSS breach \(mb)MB > \(config.thresholdMB)MB action=\(config.action) consecutive=\(consecutiveBreaches)")
                FBMetrics.shared.increment("memwatchdog.breach")
                onBreach(mb)
            } else if breachCooldown > 0 {
                breachCooldown -= 1
                if breachCooldown == 0 {
                    // L-20: cooldown elapsed under sustained high RSS -> re-arm so a true leak
                    // re-fires onBreach instead of the watchdog blowing once and dying.
                    breachArmed = true
                    log.warn("MemWatchdog", "re-arming after cooldown; RSS still \(mb)MB > \(config.thresholdMB)MB consecutive=\(consecutiveBreaches)")
                } else {
                    log.warn("MemWatchdog", "RSS still \(mb)MB > \(config.thresholdMB)MB (cooldown \(breachCooldown))")
                }
            }
        } else if !breachArmed {
            // Recovered below threshold -> re-arm immediately and reset the leak counters.
            breachArmed = true
            breachCooldown = 0
            consecutiveBreaches = 0
            log.info("MemWatchdog", "RSS recovered to \(mb)MB, re-arming")
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

    // H-2: total RSS = host RSS + the RSS of every WebContent process descended from this
    // process. WKWebView renders off-process; the host shell's mach_task_self_ RSS misses the
    // JS heap / decoded images / layer tree that live in the separate WebContent renderers —
    // the actual memory hog. Summing the family gives the operator's real browser footprint,
    // which the threshold then bounds. WebContent processes are children of this process (PPID
    // == our pid) and named "com.apple.WebKit.WebContent" (pbi_comm truncated to 16 chars =>
    // "com.apple.WebKit"). libproc (proc_listallpids + proc_pidinfo PROC_PIDTBSDINFO for PPID
    // + proc_pid_rusage RUSAGE_INFO_V0 for ri_resident_size) walks the table without root
    // privileges for processes we own. Best-effort: a syscall failure drops that PID's RSS to
    // 0 and continues (a partial sum still beats the old host-only blind spot). Falls back to
    // host-only RSS if libproc enumeration fails entirely so the watchdog never goes silent.
    public static func totalRSSBytes() -> Int {
        let hostRSS = currentRSSBytes()
        let ourPid = Int(getpid())
        // proc_listallpids(nil, 0) returns the count of all PIDs (pass nil to size).
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return hostRSS }
        var pids = [Int32](repeating: 0, count: Int(count))
        let got = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard got > 0 else { return hostRSS }
        var webContentRSS: Int = 0
        let childCount = Int(got)
        for i in 0..<childCount {
            let pid = pids[i]
            if pid == 0 || Int(pid) == ourPid { continue }
            // PROC_PIDTBSDINFO (3) -> proc_bsdinfo (pbi_ppid, pbi_comm).
            var bsd = proc_bsdinfo()
            let bsz = MemoryLayout<proc_bsdinfo>.size
            let filled = withUnsafeMutablePointer(to: &bsd) { ptr -> Int32 in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(bsz))
            }
            // Only count processes whose parent is us (WKWebView renderers fork from the host).
            // Filled size must cover at least the ppbi_ppid field to trust the PPID read.
            guard filled >= Int32(MemoryLayout<Int32>.stride) else { continue }
            if Int(bsd.pbi_ppid) != ourPid { continue }
            // Name match: pbi_comm is the short command ("com.apple.WebKit.WebContent" ->
            // "com.apple.WebKit" after the 16-char truncation). Match the WebKit prefix to
            // include both the WebContent renderer and any GPU/network helper children.
            let comm = withUnsafePointer(to: &bsd.pbi_comm) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            guard comm.hasPrefix("com.apple.WebKit") else { continue }
            // RUSAGE_INFO_V0 (0): rusage_info_current[0]=ri_resident_size (bytes).
            var ru = rusage_info_current()
            let rret = withUnsafeMutablePointer(to: &ru) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { riPtr in
                    proc_pid_rusage(pid, 0, riPtr)
                }
            }
            guard rret == 0 else { continue }
            webContentRSS += Int(ru.ri_resident_size)
        }
        return hostRSS + webContentRSS
    }
}
