import Foundation

// FR-04 / FR-08: session lifecycle + resource quota enforcement.
// FR-04: close() clears THIS session's nonPersistent dataStore, not global default.
// FR-08: max sessions, per-session memory budget, shared WKProcessPool.

public final class FBSession {
    public let id: String
    public let mode: WebMode
    public let createdAt: Double
    public var state: FBSessionState
    public let scheduler: FBScheduler
    public let credentialDomain: String?
    public var credentialInjected: Bool
    private(set) var webview: FBWebView?
    private let log = FBLogger.shared

    public init(id: String, mode: WebMode, guards: FBSchedulingGuards, credentialDomain: String?, webview: FBWebView) {
        self.id = id
        self.mode = mode
        self.createdAt = Date().timeIntervalSince1970
        self.state = .created
        self.scheduler = FBScheduler(guards: guards)
        self.credentialDomain = credentialDomain
        self.credentialInjected = false
        self.webview = webview
    }

    public func transition(to next: FBSessionState) {
        log.debug("Session", "\(id) \(state) -> \(next)")
        state = next
    }

    // FR-04: close clears session-owned dataStore only.
    // AppKit teardown (stopLoading/removeFromSuperview/hostWindow.close) MUST run on
    // main — calling it on the sessionmgr background queue traps (exit 133 on close).
    public func close() {
        let wv = webview
        webview = nil
        if let wv = wv {
            if Thread.isMainThread {
                wv.destroy()
            } else {
                DispatchQueue.main.sync { wv.destroy() }
            }
        }
        scheduler.reset()
        transition(to: .closed)
        FBMetrics.shared.increment("session.closed")
    }
}

public final class FBSessionManager {
    private let quota: FBResourceQuota
    private let guards: FBSchedulingGuards
    private let watchdog: FBWatchdogPolicy
    private let creds: FBCredentialManager
    private let auth: FBAuth
    private let allowedOrigins: [String]
    private let queue = DispatchQueue(label: "fusion-browser.sessionmgr")
    private var sessions: [String: FBSession] = [:]
    private let log = FBLogger.shared
    // Shared WKProcessPool limits WebContent process count (FR-08).
    public static let sharedProcessPoolIdentifier = "com.fusion.browser.processpool"

    public init(quota: FBResourceQuota, guards: FBSchedulingGuards, watchdog: FBWatchdogPolicy,
                creds: FBCredentialManager, auth: FBAuth, allowedOrigins: [String]) {
        self.quota = quota
        self.guards = guards
        self.watchdog = watchdog
        self.creds = creds
        self.auth = auth
        self.allowedOrigins = allowedOrigins
    }

    // FR-08: enforce max sessions + total memory. Returns quota_exceeded if over cap.
    // T3.2: quota checked BEFORE WKWebView creation (don't burn main-thread alloc on reject).
    public func create(req: CreateSessionRequest, traceId: String?) -> FBResult<CreateSessionResponse> {
        // Pre-check quota under lock to avoid creating a WKWebView we'll immediately destroy.
        let admit: Bool = queue.sync {
            if sessions.count >= quota.maxSessions {
                log.warn("SessionMgr", "quota exceeded sessions: \(sessions.count)/\(quota.maxSessions)")
                return false
            }
            // FR-08 total memory budget: sum of live per-session budgets must not exceed cap.
            let projected = (sessions.count + 1) * quota.maxMemoryPerSessionMB
            if projected > quota.maxTotalMemoryMB {
                log.warn("SessionMgr", "quota exceeded memory: \(projected)/\(quota.maxTotalMemoryMB)")
                return false
            }
            return true
        }
        if !admit {
            FBMetrics.shared.increment("session.quota_exceeded")
            return .failure(.quotaExceeded)
        }
        // WKWebView/NSWindow MUST be created on main thread (AppKit). Block here on a
        // semaphore so the sync contract holds; main-thread dispatch is near-instant.
        var wvBox: FBWebView? = nil
        let sid = FBTrace.newId()
        if Thread.isMainThread {
            wvBox = FBWebView(mode: req.mode, sessionId: sid)
        } else {
            DispatchQueue.main.sync {
                wvBox = FBWebView(mode: req.mode, sessionId: sid)
            }
        }
        guard let wv = wvBox else { return .failure(.internalError) }
        return queue.sync {
            // Re-check under lock (race: another creator may have slipped in).
            if sessions.count >= quota.maxSessions {
                log.warn("SessionMgr", "quota exceeded (race) sessions: \(sessions.count)/\(quota.maxSessions)")
                wv.destroy()
                FBMetrics.shared.increment("session.quota_exceeded")
                return .failure(.quotaExceeded)
            }
            // FR-05: inject credential if domain provided.
            var injected = false
            if let domain = req.credentialDomain, !domain.isEmpty {
                switch creds.retrieve(domain: domain) {
                case (_, .some(let e)):
                    log.warn("SessionMgr", "cred inject skip domain=\(domain) err=\(e.code)")
                case (let attrs?, nil):
                    wv.injectCookies(attrs, domain: domain)
                    injected = true
                    log.info("SessionMgr", "cred injected domain=\(domain)")
                case (nil, nil):
                    log.info("SessionMgr", "no cred for domain=\(domain)")
                }
            }
            let s = FBSession(id: sid, mode: req.mode, guards: guards,
                              credentialDomain: req.credentialDomain, webview: wv)
            s.scheduler.reset()
            s.transition(to: .running)
            sessions[sid] = s
            // FR-06: WKWebView.load MUST run on main (calling it on the sessionmgr
            // background queue traps — observed exit 133 on create with initial_url).
            // Async: navigation completion is already async via WKNavigationDelegate.
            if let url = req.initialUrl {
                let navMs = watchdog.navigateMs
                DispatchQueue.main.async {
                    wv.navigate(url: url, timeoutMs: navMs)
                }
            }
            FBMetrics.shared.increment("session.created")
            log.info("SessionMgr", "created \(sid) mode=\(req.mode) cred=\(injected)", traceId: traceId)
            return .success(CreateSessionResponse(sessionId: sid, credentialInjected: injected))
        }
    }

    public func get(_ sid: String) -> FBSession? {
        return queue.sync { sessions[sid] }
    }

    public func close(sessionId sid: String, logout: Bool = false) -> FBError? {
        // Extract the session under the lock, then tear down its webview on main
        // WITHOUT holding the queue lock (avoids main<->sessionmgr lock inversion).
        let s: FBSession? = queue.sync {
            guard let s = sessions.removeValue(forKey: sid) else { return nil }
            return s
        }
        guard let s = s else { return .sessionNotFound }
        // D11: default retain Keychain; logout=true deletes.
        if logout, let domain = s.credentialDomain { creds.delete(domain: domain) }
        s.close()
        log.info("SessionMgr", "closed \(sid) logout=\(logout)")
        return nil
    }

    public func count() -> Int { return queue.sync { sessions.count } }

    public func listIds() -> [String] { return queue.sync { Array(sessions.keys) } }

    // T2.3: CDP shim maps its single synthetic target to the first live session.
    public func firstSession() -> FBSession? {
        return queue.sync { sessions.values.first(where: { $0.state != .closed && $0.state != .permanentFail }) }
    }
}
