import Foundation
import WebKit

// FR-04 / FR-08: session lifecycle + resource quota enforcement.
// FR-04: close() clears THIS session's nonPersistent dataStore, not global default.
// FR-08: max sessions + per-session memory budget. WebContent process count is bounded
// by the session cap (quota.maxSessions) + WebKit per-site isolation, not a shared pool
// (WKProcessPool deprecated macOS 12+, removed — B-2).

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
    // E-14: the per-cookie attrs injected at create (one entry per Keychain cookie this
    // session pulled + injected). The logout path deletes ONLY these (by domain|name|path),
    // not the whole domain, so session A's logout never clobbers session B's same-domain
    // cookies. Populated in SessionManager.create as each injectCookies succeeds.
    public var injectedCookieAttrs: [[String: String]] = []
    // B-5/E-34: the client connection that created this session. nil = system-owned
    // (CDP ensureSession, manager teardown, tests) — system-owned sessions are operable
    // by any caller. A non-nil owner restricts execute/close to that same owner id; a
    // mismatched caller gets `not_owner` at the UDS route. Set once at create, immutable.
    public let ownerId: String?
    // Issue #25: the creating connection's token hash (FBAuth.ownerKey) — the PRINCIPAL
    // behind ownerId. Used only for the read-only screenshot stream: a side panel dials
    // its own connection, so its connection UUID differs, but the same token identifies
    // the same application. Never widens create/execute/close (those stay UUID-scoped).
    public let ownerKey: String?
    // Issue #25: persistent profile identity. profileId is the caller's workflow-run
    // label; profileStoreId is the registry's WKWebsiteDataStore UUID. Both nil for the
    // default non-persistent path. storeDeletionPending marks a delete_profile that
    // arrived while this session was still live — close() removes the store instead.
    public let profileId: String?
    public let profileStoreId: UUID?
    public var storeDeletionPending: Bool = false
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
                webview: FBWebView, ownerId: String? = nil, ownerKey: String? = nil,
                profileId: String? = nil, profileStoreId: UUID? = nil) {
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
        self.ownerId = ownerId
        self.ownerKey = ownerKey
        self.profileId = profileId
        self.profileStoreId = profileStoreId
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
            // C-2 (1016 audit): teardown hops to main ASYNC. The old main.sync from a
            // background caller deadlocked when main was itself blocked on something that
            // needed the caller's queue (lock inversion) — e.g. the reaper closing an idle
            // session from the sessionmgr queue while main ran a queue.sync into it. The
            // local strong `wv` keeps destroy() safe after close() returns; the closingFlag
            // (set above, before the hop) still guards concurrent executes. On-main callers
            // keep the synchronous path (destroy must not outlive the run-loop tick there).
            if Thread.isMainThread {
                wv.destroy()
            } else {
                DispatchQueue.main.async { [wv] in wv.destroy() }
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
    // Issue #25: persistent-profile registry (profileId -> data-store uuid + owner hash).
    public let profiles: FBProfileRegistry
    // Issue #25: screenshot stream hub (nil = streaming disabled, e.g. unit tests).
    // The manager only signals session end + attaches it to each new webview; the UDS
    // route owns subscribe/unsubscribe and the driver owns per-action publishes.
    public let streamHub: FBStreamHub?
    // Issue #25: browser cookie-import source dirs (config-overridable for harnesses).
    public let cookieImport: FBCookieImportConfig

    public init(quota: FBResourceQuota, guards: FBSchedulingGuards, watchdog: FBWatchdogPolicy,
                creds: FBCredentialManager, auth: FBAuth, allowedOrigins: [String],
                sessionReaper: FBSessionReaperConfig = FBSessionReaperConfig(),
                profiles: FBProfileRegistry = FBProfileRegistry(),
                streamHub: FBStreamHub? = nil,
                cookieImport: FBCookieImportConfig = FBCookieImportConfig.default) {
        self.quota = quota
        self.guards = guards
        self.watchdog = watchdog
        self.creds = creds
        self.auth = auth
        self.allowedOrigins = allowedOrigins
        self.reaperConfig = sessionReaper
        self.profiles = profiles
        self.streamHub = streamHub
        self.cookieImport = cookieImport
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
    public func create(req: CreateSessionRequest, traceId: String?, ownerId: String? = nil,
                       ownerKey: String? = nil) -> FBResult<CreateSessionResponse> {
        // Issue #25: an explicit profileId opts into a persistent store. Resolve BEFORE
        // burning main-thread webview work; a cross-owner or unattributable request is
        // rejected here. nil profileId -> resolvedProfileStore stays nil (FR-04 path).
        var resolvedProfileStore: UUID? = nil
        if let pid = req.profileId, !pid.isEmpty {
            guard let key = ownerKey else {
                log.warn("SessionMgr", "profile create denied: no token owner identity")
                return .failure(.profileDenied)
            }
            switch profiles.resolve(profileId: pid, ownerTokenHash: key) {
            case .success(let storeIdStr):
                guard let uuid = UUID(uuidString: storeIdStr) else {
                    log.error("SessionMgr", "registry store id malformed for profileId=\(pid)")
                    return .failure(.internalError)
                }
                resolvedProfileStore = uuid
            case .failure(let e):
                return .failure(e)
            }
        }
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
            wvBox = FBWebView(mode: req.mode, sessionId: sid, profileStoreId: resolvedProfileStore)
        } else {
            DispatchQueue.main.sync {
                wvBox = FBWebView(mode: req.mode, sessionId: sid, profileStoreId: resolvedProfileStore)
            }
        }
        guard let wv = wvBox else { return .failure(.internalError) }
        // Issue #25: attach the stream hub so didFinish can push a frame to subscribed
        // panels. Weak on the webview side; the engine owns the hub for the process life.
        wv.streamHub = streamHub
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
        var injectedAttrs: [[String: String]] = []
        if let domain = req.credentialDomain, !domain.isEmpty {
            let (all, err) = creds.retrieveAll(domain: domain)
            if let e = err {
                log.warn("SessionMgr", "cred inject skip domain=\(domain) err=\(e.code)")
            } else if all.isEmpty {
                log.info("SessionMgr", "no cred for domain=\(domain)")
            } else {
                var okCount = 0
                for attrs in all {
                    if wv.injectCookies(attrs, domain: domain) {
                        okCount += 1
                        injectedAttrs.append(attrs)
                    }
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
                              credentialDomain: req.credentialDomain, webview: wv, ownerId: ownerId,
                              ownerKey: ownerKey, profileId: req.profileId,
                              profileStoreId: resolvedProfileStore)
            s.injectedCookieAttrs = injectedAttrs
            s.scheduler.reset()
            s.transition(to: .running)
            s.touch() // R-5: mark active at birth so the reaper doesn't close a freshly-created session before its first action.
            sessions[sid] = s
            // FR-06: WKWebView.load MUST run on main (calling it on the sessionmgr
            // background queue traps — observed exit 133 on create with initial_url).
            // Async: navigation completion is already async via WKNavigationDelegate.
            // E-40: a NEVER-loaded blank webview idles into ProcessThrottler suspension;
            // the first screenshot forces a render that races the suspend IPC and traps
            // (sendPrepareToSuspendIPC -> ProcessThrottlerActivity::deref -> SIGTRAP exit
            // 133, proven by crash report fusion-browser-*-112437.ips). The on-screen
            // headless host window keeps a NAVIGATED page visible (no suspend); a blank
            // page never paints, so WebContent suspends before any real load. Load a
            // minimal blank document at create so WebContent renders immediately and
            // never idles into suspend. Safe: data:about blank is the documented empty
            // session baseline; callers that then navigate replace it. Fire-and-forget
            // like the initial_url branch — no didFinish wait (create must not block).
            let navUrl = req.initialUrl ?? "data:text/html,<html></html>"
            let navMs = watchdog.navigateMs
            DispatchQueue.main.async {
                wv.navigate(url: navUrl, timeoutMs: navMs)
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
        // B-5/E-34: this system accessor SKIPS ownership (CDP ensureSession, tests, teardown).
        // UDS clients must use get(_:ownerId:) which enforces ownership.
        return queue.sync {
            guard let s = sessions[sid], !s.isClosing else { return nil }
            return s
        }
    }

    // B-5/E-34: owner-aware get for UDS clients. Returns .failure(.sessionNotFound) when the
    // session is absent/closing, .failure(.notOwner) when it exists but belongs to another
    // client, .success(session) when the caller owns it OR it is system-owned (ownerId nil).
    // A system-owned session (CDP-created, reaper-created) is operable by any caller — the
    // ownership model gates client-to-client isolation, not system-to-client.
    public func get(_ sid: String, ownerId: String?) -> FBResult<FBSession> {
        return queue.sync {
            guard let s = sessions[sid], !s.isClosing else { return .failure(.sessionNotFound) }
            // B-5/E-34: ownership gates client-to-client isolation. A SYSTEM caller
            // (ownerId nil — teardown, reaper, CDP ensureSession) bypasses the check and
            // may operate any session. Two non-nil callers must match. A client cannot
            // operate another client's session; the system always can.
            if let owner = s.ownerId, let caller = ownerId, owner != caller {
                log.warn("SessionMgr", "not_owner sid=\(sid) owner=\(owner) caller=\(caller)")
                return .failure(.notOwner)
            }
            return .success(s)
        }
    }

    public func close(sessionId sid: String, ownerId: String? = nil, logout: Bool = false) -> FBError? {
        // Extract the session under the lock, then tear down its webview on main
        // WITHOUT holding the queue lock (avoids main<->sessionmgr lock inversion).
        // B-5/E-34: owner-aware. A caller whose ownerId does not match the session's owner
        // (and the session is not system-owned) gets .notOwner — the session stays live.
        // ownerId nil (default) = system caller (teardown, reaper, CDP) — always allowed.
        let extracted: (FBSession?, FBError?) = queue.sync {
            guard let s = sessions.removeValue(forKey: sid) else { return (nil, .sessionNotFound) }
            // B-5/E-34: ownership gates client-to-client. System (ownerId nil — teardown,
            // reaper, CDP) bypasses and may close any session. Two non-nil callers must match.
            if let owner = s.ownerId, let caller = ownerId, owner != caller {
                // Ownership mismatch: put it back, deny. Never tear down another client's session.
                sessions[sid] = s
                log.warn("SessionMgr", "close not_owner sid=\(sid) owner=\(owner) caller=\(caller)")
                return (nil, .notOwner)
            }
            // L-15: clear the stable pin ONLY when the pinned session itself closes — a later
            // create re-pins on its next successful entry (firstSessionId == nil check).
            if firstSessionId == sid { firstSessionId = nil }
            return (s, nil)
        }
        guard let s = extracted.0 else { return extracted.1 }
        // D11: default retain Keychain; logout=true deletes.
        // F-12: logout revokes BOTH layers — Keychain (persistent) then the in-memory
        // cookie store (runtime) — BEFORE webview destroy, so the live session cannot
        // be re-authenticated from either layer. Order is Keychain-delete → clearCookies
        // → destroy, closing the delete/destroy TOCTOU window the audit flagged.
        // E-14: delete ONLY the cookies THIS session injected at create (by domain|name|path),
        // not the whole domain. Keychain is shared per-credentialDomain, so a domain may hold
        // cookies from several sessions (F-10 per-cookie keys); a bulk delete(domain:) would
        // clobber session B's same-domain cookies when session A logs out. injectedCookieAttrs
        // is captured in the create inject loop, so A's logout deletes only A's cookies. If the
        // list is empty (no inject, or pre-E-14 sessions) fall back to bulk delete for the
        // D11「彻底注销」 semantics — honest degradation, never silently leaves credentials.
        if logout, let domain = s.credentialDomain {
            if s.injectedCookieAttrs.isEmpty {
                log.warn("SessionMgr", "logout fallback bulk domain=\(domain) (no captured inject attrs)")
                creds.delete(domain: domain)
            } else {
                var removed = 0
                for attrs in s.injectedCookieAttrs {
                    if creds.delete(domain: domain, cookieAttrs: attrs) { removed += 1 }
                }
                log.info("SessionMgr", "logout per-cookie domain=\(domain) removed=\(removed)/\(s.injectedCookieAttrs.count)")
            }
        }
        if logout, let wv = s.webview { wv.clearCookies() }
        s.close()
        // Issue #25: terminal stream signal — subscribers get exactly one stream_end and
        // the hub drops the session's subscriptions (no frames after this point).
        streamHub?.end(sessionId: sid, reason: "session_closed")
        // Issue #25: a delete_profile that arrived while this session was live (or a
        // profile already gone from the registry) frees its WebKit store on the LAST
        // session's close. A plain close KEEPS the store — that is the point of profiles.
        if let pid = s.profileId, let uuid = s.profileStoreId {
            let othersLive = queue.sync { sessions.values.contains { $0.profileStoreId == uuid } }
            let profileGone = profiles.entry(profileId: pid) == nil || s.storeDeletionPending
            if profileGone && !othersLive {
                DispatchQueue.main.async {
                    WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in }
                }
                log.info("SessionMgr", "profile store removed profileId=\(pid) store=\(uuid)")
            }
        }
        log.info("SessionMgr", "closed \(sid) logout=\(logout)")
        return nil
    }

    public func count() -> Int { return queue.sync { sessions.count } }

    // H-9: live capacity snapshot for THIS node — the scheduler-placement input. Reads
    // the live session count under the queue lock (consistent with count()), then builds
    // FBNodeCapacity from the configured quota. Exposed via the UDS `{type:"capacity"}`
    // request (gated behind .metrics cap in UDSServer). nodeId is minted once per process
    // (FBNodeCapacity.processNodeId), freeMemoryMB probed live each call.
    public func capacity() -> FBNodeCapacity {
        let live = queue.sync { sessions.count }
        return FBNodeCapacity.current(quota: quota, liveSessions: live)
    }

    public func listIds() -> [String] { return queue.sync { Array(sessions.keys) } }

    // Issue #25: free a deleted profile's WebKit store when NO live session holds it.
    // Called after delete_profile removed the registry entry: a later close would keep
    // the store (its session's profileId lookup now misses, but the store UUID must be
    // removed explicitly or the on-disk login data leaks until the next delete).
    public func purgeProfileStore(uuid: UUID) {
        let live = queue.sync { sessions.values.contains { $0.profileStoreId == uuid } }
        guard !live else {
            log.info("SessionMgr", "profile store purge deferred (live session) store=\(uuid)")
            return
        }
        DispatchQueue.main.async {
            WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in }
        }
        log.info("SessionMgr", "profile store purged store=\(uuid)")
    }

    // Issue #25: delete_profile arrived while sessions still hold the profile's store.
    // Mark them so each session's close frees the store even if the profileId is
    // re-created (with a NEW store UUID) before the old session closes.
    public func markProfileDeleted(profileId: String) {
        let marked = queue.sync { () -> Int in
            let live = sessions.values.filter { $0.profileId == profileId }
            live.forEach { $0.storeDeletionPending = true }
            return live.count
        }
        log.info("SessionMgr", "profile delete marked live=\(marked) profileId=\(profileId)")
    }

    // T2.3: CDP shim maps its single synthetic target to the first live session.
    // L-15: prefer the STABLE pinned firstSessionId (set on first create, cleared on that
    // session's close). Dictionary.values.first order is nondeterministic; the pin keeps the
    // CDP target bound to one session across calls instead of silently hopping. Falls back to
    // a live-values scan only if the pin is unset/invalid (e.g. pinned one closed and no new
    // create has re-pinned yet) so CDP still finds SOME live session.
    public func firstSession() -> FBSession? {
        return queue.sync {
            // M-9 (1016 audit): a mid-close session (isClosing=true, state still not
            // terminal) was handed to CDP ensureSession — events/derefs then raced the
            // teardown. Skip closing sessions in BOTH lookups.
            if let pid = firstSessionId, let s = sessions[pid],
               s.state != .closed && s.state != .permanentFail && !s.isClosing {
                return s
            }
            return sessions.values.first(where: {
                $0.state != .closed && $0.state != .permanentFail && !$0.isClosing
            })
        }
    }
}
