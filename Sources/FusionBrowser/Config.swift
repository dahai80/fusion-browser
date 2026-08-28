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
