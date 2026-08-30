import Foundation
import AppKit

// fusion-browser engine entry point. Wires config -> infra -> server.
// Phase 1: UDS server only. CDP :9222 default off (FR-07/NFR-S3).

let log = FBLogger.shared

func loadConfig() -> FBEngineConfig {
    // Config file at ~/.fusion-browser/config.json optional; else default.
    // L-17: a MISSING file is fine (defaults). But a PRESENT-but-malformed file MUST fail
    // loud — the old path logged a warn and fell back to FBEngineConfig.default, so an
    // operator who typo'd authToken as a number (decode throws) got an engine that silently
    // started with authToken=nil (denies ALL UDS) or cdpEnabled=false (CDP silently off),
    // burning hours before anyone noticed. Rule 12: fail visibly. Decode error -> exit(1)
    // + stderr so the operator sees the exact parse failure immediately, not a green log.
    // H-9: FUSION_BROWSER_CONFIG env override — NSHomeDirectory() on macOS ignores the
    // HOME env var (returns the real user home from the pwd DB), so multi-node test/CI
    // isolation cannot use HOME. The env override lets a harness (scripts/multinode_smoke.py,
    // the self-hosted runner) point each binary at its own config without touching the
    // operator's ~/.fusion-browser. Honored BEFORE the default path so an explicit override
    // wins; absent -> falls through to the default ~/.fusion-browser/config.json.
    let path: String
    if let envCfg = ProcessInfo.processInfo.environment["FUSION_BROWSER_CONFIG"], !envCfg.isEmpty {
        path = envCfg
    } else {
        let home = NSHomeDirectory()
        path = "\(home)/.fusion-browser/config.json"
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        log.info("Main", "no config file, using defaults")
        return FBEngineConfig.default
    }
    do {
        let cfg = try JSONDecoder().decode(FBEngineConfig.self, from: data)
        log.info("Main", "config loaded from \(path)")
        return cfg
    } catch {
        let msg = "config parse failed at \(path): \(error). Fix the JSON or remove the file to use defaults; refusing to start with silent default fallback."
        log.error("Main", msg)
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(1)
    }
}

// P5/crash-fix: process activity token held for app lifetime. The engine is a headless
// .accessory app whose webviews live in offscreen NSWindows (never orderFront) -> macOS
// App Nap suspends the host, and WebKit's ProcessThrottler sends prepareToSuspend IPC to
// each WebContent process. A WKSnapshot (screenshotSync) forces a render that races the
// suspend: under repeated snapshots the ProcessThrottlerActivity refcount traps
// (sendPrepareToSuspendIPC -> ~ProcessThrottlerActivity -> RefCounted::deref -> SIGTRAP
// exit 133). Holding a .userInitiated activity for the whole process disables App Nap, so
// the ProcessThrottler never suspends and WKSnapshot is stable at any frequency. The token
// is retained in a static so it outlives runEngine's stack frame.
private var appActivityToken: NSObjectProtocol?
func bootstrapNSApp() {
    // WKWebView needs an NSApplication + run loop. Headless still requires app context.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    appActivityToken = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "fusion-browser automation engine: headless WKWebView rendering + snapshots must not be App-Napped (ProcessThrottler suspend races WKSnapshot)"
    )
    log.info("Main", "app-nap disabled via process activity token (snapshot stability)")
}

func runEngine() {
    let cfg = loadConfig()
    switch cfg.logLevel {
    case "debug": FBLogger.shared.setMinLevel(.debug)
    case "warn": FBLogger.shared.setMinLevel(.warn)
    case "error": FBLogger.shared.setMinLevel(.error)
    default: FBLogger.shared.setMinLevel(.info)
    }
    log.info("Main", "fusion-browser engine starting")
    log.info("Main", "quota: sessions=\(cfg.quota.maxSessions) mem/sess=\(cfg.quota.maxMemoryPerSessionMB)MB total=\(cfg.quota.maxTotalMemoryMB)MB")
    log.info("Main", "socket=\(cfg.socketPath) cdp=\(cfg.cdpEnabled ? "on:\(cfg.cdpPort)" : "off")")

    // H-5/E-9: elevate the token's capabilities from the config so evaluate
    // (and any other cap) is reachable when the operator opts in. Empty list
    // (default) → .default (no evaluate); ["all"] → full caps. Unknown names
    // dropped fail-closed by FBAuth.parseCaps.
    let tokenCaps = FBAuth.parseCaps(cfg.tokenCapabilities)
    let auth = FBAuth(token: cfg.authToken, caps: tokenCaps.isEmpty ? .default : tokenCaps,
                      systemCaller: cfg.tokenSystemCaller)
    if cfg.tokenSystemCaller {
        log.info("Main", "token system-caller bypass on (operator config tokenSystemCaller=true) — UDS ownership bypassed for this token (proxy/scheduler)")
    }
    let creds = FBCredentialManager()
    let sanitizer = FBSanitizer()
    let watchdog = cfg.watchdog.policy()
    // H-1: no shared extractor — each FBSession owns its own FBAXTreeExtractor (per-session
    // mapping isolation). E-17~20 (#68): pure-Swift extractor (Rust core removed).
    let manager = FBSessionManager(quota: cfg.quota, guards: cfg.guards, watchdog: watchdog,
                                    creds: creds, auth: auth, allowedOrigins: cfg.allowedOrigins,
                                    sessionReaper: cfg.sessionReaper)
    let visualLocator = FBVisualLocator(config: cfg.visualLocator)
    if cfg.visualLocator.enabled {
        log.info("Main", "visual locator on model=\(cfg.visualLocator.model) endpoint=\(cfg.visualLocator.endpoint)")
    }
    let driver = FBActionDriver(watchdog: watchdog, auth: auth, allowedOrigins: cfg.allowedOrigins,
                                sanitizer: sanitizer, visualLocator: visualLocator)
    let server = FBUDSServer(socketPath: cfg.socketPath, manager: manager, driver: driver,
                             auth: auth, rateLimit: cfg.rateLimit)
    if cfg.rateLimit.enabled {
        log.info("Main", "rate limit on rate=\(cfg.rateLimit.ratePerSec)/s burst=\(cfg.rateLimit.burst)")
    } else {
        log.info("Main", "rate limit off (bypass)")
    }
    var cdpServer: FBCDPServer? = nil
    if cfg.cdpEnabled {
        cdpServer = FBCDPServer(port: cfg.cdpPort, manager: manager, driver: driver,
                                auth: auth, allowedOrigins: cfg.allowedOrigins)
    }

    bootstrapNSApp()
    do {
        try server.start()
    } catch {
        log.error("Main", "server start failed: \(error)")
        exit(1)
    }
    if let cdp = cdpServer {
        do {
            try cdp.start()
        } catch {
            log.error("Main", "CDP server start failed: \(error)")
            cdpServer = nil
        }
    }

    // R-5: start the idle-session reaper (default on). Closes sessions abandoned by a
    // disconnected client so a single client can't hold the quota cap forever.
    manager.startReaper()

    // P4-2: process-level RSS watchdog (OOM self-heal). Drain sessions or exit on breach.
    var memWatchdog: FBMemoryWatchdog? = nil
    if cfg.memoryWatchdog.enabled {
        let act = cfg.memoryWatchdog.action
        let drain: (Int) -> Void = { mb in
            log.error("Main", "memwatchdog breach \(mb)MB action=\(act)")
            switch FBMemoryWatchdogAction(rawValue: act) {
            case .exit:
                for sid in manager.listIds() { _ = manager.close(sessionId: sid) }
                log.error("Main", "memwatchdog: drained all sessions, exiting for supervisor restart")
                exit(0)
            case .closeSessions, nil:
                for sid in manager.listIds() {
                    log.warn("Main", "memwatchdog: closing session \(sid) to reclaim memory")
                    _ = manager.close(sessionId: sid)
                }
                FBMetrics.shared.increment("memwatchdog.sessions_drained")
            }
        }
        memWatchdog = FBMemoryWatchdog(config: cfg.memoryWatchdog, onBreach: drain)
        memWatchdog?.start()
    }

    log.info("Main", "engine ready; UDS at \(cfg.socketPath)\(cdpServer != nil ? " CDP at :\(cfg.cdpPort)" : "")")
    // Run forever.
    NSApplication.shared.run()
}

runEngine()
