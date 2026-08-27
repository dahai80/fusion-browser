import Foundation
import AppKit

// fusion-browser engine entry point. Wires config -> infra -> server.
// Phase 1: UDS server only. CDP :9222 default off (FR-07/NFR-S3).

let log = FBLogger.shared

func loadConfig() -> FBEngineConfig {
    // Config file at ~/.fusion-browser/config.json optional; else default.
    let home = NSHomeDirectory()
    let path = "\(home)/.fusion-browser/config.json"
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
        do {
            let cfg = try JSONDecoder().decode(FBEngineConfig.self, from: data)
            log.info("Main", "config loaded from \(path)")
            return cfg
        } catch {
            log.warn("Main", "config parse failed at \(path): \(error); using defaults")
        }
    } else {
        log.info("Main", "no config file, using defaults")
    }
    return FBEngineConfig.default
}

func bootstrapNSApp() {
    // WKWebView needs an NSApplication + run loop. Headless still requires app context.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
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
    if FBCoreBridge.isAvailable {
        let v = FBCoreBridge.version()
        log.info("Main", "rust core available version=0x\(String(v, radix: 16)) useRustCore=\(cfg.useRustCore)")
    } else {
        log.info("Main", "rust core not available (Swift path)")
    }

    let auth = FBAuth(token: cfg.authToken)
    let creds = FBCredentialManager()
    let extractor = FBAXTreeExtractor(useRustCore: cfg.useRustCore)
    let sanitizer = FBSanitizer()
    let watchdog = cfg.watchdog.policy()
    let manager = FBSessionManager(quota: cfg.quota, guards: cfg.guards, watchdog: watchdog,
                                    creds: creds, auth: auth, allowedOrigins: cfg.allowedOrigins)
    let visualLocator = FBVisualLocator(config: cfg.visualLocator)
    if cfg.visualLocator.enabled {
        log.info("Main", "visual locator on model=\(cfg.visualLocator.model) endpoint=\(cfg.visualLocator.endpoint)")
    }
    let driver = FBActionDriver(watchdog: watchdog, auth: auth, allowedOrigins: cfg.allowedOrigins,
                                extractor: extractor, sanitizer: sanitizer, visualLocator: visualLocator)
    let server = FBUDSServer(socketPath: cfg.socketPath, manager: manager, driver: driver, auth: auth)
    var cdpServer: FBCDPServer? = nil
    if cfg.cdpEnabled {
        cdpServer = FBCDPServer(port: cfg.cdpPort, manager: manager, driver: driver,
                                extractor: extractor, auth: auth, allowedOrigins: cfg.allowedOrigins)
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
