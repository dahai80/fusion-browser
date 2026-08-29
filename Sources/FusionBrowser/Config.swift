import Foundation

// FR-08 resource quota + FR-13 scheduling guards + FR-10 allowed origins.
// Per-node dynamic sizing (NFR-R1): session count & total memory by physical RAM.

public struct FBResourceQuota: Codable, Equatable {
    public var maxSessions: Int
    public var maxMemoryPerSessionMB: Int
    public var maxTotalMemoryMB: Int
    // H-2: the old `maxWebContentProcesses` field was a DEAD field — declared, set to
    // maxSessions, and read nowhere (grep confirmed). It only made FR-08's "WebContent
    // process cap" look implemented while providing zero enforcement (operators set it to
    // 4, got 10 processes). Removed: no config key lies about an unenforced limit.
    // B-2: the live WebContent process count is bounded by the session cap (maxSessions,
    // enforced in SessionManager) + WebKit's built-in per-site process isolation. The old
    // shared WKProcessPool was deprecated (macOS 12+, no-op) and never enforced a cap;
    // it was removed. FBMemoryWatchdog.totalRSSBytes samples host+WebContent RSS as the
    // real memory backstop (P4-2, default off — enable for production).

    public init(maxSessions: Int, maxMemoryPerSessionMB: Int, maxTotalMemoryMB: Int) {
        self.maxSessions = maxSessions
        self.maxMemoryPerSessionMB = maxMemoryPerSessionMB
        self.maxTotalMemoryMB = maxTotalMemoryMB
    }

    // NFR-R1: by physical RAM. 8GB -> 4 session, 16GB -> 10 session.
    public static func forHost() -> FBResourceQuota {
        return forHost(ramGB: physicalRAMGB())
    }

    // T3.2: explicit-RAM overload so the tiering table is unit-testable without
    // depending on the machine the test runs on.
    public static func forHost(ramGB: Int) -> FBResourceQuota {
        let sessions: Int
        switch ramGB {
        case ..<8: sessions = 2
        case 8..<16: sessions = 4
        case 16..<32: sessions = 10
        default: sessions = 16
        }
        let perSession = 150
        let total = sessions * perSession
        return FBResourceQuota(maxSessions: sessions, maxMemoryPerSessionMB: perSession,
                               maxTotalMemoryMB: total)
    }
}

func physicalRAMGB() -> Int {
    var size: UInt64 = 0
    var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
    var len = MemoryLayout<UInt64>.size
    let r = sysctl(&mib, 2, &size, &len, nil, 0)
    if r != 0 { return 8 }
    return Int(size / (1024 * 1024 * 1024))
}

// H-9: host free memory in MB (active+inactive+wired backed out of physmem). Used by
// FBNodeCapacity so an external scheduler (fusion-gateway) can place browser sessions on
// the node with the most headroom. mach_host_self + HOST_VM_INFO. Returns 0 on probe
// failure (honest — never fabricates free memory; the scheduler treats 0 as unknown and
// falls back to live-session-count placement). Free here is physmem - (active+wired);
// inactive/reclaimable is omitted deliberately because it is not guaranteed reclaimable
// under memory pressure, so the reported free is a CONSERVATIVE floor, not an optimistic
// upper bound. Conservative is correct for placement: oversubscription is worse than
// leaving headroom on the table.
func freeMemoryMB() -> Int {
    var pageSize: vm_size_t = 0
    let ps = withUnsafeMutablePointer(to: &pageSize) { ptr in
        host_page_size(mach_host_self(), ptr)
    }
    if ps != KERN_SUCCESS || pageSize == 0 { return 0 }
    var vmStat = vm_statistics_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics_data_t>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &vmStat) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics(mach_host_self(), HOST_VM_INFO, intPtr, &count)
        }
    }
    if r != KERN_SUCCESS { return 0 }
    let active = Int(vmStat.active_count) * Int(pageSize)
    let wired = Int(vmStat.wire_count) * Int(pageSize)
    let physMB = physicalRAMGB() * 1024
    let used = (active + wired) / (1024 * 1024)
    let free = physMB - used
    return free > 0 ? free : 0
}

// H-9 / R-10: per-node capacity report — the scheduler-placement input. fusion-browser
// is a NON-PERSISTENT single-node engine (FR-04); cross-node scheduling/migration lands in
// fusion-gateway (audit R-10 改法: "跨节点调度/迁移落地可能在 fusion-gateway，本侧出契约+
// issue"). THIS side exposes the capacity plane: a node id + the live session count + free
// memory, so an external scheduler can read capacity -> pick a node -> route create. nodeId
// is minted ONCE per engine process (UUID); a restart mints a new id (honest for a
// non-persistent engine — there is no sticky node identity to preserve). Exposed via the
// UDS `{type:"capacity"}` request (gated behind .metrics cap — read-only resource info,
// lower-sensitivity than metrics counters; an operator exposing metrics already exposes
// resource shape). The scheduler MUST NOT rely on nodeId being stable across restarts.
public struct FBNodeCapacity: Codable, Equatable {
    public var nodeId: String
    public var maxSessions: Int
    public var liveSessions: Int
    public var maxTotalMemoryMB: Int
    public var freeMemoryMB: Int
    public var ramGB: Int

    // Custom encode/decode keyed by the camelCase forms the global strategy produces.
    // FBFrame.encoder uses .convertToSnakeCase (camelCase key -> snake_case wire) and
    // FBFrame.decoder uses .convertFromSnakeCase (snake_case wire -> camelCase key match).
    // We MUST key by the post-strategy camelCase, not the raw snake string, because the
    // strategy applies to the CodingKey.stringValue even for explicit keys. The gotcha:
    // consecutive-cap acronyms (ramGB, maxTotalMemoryMB) — .convertFromSnakeCase turns
    // "ram_gb" into "ramGb" (lowercases the letter after the underscore), NOT "ramGB", so
    // the key rawValue must be "ramGb" / "maxTotalMemoryMb" / "freeMemoryMb" to match.
    // Auto-synthesized keys would hit the same mismatch (property "ramGB" vs converted
    // "ramGb"), so auto-synthesis returns nil — this custom codec is the fix. The WIRE
    // output is the stable snake_case contract an external scheduler parses:
    // node_id, max_sessions, live_sessions, max_total_memory_mb, free_memory_mb, ram_gb.
    private enum WireKeys: String, CodingKey {
        case nodeId = "nodeId"
        case maxSessions = "maxSessions"
        case liveSessions = "liveSessions"
        case maxTotalMemoryMB = "maxTotalMemoryMb"
        case freeMemoryMB = "freeMemoryMb"
        case ramGB = "ramGb"
    }

    public init(nodeId: String, maxSessions: Int, liveSessions: Int,
                maxTotalMemoryMB: Int, freeMemoryMB: Int, ramGB: Int) {
        self.nodeId = nodeId
        self.maxSessions = maxSessions
        self.liveSessions = liveSessions
        self.maxTotalMemoryMB = maxTotalMemoryMB
        self.freeMemoryMB = freeMemoryMB
        self.ramGB = ramGB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        maxSessions = try c.decode(Int.self, forKey: .maxSessions)
        liveSessions = try c.decode(Int.self, forKey: .liveSessions)
        maxTotalMemoryMB = try c.decode(Int.self, forKey: .maxTotalMemoryMB)
        freeMemoryMB = try c.decode(Int.self, forKey: .freeMemoryMB)
        ramGB = try c.decode(Int.self, forKey: .ramGB)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKeys.self)
        try c.encode(nodeId, forKey: .nodeId)
        try c.encode(maxSessions, forKey: .maxSessions)
        try c.encode(liveSessions, forKey: .liveSessions)
        try c.encode(maxTotalMemoryMB, forKey: .maxTotalMemoryMB)
        try c.encode(freeMemoryMB, forKey: .freeMemoryMB)
        try c.encode(ramGB, forKey: .ramGB)
    }

    // Builds the live capacity snapshot for THIS node from the configured quota + the
    // current live-session count. nodeId is minted once per process via a lazy static so
    // every snapshot within one engine lifetime reports the SAME id (stable for a
    // scheduler's placement session); freeMemoryMB is probed live each call (placement
    // needs current headroom, not a stale snapshot). ramGB via physicalRAMGB().
    public static func current(quota: FBResourceQuota, liveSessions: Int) -> FBNodeCapacity {
        return FBNodeCapacity(
            nodeId: Self.processNodeId,
            maxSessions: quota.maxSessions,
            liveSessions: liveSessions,
            maxTotalMemoryMB: quota.maxTotalMemoryMB,
            freeMemoryMB: FusionBrowser.freeMemoryMB(),
            ramGB: physicalRAMGB()
        )
    }

    // One UUID per engine process. Lazy static — minted on first use, reused thereafter.
    // NOT persisted (non-persistent engine); a restart is a new node identity.
    static let processNodeId: String = UUID().uuidString
}

public struct FBSchedulingGuards: Codable, Equatable {
    public var maxActions: Int
    public var taskTimeoutMs: Int
    public var repeatActionBreak: Int
    public var rebuildDepthCap: Int

    public init(maxActions: Int = 200, taskTimeoutMs: Int = 300_000,
                repeatActionBreak: Int = 3, rebuildDepthCap: Int = 1) {
        self.maxActions = maxActions
        self.taskTimeoutMs = taskTimeoutMs
        self.repeatActionBreak = repeatActionBreak
        self.rebuildDepthCap = rebuildDepthCap
    }
}

// FR-10 allowed origins for EVALUATE.
public struct FBWatchdogPolicy {
    public var navigateMs: Int
    public var clickMs: Int
    public var typeMs: Int
    public var scrollMs: Int
    public var screenshotMs: Int
    public var evaluateMs: Int

    public init(navigateMs: Int = 30_000, clickMs: Int = 2_000, typeMs: Int = 2_000,
                scrollMs: Int = 500, screenshotMs: Int = 5_000, evaluateMs: Int = 5_000) {
        self.navigateMs = navigateMs
        self.clickMs = clickMs
        self.typeMs = typeMs
        self.scrollMs = scrollMs
        self.screenshotMs = screenshotMs
        self.evaluateMs = evaluateMs
    }

    public func timeout(for action: ActionType) -> Int {
        switch action {
        case .navigate: return navigateMs
        case .click: return clickMs
        case .typeText: return typeMs
        case .scroll: return scrollMs
        case .screenshot: return screenshotMs
        case .evaluate: return evaluateMs
        case .close: return 2_000
        }
    }

    public static let `default` = FBWatchdogPolicy()
}

public struct FBEngineConfig: Codable {
    public var socketPath: String
    public var cdpPort: Int
    public var cdpEnabled: Bool
    public var authToken: String?
    // H-5: capabilities granted to the configured authToken. Defaults to empty
    // list → FBAuth uses .default (navigate/click/type/scroll/screenshot/close,
    // NO evaluate). Set e.g. ["evaluate"] or ["all"] to make Runtime.evaluate
    // reachable; without it evaluate is cap-gated off (evaluate_denied). Unknown
    // names dropped fail-closed. Parsed by FBAuth.parseCaps at startup.
    public var tokenCapabilities: [String]
    public var allowedOrigins: [String]
    public var quota: FBResourceQuota
    public var guards: FBSchedulingGuards
    public var watchdog: FBWatchdogPolicyEncoder
    public var logLevel: String
    // T3.4: visual-grounding fallback config (CoreGraphics/WKSnapshot -> fusion-mlx VLM).
    public var visualLocator: FBVisualLocatorConfig
    // P4-2: process-level RSS watchdog (OOM self-heal). Default off.
    public var memoryWatchdog: FBMemoryWatchdogConfig
    // R-5: idle-session reaper. Default ON — a client that creates sessions and disconnects
    // left them live forever, letting one client burn the whole session cap (quota DoS). The
    // reaper closes sessions idle past idleTimeoutMs. Disable by setting enabled=false.
    public var sessionReaper: FBSessionReaperConfig
    // H-8: per-client rate limit (main-thread fair scheduling). Default ON.
    public var rateLimit: FBRateLimitConfig

    public init(socketPath: String = "/tmp/fusion-browser.sock",
                cdpPort: Int = 9222, cdpEnabled: Bool = false,
                authToken: String? = nil, tokenCapabilities: [String] = [],
                allowedOrigins: [String] = [],
                quota: FBResourceQuota = .forHost(),
                guards: FBSchedulingGuards = FBSchedulingGuards(),
                watchdog: FBWatchdogPolicyEncoder = FBWatchdogPolicyEncoder(),
                logLevel: String = "info",
                visualLocator: FBVisualLocatorConfig = FBVisualLocatorConfig(),
                memoryWatchdog: FBMemoryWatchdogConfig = FBMemoryWatchdogConfig(),
                sessionReaper: FBSessionReaperConfig = FBSessionReaperConfig(),
                rateLimit: FBRateLimitConfig = FBRateLimitConfig()) {
        self.socketPath = socketPath
        self.cdpPort = cdpPort
        self.cdpEnabled = cdpEnabled
        self.authToken = authToken
        self.tokenCapabilities = tokenCapabilities
        self.allowedOrigins = allowedOrigins
        self.quota = quota
        self.guards = guards
        self.watchdog = watchdog
        self.logLevel = logLevel
        self.visualLocator = visualLocator
        self.memoryWatchdog = memoryWatchdog
        self.sessionReaper = sessionReaper
        self.rateLimit = rateLimit
    }

    public static let `default` = FBEngineConfig()

    enum CodingKeys: String, CodingKey {
        case socketPath, cdpPort, cdpEnabled, authToken, tokenCapabilities, allowedOrigins, quota, guards, watchdog, logLevel, visualLocator, memoryWatchdog, sessionReaper, rateLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FBEngineConfig.default
        socketPath = try c.decodeIfPresent(String.self, forKey: .socketPath) ?? d.socketPath
        cdpPort = try c.decodeIfPresent(Int.self, forKey: .cdpPort) ?? d.cdpPort
        cdpEnabled = try c.decodeIfPresent(Bool.self, forKey: .cdpEnabled) ?? d.cdpEnabled
        authToken = try c.decodeIfPresent(String.self, forKey: .authToken) ?? d.authToken
        tokenCapabilities = try c.decodeIfPresent([String].self, forKey: .tokenCapabilities) ?? d.tokenCapabilities
        allowedOrigins = try c.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? d.allowedOrigins
        quota = try c.decodeIfPresent(FBResourceQuota.self, forKey: .quota) ?? d.quota
        guards = try c.decodeIfPresent(FBSchedulingGuards.self, forKey: .guards) ?? d.guards
        watchdog = try c.decodeIfPresent(FBWatchdogPolicyEncoder.self, forKey: .watchdog) ?? d.watchdog
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? d.logLevel
        visualLocator = try c.decodeIfPresent(FBVisualLocatorConfig.self, forKey: .visualLocator) ?? d.visualLocator
        memoryWatchdog = try c.decodeIfPresent(FBMemoryWatchdogConfig.self, forKey: .memoryWatchdog) ?? d.memoryWatchdog
        sessionReaper = try c.decodeIfPresent(FBSessionReaperConfig.self, forKey: .sessionReaper) ?? d.sessionReaper
        rateLimit = try c.decodeIfPresent(FBRateLimitConfig.self, forKey: .rateLimit) ?? d.rateLimit
    }
}

// R-5: idle-session reaper config. Closes sessions with no executed action for
// idleTimeoutMs, checked every checkIntervalMs. Default ON (quota-DoS protection).
public struct FBSessionReaperConfig: Codable, Equatable {
    public var enabled: Bool
    public var idleTimeoutMs: Int
    public var checkIntervalMs: Int

    public init(enabled: Bool = true, idleTimeoutMs: Int = 1_800_000,
                checkIntervalMs: Int = 60_000) {
        self.enabled = enabled
        self.idleTimeoutMs = idleTimeoutMs
        self.checkIntervalMs = checkIntervalMs
    }
}

// Codable wrapper for FBWatchdogPolicy (struct has no Codable).
public struct FBWatchdogPolicyEncoder: Codable, Equatable {
    public var navigateMs: Int
    public var clickMs: Int
    public var typeMs: Int
    public var scrollMs: Int
    public var screenshotMs: Int
    public var evaluateMs: Int

    public init(navigateMs: Int = 30_000, clickMs: Int = 2_000, typeMs: Int = 2_000,
                scrollMs: Int = 500, screenshotMs: Int = 5_000, evaluateMs: Int = 5_000) {
        self.navigateMs = navigateMs
        self.clickMs = clickMs
        self.typeMs = typeMs
        self.scrollMs = scrollMs
        self.screenshotMs = screenshotMs
        self.evaluateMs = evaluateMs
    }

    public func policy() -> FBWatchdogPolicy {
        return FBWatchdogPolicy(navigateMs: navigateMs, clickMs: clickMs, typeMs: typeMs,
                                scrollMs: scrollMs, screenshotMs: screenshotMs, evaluateMs: evaluateMs)
    }
}
