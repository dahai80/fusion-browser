import Foundation

// FR-04 / FR-08: session lifecycle + resource quota enforcement.
// FR-04: close() clears THIS session's nonPersistent dataStore, not global default.
// FR-08: max sessions, per-session memory budget, shared WKProcessPool.

public final class FBSession {
    public let id: String
    public let mode: WebMode
    public let createdAt: Double
    // L-14: state read/writes raced. transition(to:) ran off the manager queue
    // (ActionDriver.handleCrash watchdog block, FBSession.close after close), while
    // firstSession() read $0.state under queue.sync — a torn read let firstSession()
    // return a session mid-close or skip a live one (CDP/audit nondeterminism). Guard
    // the backing field with a per-session NSLock so every read (including firstSession)
    // and every write (transition) is atomic regardless of which thread/queue issues it.
    private let stateLock = NSLock()
    private var currentState: FBSessionState
    public var state: FBSessionState {
        stateLock.lock(); let v = currentState; stateLock.unlock(); return v
    }
    public let scheduler: FBScheduler
    public let credentialDomain: String?
    public var credentialInjected: Bool
    // E-21: `webview` was a plain `private(set) var` read by ActionDriver/CDP on one
    // thread (client queue / global watchdog) and nil'd by close() on another (client
    // queue or memwatchdog queue) with zero synchronization -> Swift memory-model UB
    // (Swift 6 strict concurrency: compile error). Back it with a per-session NSLock so
    // every read (execute, extractAXTree, clearCookies-on-logout) and the single nil write
    // (close) are atomic. The getter returns the current ref under the lock; callers
    // capture it into a local strong `wv` and operate on THAT (a close racing after the
    // capture nils the backing field but cannot revoke the local ref — see E-22 barrier).
    private let webviewLock = NSLock()
    private var webviewField: FBWebView?
    public var webview: FBWebView? {
        webviewLock.lock(); let v = webviewField; webviewLock.unlock(); return v
    }
    // E-22: atomic is-closing flag. Set under webviewLock BEFORE teardown begins (close()
    // is called concurrently with an in-flight execute that already captured `wv`). The
    // execute path + manager.get re-check this so a new action on a closing session fails
    // fast (sessionClosing) instead of touching a WKWebView mid-destroy. Stays true for
    // the session's remaining lifetime (close is terminal).
    public var isClosing: Bool {
        webviewLock.lock(); let v = closingFlag; webviewLock.unlock(); return v
    }
    private var closingFlag: Bool = false
    private let log = FBLogger.shared
    // R-5: last-activity timestamp for the idle reaper. A client that creates sessions and
    // disconnects left them live forever (quota DoS — one client burns the whole session cap
    // by opening N sessions and walking away). Updated on create + every executed action;
    // FBSessionManager.reaper closes sessions idle past sessionReaper.idleTimeoutMs.
    // Lock-guarded: written on the ActionDriver watchdog thread + reaper thread, read by the
    // reaper. Date init via the explicit epoch form (this process only; no wall-clock drift
    // matters here — relative deltas against the same timebase).
    private let activityLock = NSLock()
    private var lastActivityTs: Double
    public var lastActivity: Double {
        activityLock.lock(); let v = lastActivityTs; activityLock.unlock(); return v
    }
    public func touch() {
        activityLock.lock(); lastActivityTs = Date().timeIntervalSince1970; activityLock.unlock()
    }
    // H-1: per-session AXTree extractor + stable mapping isolation. Previously a single
    // shared FBAXTreeExtractor (main.swift) backed every session, so FBStableMapping.install
    // did mappings.removeAll() — session B's extract WIPED session A's node map mid-action
    // (cross-session click/type node_stale), and F-13's credential screenshot guard (which
    // reads mapping.role) was defeated for any session whose map another extract cleared.
    // Each session owns its own extractor -> install only wipes THIS session's map. R-14.
    public let extractor: FBAXTreeExtractor

    public init(id: String, mode: WebMode, guards: FBSchedulingGuards, credentialDomain: String?,
                webview: FBWebView) {
        self.id = id
        self.mode = mode
        self.createdAt = Date().timeIntervalSince1970
        self.currentState = .created
        self.scheduler = FBScheduler(guards: guards)
        self.credentialDomain = credentialDomain
        self.credentialInjected = false
        self.webviewField = webview
        self.lastActivityTs = self.createdAt
        self.extractor = FBAXTreeExtractor()
    }

    public func transition(to next: FBSessionState) {
        stateLock.lock()
        let prev = currentState
        currentState = next
        stateLock.unlock()
        log.debug("Session", "\(id) \(prev) -> \(next)")
    }

    // FR-04: close clears session-owned dataStore only.
    // AppKit teardown (stopLoading/removeFromSuperview/hostWindow.close) MUST run on
    // main — calling it on the sessionmgr background queue traps (exit 133 on close).
    // E-22: set the is-closing flag + nil the webview field atomically BEFORE the main-hop
    // teardown, so a concurrent execute that captured `wv` sees isClosing=true on re-check
    // and any NEW execute (re-reading the field) sees nil -> fast-fail. The local `wv`
    // captured here still has a strong ref so destroy() is safe; a concurrent in-flight
    // eval on the same FBWebView serializes its completion on main against stopLoading
    // (both dispatch to main), so no UAF — the eval completes (or the watchdog times out).
    public func close() {
        webviewLock.lock()
        if closingFlag {
            // Idempotent: a second close() (reaper + explicit, double-client) is a no-op.
            webviewLock.unlock()
            log.debug("Session", "\(id) close() re-entered; already closing")
            return
        }
        closingFlag = true
        let wv = webviewField
        webviewField = nil
        webviewLock.unlock()
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
    // L-15: stable pin for the first live session (CDP single-target binding). Nondeterministic
    // dict order made firstSession() return a different session after the bound one closed.
    private var firstSessionId: String? = nil
    private let log = FBLogger.shared
    // R-5: idle-session reaper timer. Closes sessions whose lastActivity is older than
    // idleTimeoutMs so a disconnected client's abandoned sessions can't hold the quota cap
    // forever (quota DoS). Started in startReaper; cancelled in stopReaper (called on
    // engine teardown / memwatchdog exit). The tick scans sessions under the queue lock,
    // collects idle ids, then closes each OUTSIDE the lock (close does a main-hop).
    private var reaperTimer: DispatchSourceTimer?
    private let reaperConfig: FBSessionReaperConfig
    // Shared WKProcessPool limits WebContent process count (FR-08).
    public static let sharedProcessPoolIdentifier = "com.fusion.browser.processpool"

    public init(quota: FBResourceQuota, guards: FBSchedulingGuards, watchdog: FBWatchdogPolicy,
                creds: FBCredentialManager, auth: FBAuth, allowedOrigins: [String],
                sessionReaper: FBSessionReaperConfig = FBSessionReaperConfig()) {
        self.quota = quota
        self.guards = guards
        self.watchdog = watchdog
        self.creds = creds
        self.auth = auth
        self.allowedOrigins = allowedOrigins
        self.reaperConfig = sessionReaper
    }

    // R-5: start the idle reaper. No-op if disabled. Idempotent (guard against double-start).
    public func startReaper() {
        guard reaperConfig.enabled else {
            log.info("SessionMgr", "reaper disabled")
            return
        }
        guard reaperTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.scheduleRepeating(deadline: .now() + .milliseconds(reaperConfig.checkIntervalMs),
                            interval: .milliseconds(reaperConfig.checkIntervalMs))
        t.setEventHandler { [weak self] in self?.reapIdle() }
        t.resume()
        reaperTimer = t
        log.info("SessionMgr", "reaper started idleMs=\(reaperConfig.idleTimeoutMs) intervalMs=\(reaperConfig.checkIntervalMs)")
    }

    public func stopReaper() {
        reaperTimer?.cancel()
        reaperTimer = nil
    }

    // R-5: close sessions idle past idleTimeoutMs. The timer fires ON the sessionmgr queue,
    // so we CANNOT call close(sessionId:) (it does queue.sync -> self-deadlock on a serial
    // queue). Inline the extraction under the lock, release, then tear down each webview
    // on main outside the lock — the same shape close(sessionId:) uses, minus the queue.sync.
    private func reapIdle() {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Double(reaperConfig.idleTimeoutMs) / 1000.0
        var reaped: [FBSession] = []
        // We are already on `queue` (timer source target). Mutate the dict inline — NO
        // queue.sync (recursive sync on a serial queue deadlocks).
        for (sid, s) in sessions {
            if s.lastActivity < cutoff {
                sessions.removeValue(forKey: sid)
                if firstSessionId == sid { firstSessionId = nil }
                reaped.append(s)
                log.warn("SessionMgr", "reaper closing idle \(sid) idleMs=\(Int((now - s.lastActivity) * 1000))")
            }
        }
        if reaped.isEmpty { return }
        FBMetrics.shared.increment("session.reaped", by: reaped.count)
        // Teardown off the lock. s.close() hops to main for AppKit destroy. No logout
        // (reaper is a resource guard, not a credential revocation — logout is explicit).
        for s in reaped { s.close() }
    }

    // R-5: mark a session active. Called from ActionDriver.execute before dispatch so the
    // reaper doesn't close a session mid-action. No-op on unknown/missing id.
    public func touch(sessionId sid: String) {
        queue.sync {
            sessions[sid]?.touch()
        }
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
        // E-36: credential retrieval (Keychain IPC) + cookie injection (httpCookieStore) MUST
        // run OUTSIDE the sessionmgr queue lock. The old code did both inside queue.sync; the
        // cookie store's setCookie completion can touch main, and Keychain IPC can block —
        // holding the sessionmgr lock across either inverts against memwatchdog's drain path
        // (manager.close -> queue.sync -> main), an AB-BA deadlock. The webview already exists
        // (built on main above), so inject here, lock-free, BEFORE the recheck. On a race-loser
        // reject the injected cookies die with the doomed webview (in-memory store) — harmless.
        // F-10: a domain may have multiple cookies (per-cookie Keychain keys); inject all.
        // F-11: injected reflects the truthful per-cookie result (was unconditionally true).
        var injected = false
        if let domain = req.credentialDomain, !domain.isEmpty {
            let (all, err) = creds.retrieveAll(domain: domain)
            if let e = err {
                log.warn("SessionMgr", "cred inject skip domain=\(domain) err=\(e.code)")
            } else if all.isEmpty {
                log.info("SessionMgr", "no cred for domain=\(domain)")
            } else {
                var okCount = 0
                for attrs in all {
                    if wv.injectCookies(attrs, domain: domain) { okCount += 1 }
                }
                injected = okCount > 0
                log.info("SessionMgr", "cred injected domain=\(domain) ok=\(okCount)/\(all.count)")
            }
        }
        // F-14: if the recheck below rejects (race-loser), we must destroy() the freshly-built
        // webview on MAIN (AppKit), but queue.sync runs inline on this (non-main) caller thread.
        // Capture the doomed webview inside the locked block, then destroy on main AFTER the
        // queue.sync returns and the lock is released — mirroring manager.close's pattern.
        var doomedWebview: FBWebView? = nil
        let result: FBResult<CreateSessionResponse> = queue.sync {
            // Re-check under lock (race: another creator may have slipped in).
            // L-16: re-verify BOTH the session-count cap AND the projected memory budget —
            // the old recheck only checked sessions.count, so when maxTotalMemoryMB is
            // tighter than maxSessions*maxMemoryPerSessionMB, N concurrent creators all
            // passed precheck, all built a webview, all passed the count-only recheck, and
            // landed N sessions whose total memory exceeds maxTotalMemoryMB (TOCTOU bypass).
            let projectedMem = (sessions.count + 1) * quota.maxMemoryPerSessionMB
            if sessions.count >= quota.maxSessions || projectedMem > quota.maxTotalMemoryMB {
                log.warn("SessionMgr", "quota exceeded (race) sessions: \(sessions.count)/\(quota.maxSessions) mem: \(projectedMem)/\(quota.maxTotalMemoryMB)")
                // F-14: do NOT destroy() the webview inside this queue.sync block. queue.sync
                // runs inline on the caller thread (UDS background handler, NOT main), and
                // destroy() does AppKit ops (stopLoading/removeFromSuperview/hostWindow.close)
                // that the codebase documents as main-thread-only — calling them off-main
                // traps (exit 133/SIGTRAP), the exact constraint FBSession.close() honors via
                // a main hop. Extract the doomed webview here under the lock, release the lock
                // by returning, then destroy on main below — mirroring manager.close's pattern.
                doomedWebview = wv
                FBMetrics.shared.increment("session.quota_exceeded")
                return .failure(.quotaExceeded)
            }
            let s = FBSession(id: sid, mode: req.mode, guards: guards,
                              credentialDomain: req.credentialDomain, webview: wv)
            s.scheduler.reset()
            s.transition(to: .running)
            s.touch() // R-5: mark active at birth so the reaper doesn't close a freshly-created session before its first action.
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
            // L-15: pin a STABLE first-session id. firstSession() used sessions.values.first
            // whose order is nondeterministic; if the bound session closed mid-operation,
            // the next call returned a DIFFERENT live session and CDP silently routed the
            // client's subsequent Runtime.evaluate/Page.navigate into a session it never
            // discovered. Track the first id explicitly: set on the first successful create,
            // cleared only when that specific session closes. A later create does NOT steal
            // the pin while the pinned one is live.
            if firstSessionId == nil { firstSessionId = sid }
            log.info("SessionMgr", "created \(sid) mode=\(req.mode) cred=\(injected)", traceId: traceId)
            return .success(CreateSessionResponse(sessionId: sid, credentialInjected: injected))
        }
        // F-14: race-loser — destroy the freshly-built webview on MAIN (AppKit), after the
        // queue.sync released the lock. Same main-hop FBSession.close() uses; never destroy
        // off-main (exit 133). On main it is synchronous; off-main we main.sync (caller is a
        // UDS background thread, never main, so no self-deadlock).
        if let doomed = doomedWebview {
            if Thread.isMainThread {
                doomed.destroy()
            } else {
                DispatchQueue.main.sync { doomed.destroy() }
            }
            log.warn("SessionMgr", "race-loser webview destroyed on main")
        }
        return result
    }

    public func get(_ sid: String) -> FBSession? {
        // E-22: never hand out a session already mid-close. close(sessionId:) removes the
        // session from the dict before setting isClosing, so under normal flow the dict
        // lookup misses first. The isClosing re-check is a belt-and-suspenders guard for the
        // window where a reaper/teardown path nil'd the webview but has not yet removed the
        // dict entry — and the authoritative gate is the execute-entry re-check (a caller
        // that captured the session just before close flipped the flag).
        return queue.sync {
            guard let s = sessions[sid], !s.isClosing else { return nil }
            return s
        }
    }

    public func close(sessionId sid: String, logout: Bool = false) -> FBError? {
        // Extract the session under the lock, then tear down its webview on main
        // WITHOUT holding the queue lock (avoids main<->sessionmgr lock inversion).
        let s: FBSession? = queue.sync {
            guard let s = sessions.removeValue(forKey: sid) else { return nil }
            // L-15: clear the stable pin ONLY when the pinned session itself closes — a later
            // create re-pins on its next successful entry (firstSessionId == nil check).
            if firstSessionId == sid { firstSessionId = nil }
            return s
        }
        guard let s = s else { return .sessionNotFound }
        // D11: default retain Keychain; logout=true deletes.
        // F-12: logout revokes BOTH layers — Keychain (persistent) then the in-memory
        // cookie store (runtime) — BEFORE webview destroy, so the live session cannot
        // be re-authenticated from either layer. Order is Keychain-delete → clearCookies
        // → destroy, closing the delete/destroy TOCTOU window the audit flagged.
        if logout, let domain = s.credentialDomain { creds.delete(domain: domain) }
        if logout, let wv = s.webview { wv.clearCookies() }
        s.close()
        log.info("SessionMgr", "closed \(sid) logout=\(logout)")
        return nil
    }

    public func count() -> Int { return queue.sync { sessions.count } }

    public func listIds() -> [String] { return queue.sync { Array(sessions.keys) } }

    // T2.3: CDP shim maps its single synthetic target to the first live session.
    // L-15: prefer the STABLE pinned firstSessionId (set on first create, cleared on that
    // session's close). Dictionary.values.first order is nondeterministic; the pin keeps the
    // CDP target bound to one session across calls instead of silently hopping. Falls back to
    // a live-values scan only if the pin is unset/invalid (e.g. pinned one closed and no new
    // create has re-pinned yet) so CDP still finds SOME live session.
    public func firstSession() -> FBSession? {
        return queue.sync {
            if let pid = firstSessionId, let s = sessions[pid],
               s.state != .closed && s.state != .permanentFail {
                return s
            }
            return sessions.values.first(where: { $0.state != .closed && $0.state != .permanentFail })
        }
    }
}
