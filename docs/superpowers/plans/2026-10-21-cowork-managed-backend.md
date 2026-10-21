# Cowork Managed-Browser Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** fusion-browser becomes the managed-browser backend for fusion-cowork: persistent per-run profiles, cookie import from Chrome/Edge/Firefox, and a pushed screenshot stream (issue #25).

**Architecture:** Additive wire types on the existing length-prefixed UDS server. Three new engine surfaces — `FBProfileRegistry` (profileId -> WKWebsiteDataStore(forIdentifier:), owner = auth-token hash), `FBBrowserCookieImporter` (SQLite readers + Chromium AES decrypt), `FBStreamHub` (per-session subscriber push with throttle). Hooks: `FBActionDriver.execute` end + `WKNavigationDelegate.didFinish`. Python client gains profile ops + a dedicated-socket stream class.

**Tech Stack:** Swift 6 / macOS 14+, WebKit (`WKWebsiteDataStore(forIdentifier:)`), system `SQLite3` + `CommonCrypto`, XCTest, Python client (pure socket).

**Spec:** `docs/superpowers/specs/2026-10-21-cowork-managed-backend-design.md`

## Global Constraints

- macOS 14+ (project floor); no new SPM dependencies (system SQLite3/CommonCrypto only).
- 4-space indentation multiples, no docstrings, always log; wire keys snake_case via existing `.convertToSnakeCase`.
- Arch-3: NO live WKWebView assertions in `swift test` (main-run-loop deadlock); live paths verified by release binary + `scripts/` harnesses only.
- Any `create` without `profileId` must behave byte-identically to today (FR-04 non-persistence default).
- New privileged surfaces are NOT in `FBCapabilities.default`; existing rawValues never change.
- E-39: never log cookie names/values. E-40: blank-document load on create stays.
- Only this repo is modified; cowork-side code lands via an issue filed in this task sequence.

## Review Focus

- A `profileId` created by token A, then used by token B: expect `profile_denied`, never a shared login state.
- A wrong-token auth frame: expect the `auth_denied` error frame then close (already pinned in `UDSConcurrencyTests`).
- A v20 Chrome cookie blob: expect `skippedAppBound` count increment, `imported` unaffected, no crash.
- A non-subscribed client issuing execute while another connection streams: expect its responses never carry an extra frame.
- A session close while a stream is active: expect exactly one `stream_end` frame, then the iterator stops.

---

### Task 1: Capabilities

**Files:**
- Modify: `Sources/FusionBrowser/Auth.swift:8-86`
- Test: `Tests/FusionBrowserTests/InfraTests.swift` (append to `AuthTests`)

**Interfaces:**
- Consumes: existing `FBCapabilities` OptionSet.
- Produces: `FBCapabilities.importCookies` (1<<8), `FBCapabilities.persistentProfiles` (1<<9); `parseCaps` accepts `"importcookies"` / `"persistentprofiles"` (case-insensitive); both in `.all`, neither in `.default`; `FBAuth.ownerKey(token: String?) -> String?` returns the SHA256 hex of the token when the token authenticates, else nil.

- [ ] Step 1: Write failing tests in `InfraTests.swift`: `testNewCapsNotDefault`, `testNewCapsInAll`, `testParseCapsNewNames`, `testOwnerKeyMatchesAuthenticate`, `testOwnerKeyFailClosed`.
- [ ] Step 2: `swift test --disable-sandbox --filter AuthTests` -> FAIL (no such members).
- [ ] Step 3: Add the two bits + parseCaps cases + `ownerKey(token:)` (reuse constant-time hash compare; return nil on no-token/mismatch/empty).
- [ ] Step 4: `swift test --disable-sandbox --filter AuthTests` -> PASS.
- [ ] Step 5: Commit `feat: capabilities for persistent profiles and cookie import`.

### Task 2: Wire schema

**Files:**
- Modify: `Sources/FusionBrowser/Protocol.swift`
- Test: `Tests/FusionBrowserTests/ProtocolTests.swift` (append)

**Interfaces:**
- Consumes: Task 1 (none at compile time).
- Produces (exact):
  - `CreateSessionRequest.profileId: String?` (new optional init param, default nil).
  - `struct ImportCookiesRequest: Codable { sessionId: String; browser: String; profile: String? }`
  - `struct StreamScreenshotsRequest: Codable { sessionId: String; enabled: Bool }`
  - `struct DeleteProfileRequest: Codable { profileId: String }`
  - `struct ImportCookiesResponse: Codable { sessionId: String; browser: String; imported: Int; skippedAppBound: Int; skippedOther: Int }`
  - `struct StreamAckResponse: Codable { sessionId: String; active: Bool }`
  - `struct ProfileDeletedResponse: Codable { profileId: String; deleted: Bool }`
  - `FBRequest` cases `.importCookies`, `.streamScreenshots`, `.deleteProfile`; ReqType strings `import_cookies`, `stream_screenshots`, `delete_profile` (all with a `payload` object).
  - `FBResponse` cases `.importCookies`, `.streamAck`, `.profileDeleted`; RespType strings `import_cookies`, `stream_ack`, `profile_deleted`.
  - Push events (NOT FBResponse): `struct ScreenshotFrameEvent: Codable { var type: String = "screenshot_frame"; sessionId: String; seq: Int; png: Data; url: String; title: String; tsMs: Int }`, `struct StreamEndEvent: Codable { var type: String = "stream_end"; sessionId: String; reason: String }`.
- [ ] Step 1: Failing roundtrip tests: each new request/response encodes/decodes through `FBFrame`; `ScreenshotFrameEvent` encodes `type` as `screenshot_frame` and `png` base64; an unknown `type` still throws on decode of `FBRequest`.
- [ ] Step 2: `swift test --filter Protocol` -> FAIL.
- [ ] Step 3: Add types/cases (ReqType/RespType string tables updated).
- [ ] Step 4: PASS.
- [ ] Step 5: Commit `feat: wire schema for profiles, cookie import, screenshot stream`.

### Task 3: Profile registry

**Files:**
- Create: `Sources/FusionBrowser/ProfileRegistry.swift`
- Modify: `Sources/FusionBrowser/ErrorModel.swift` (add code `profile_denied`)
- Test: `Tests/FusionBrowserTests/ProfileRegistryTests.swift` (create)

**Interfaces:**
- Produces:
  - `public final class FBProfileRegistry`
  - `init(path: String = FBProfileRegistry.defaultPath)`; `static let defaultPath = "~/.fusion-browser/profiles.json"` expanded.
  - `public func resolve(profileId: String, ownerTokenHash: String) -> FBResult<String>` — creates a new entry (`storeId` = UUID string) when absent; same owner reuses; different owner -> `.failure(.profileDenied)`.
  - `public func delete(profileId: String, ownerTokenHash: String, isSystemCaller: Bool) -> FBError?` — nil on success/deleting-unknown; `.notOwner` on cross-owner.
  - `public func entry(profileId: String) -> Entry?`; `public func count() -> Int` (tests).
  - `public func closeLastSession(profileId:)` helper is NOT needed; store deletion is Task 4's close wiring.
- [ ] Step 1: Failing tests: resolve creates then reuses (same storeId); cross-owner denied; delete cross-owner -> `notOwner`; system caller may delete; corrupt registry file (write garbage) -> next resolve succeeds and logs, does not throw; file mode is 0o600.
- [ ] Step 2: `swift test --filter ProfileRegistryTests` -> FAIL.
- [ ] Step 3: Implement (internal `NSLock`, JSON on disk, atomic write via temp+rename, corrupt -> empty map).
- [ ] Step 4: PASS.
- [ ] Step 5: Commit `feat: profile registry with token-hash ownership`.

### Task 4: Profile-aware create + dataStore plumbing

**Files:**
- Modify: `Sources/FusionBrowser/WebView.swift:63-73` (init param + store selection)
- Modify: `Sources/FusionBrowser/SessionManager.swift:236-372` (resolve profile, pass store/hub, record for close)
- Modify: `Sources/FusionBrowser/UDSServer.swift:351-368` (cap gate + ownerKey)
- Test: `Tests/FusionBrowserTests/ProfileCreateTests.swift` (create; registry-level + gate-helper only)

**Interfaces:**
- Consumes: Task 1 `ownerKey`, Task 2 `profileId`, Task 3 registry.
- Produces: `FBWebView.init(mode:sessionId:dataStore: WKWebsiteDataStore? = nil, streamHub: FBStreamHub? = nil)`; `FBSessionManager.create(req:traceId:ownerId:ownerKey: String? = nil)`; UDS `.createSession` path: `profileId != nil` without `.persistentProfiles` cap -> `send(error: .authDenied)`; `profileId != nil` with `ownerKey == nil` (system caller/CDP) -> `send(error: .profileDenied)`.
- [ ] Step 1: Failing tests: `testProfileGateRequiresCap` (extract pure helper `FBProfileGate.allow(profileId:caps:) -> FBError?` in ProfileRegistry.swift); `testProfileGateNoOwnerKeyDenied`.
- [ ] Step 2: FAIL.
- [ ] Step 3: Implement gate helper + wiring (SessionManager uses `WKWebsiteDataStore(forIdentifier: UUID(uuidString: storeId)!)` on main; `FBSession` records `profileId`; `close` calls registry store deletion when the last session of that profile closes — best-effort, logged).
- [ ] Step 4: `swift test --filter "Profile|SessionManager"` -> PASS.
- [ ] Step 5: Commit `feat: persistent profile sessions (profileId -> WKWebsiteDataStore)`.

### Task 5: Chromium cookie crypto

**Files:**
- Create: `Sources/FusionBrowser/CookieCrypto.swift`
- Test: `Tests/FusionBrowserTests/CookieCryptoTests.swift`

**Interfaces:**
- Produces: `enum FBDecryptStatus: String { case ok, appBound, plaintext, failed }`; `enum FBChromiumCookieCrypto { static func deriveKey(password: Data, iterations: Int = 1003, keyLength: Int = 16) -> Data; static func decrypt(_ blob: Data, key: Data) -> (value: String?, status: FBDecryptStatus) }` — `v10`/`v11` prefixes AES-128-CBC, IV = 16 x 0x20, PKCS7; `v20` -> (nil, .appBound); no prefix -> UTF-8 of blob as .plaintext; CBC failure -> (nil, .failed).
- [ ] Step 1: Failing tests: key derivation deterministic for a fixed password; encrypt->decrypt roundtrip; wrong key -> .failed; `v20` blob -> .appBound; plaintext blob -> .plaintext; truncated CBC body -> .failed (no crash).
- [ ] Step 2: FAIL.
- [ ] Step 3: Implement with `CCKeyDerivationPBKDF` + `CCCrypt`.
- [ ] Step 4: PASS.
- [ ] Step 5: Commit `feat: chromium cookie decryption (v10/v11, v20 detected)`.

### Task 6: Browser cookie readers

**Files:**
- Create: `Sources/FusionBrowser/BrowserCookieImport.swift`
- Test: `Tests/FusionBrowserTests/BrowserCookieImportTests.swift`

**Interfaces:**
- Consumes: Task 5.
- Produces:
  - `enum FBBrowserKind: String { case chrome, edge, firefox }`
  - `struct FBImportedCookie { var attrs: [String: String] }` (keys: name, value, domain, path, secure, httponly, samesite, expires)
  - `struct FBCookieImportConfig { var chromeUserDataDir: String; var edgeUserDataDir: String; var firefoxProfilesDir: String; static let `default`: ... }` (real macOS paths)
  - `final class FBBrowserCookieImporter { init(config:keyProvider: @escaping (FBBrowserKind) -> Data?); func importCookies(kind:FBBrowserKind, profile:String?) -> FBResult<ImportResult>; struct ImportResult { var cookies: [FBImportedCookie]; var skippedAppBound: Int; var skippedOther: Int } }`
  - Chromium paths probed: `<dir>/<profile>/Network/Cookies`, then `<dir>/<profile>/Cookies` (`profile` default `"Default"`); DB copied to temp first (WAL sidecar too).
  - Chrome epoch: `expires_utc/1_000_000 - 11644473600`, <= now -> empty expires (session cookie).
- [ ] Step 1: Failing tests (build fixture SQLite DBs with `SQLite3` in the test): chromium row mapping incl. leading-dot host and encrypted v10 value (encrypt via test helper using Task 5 primitives), v20 row -> counted appBound, plaintext value row -> imported; firefox row mapping + sameSite 0/1/2 -> unset/lax/strict; missing dir -> `.credentialNotFound` style failure with zero counts; `profile` path preference order (Network/Cookies first).
- [ ] Step 2: FAIL.
- [ ] Step 3: Implement readers + mappings + temp copy.
- [ ] Step 4: PASS.
- [ ] Step 5: Commit `feat: chrome/edge/firefox cookie readers`.

### Task 7: import_cookies route + stream hub + hooks

**Files:**
- Create: `Sources/FusionBrowser/StreamHub.swift`
- Modify: `Sources/FusionBrowser/UDSServer.swift` (3 new routes, teardown unsubscribe)
- Modify: `Sources/FusionBrowser/ActionDriver.swift` (publish at execute end)
- Modify: `Sources/FusionBrowser/WebView.swift` (didFinish publish; hub property)
- Modify: `Sources/FusionBrowser/SessionManager.swift` (hub on close -> `end`)
- Modify: `Sources/FusionBrowser/main.swift` (wire one hub into manager/driver)
- Test: `Tests/FusionBrowserTests/StreamHubTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4.
- Produces: `public final class FBStreamHub { init(minIntervalMs: Int = 200, now: @escaping () -> Double = { Date().timeIntervalSince1970 }); func subscribe(sessionId:key:send: @escaping (Data) -> Void) -> Int; func unsubscribe(sessionId:key:); func unsubscribeAll(key:); func hasSubscribers(sessionId:) -> Bool; func publish(sessionId: String, webview: any FBStreamCapturable); func end(sessionId: String, reason: String) }` where `protocol FBStreamCapturable { func screenshotPngAsync(_ completion: @escaping (Data?) -> Void) }` and `FBWebView` conforms (wraps `screenshotSync` off-main).
- [ ] Step 1: Failing tests: two subscribers receive the same frame; throttle drops a frame inside the window; in-flight capture skips a second publish; `end` emits one `stream_end` then no more frames; `unsubscribeAll` removes the connection.
- [ ] Step 2: FAIL.
- [ ] Step 3: Implement hub + routes: `stream_screenshots` (cap `.screenshot`, owner-checked), `import_cookies` (cap `.importCookies`, owner-checked, injects each cookie via `session.webview.injectCookies(attrs, domain:)`), `delete_profile` (owner/system-caller rules); connection teardown -> `unsubscribeAll(key: ownerId)`.
- [ ] Step 4: `swift test` full suite -> PASS (no regressions).
- [ ] Step 5: Commit `feat: screenshot stream hub + import/delete routes`.

### Task 8: Python client

**Files:**
- Modify: `client/python/fusion_browser_client/client.py`, `__init__.py`
- Test: `client/python/tests/test_client.py` (append)

**Interfaces:**
- Consumes: Task 2 wire strings.
- Produces: `create_session(..., profile_id: Optional[str] = None)`; `import_cookies(session_id, browser, profile=None) -> dict` (payload of `import_cookies` response); `delete_profile(profile_id) -> bool`; `class FusionBrowserStream(session_id, socket_path=..., token=None, timeout=None)` with `frames()` -> iterator of payload dicts, terminating on `stream_end` or EOF; re-exports in `__init__.py`.
- [ ] Step 1: Failing tests against the fake UDS server: profile_id passthrough; import_cookies response parse; delete_profile bool; stream subscribe sends correct frame and `frames()` yields a `screenshot_frame` payload then stops on `stream_end`.
- [ ] Step 2: `cd client/python && pytest tests/ -v` -> FAIL.
- [ ] Step 3: Implement (stream owns its own socket + auth; uses `_send`/`_recv_one`).
- [ ] Step 4: PASS.
- [ ] Step 5: Commit `feat(python): profile, cookie import, and screenshot stream client`.

### Task 9: Live harness

**Files:**
- Create: `scripts/cowork_smoke.py`
- Modify: `scripts/release_gate.sh` (hard-list entry)
- Test: run harness against the release binary

**Interfaces:**
- Consumes: all previous tasks.
- Produces: report JSON `scripts/cowork-smoke-report.json` with `ok` bool + phase detail.
- Harness flow: temp dir; build a firefox `cookies.sqlite` with a `session=ok` cookie for `127.0.0.1`; start engine (release binary, temp socket, config with `tokenCapabilities:["all"]`, `tokenSystemCaller:false`); create with `profileId`; import firefox cookies; start a tiny HTTP server whose `/check` sets/reads the cookie; navigate + assert login-state visibility via `evaluate(document.cookie)`; open a `FusionBrowserStream` on a second connection; execute a click; assert >=1 `screenshot_frame`; close session; restart engine; create same `profileId`; navigate `/check`; assert cookie persisted; delete_profile; assert `ok`.
- [ ] Step 1: Write harness (reuse codec from `scripts/smoke_client.py`).
- [ ] Step 2: `swift build -c release` then run harness -> PASS report.
- [ ] Step 3: Add to `release_gate.sh` hard list + update its doc comment.
- [ ] Step 4: Commit `feat: cowork managed-backend live harness`.

### Task 10: Docs + cowork issue

**Files:**
- Create: `docs/cowork-managed-backend-contract.md`
- Modify: `docs/PROTOCOL.md`, `README.md`, `CLAUDE.md` (Current State / config keys)
- External: issue on `dahai80/fusion-cowork`

**Interfaces:**
- Produces: contract stating: launch via UDS socket path; per-run `profileId`; `import_cookies` step with honest counters (Firefox strong path, Chrome/Edge best-effort, v20 skipped); stream requires a DIRECT local UDS connection (gateway is per-call-dial, cannot hold a subscription) and terminates on `stream_end`; required operator caps `persistentProfiles` + `importCookies` (+ `screenshot`, `all` for driver); cdp_* reuse unchanged.
- [ ] Step 1: Write contract doc.
- [ ] Step 2: Update PROTOCOL.md (new types/caps) + README (feature blurb) + CLAUDE.md current state + final test count.
- [ ] Step 3: `gh issue create --repo dahai80/fusion-cowork` (English) referencing the contract, listing the cowork-side deliverables (managed launch, per-run profile, import step, panel stream consumer).
- [ ] Step 4: Commit `docs: cowork managed-backend integration contract`.

## Self-Review

Spec coverage: A -> Tasks 3,4; B -> Tasks 5,6,7; C -> Tasks 2,7,8; G4 compat -> Task 2 (unknown-type test); G5 Python -> Task 8; live verify -> Task 9; docs + cowork issue -> Task 10; caps -> Task 1; owner rules -> Tasks 1,3; stream topology/end -> Tasks 7,10; nav hook -> Task 7.

Dependency order is strict: 1,2 before 4; 5 before 6; 4,6 before 7; 7 before 8,9; 10 last.
