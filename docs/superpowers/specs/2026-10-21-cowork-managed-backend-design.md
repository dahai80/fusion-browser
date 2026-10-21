# Design: fusion-browser as Managed-Browser Backend for fusion-cowork (Issue #25)

> STATUS: DRAFT — pending partner approval.

## Intent & Why

Cowork ships a built-in browser; Anthropic Cowork comparison (insight/fusion-cowork-vs-anthropic-1021.md §7.1 P0-5) flags cowork's manual Chrome debug-port launch as a gap. Issue #25 asks fusion-browser to be the managed backend so a cowork run gets a working browser with zero manual setup: per-run login state, cookies imported from the user's browser, and a live screenshot view in cowork's web panel.

This repo ships the engine-side surface + contract doc + a filed issue on fusion-cowork (monorepo rule: cowork-side code lands via issue → PR in that repo).

## Goals / Non-goals / Anti-goals

Goals:
- G1 Persistent profile per workflow run (`profileId` on create) — login state survives session close AND engine restart.
- G2 Cookie/login-state import from the user's Chrome/Edge/Firefox on macOS into a live session.
- G3 Screenshot stream: engine pushes a frame after each action/navigation to subscribed connections (cowork panel consumes via its backend).
- G4 Additive wire schema; existing clients unaffected.
- G5 Python client (`client/python`) gains profile/import/stream support so the same session is test-drivable.

Non-goals:
- CDP-side screencast emulation (Page.startScreencast) — stream is UDS-only.
- Cross-node profile roaming (gateway-side concern, out of scope).
- Importing passwords/history/autofill — cookies only.
- cowork-side panel/launch code (lands in fusion-cowork via issue).

Anti-goals:
- Breaking FR-04 default non-persistence: no `profileId` → behavior byte-identical to today.
- Broadening caps: cookie import touches the user's Keychain + browser profiles → dedicated capability, fail-closed.

## Constraints

- macOS 14+ (WKWebsiteDataStore(forIdentifier:) is macOS 14.0+).
- No external SPM deps: SQLite via system `import SQLite3`, AES-CBC via system `import CommonCrypto`.
- E-40/FR-06 main-thread rules unchanged; WKWebView ops main-hop as today.
- Wire is snake_case JSON, length-prefixed; unknown `type` from an old client to a new server stays a clean error frame.
- H-5 scoped-token model: new privileged surface NOT in `.default`.

## Part A — Persistent Profiles

- `CreateSessionRequest.profileId: String?` (additive, default nil = today's nonPersistent store).
- New `FBProfileRegistry.swift`: maps `profileId → {storeId: UUID, ownerTokenHash: String, createdAt}`. Registry file `~/.fusion-browser/profiles.json` (0o600, atomic writes, corrupt file = rebuilt fail-safe, log loud).
- Builder call (ownership identity, resolves builder-check Q1): owner is the **auth token SHA256 hex** (M-6 pattern — raw token never stored), NOT the per-connection UUID. Connection UUIDs die on reconnect and are meaningless through fusion-gateway's per-call-dial mode; the token is the only stable client identity the engine has. Same token = same owner across connections/proxy hops.
- Builder call (collision rules): `create` with an existing `profileId` — same owner token → allowed (shared store, see below); different owner token → `.notOwner`-family error `profile_denied` (never adopt or share across trust domains; anti-goal is cross-client login-state reuse). No nil-owner profiles: system-caller creates record the system token's hash, so every profile is attributable and GC-able.
- WebView init gains `dataStore: WKWebsiteDataStore?` param (nil = `nonPersistent()`); SessionManager.create resolves registry before building the webview.
- Profile store data lives under `~/Library/WebKit/` per-store dirs managed by WebKit itself (engine never touches cookie blobs directly).
- Builder call (concurrency, resolves Q5): two live sessions on one `profileId` allowed ONLY for the same owner token — a same-trust shared cookie jar (parallel tabs on one login); cross-token share is denied at create. Documented as live coupling.
- New request `{type:"delete_profile", payload:{profileId}}` → `{type:"profile_deleted", payload:{profileId, deleted}}`. Allowed for the owner token hash or a system caller; else `not_owner`. Live sessions on the profile keep working; the registry entry is removed and the WebKit store is deleted when its last session closes (best-effort, logged).
- Builder call (privilege, resolves Q6): NEW `FBCapabilities.persistentProfiles` bit (1<<9, after `.importCookies`), in `.all`, NOT in `.default`; `parseCaps` accepts `"persistentProfiles"`. A persistent profile writes login state that survives restarts — the same anti-goal tier as cookie import; an unscoped token must not mint stores.
- Same `profileId` re-created after close → same store → cookies/localStorage persist across engine restarts (workflow-run identity).

## Part B — Cookie Import (Chrome / Edge / Firefox, macOS)

- New `BrowserCookieImport.swift`. Request: `{type:"import_cookies", payload:{sessionId, browser:"chrome"|"edge"|"firefox", profile?:String}}` → `{type:"import_cookies", payload:{sessionId, imported:Int, skippedAppBound:Int, skippedOther:Int}}`.
- Chromium (chrome + edge share the reader):
  - DB paths probed in order: `<user-data-dir>/<profile>/Network/Cookies` then `<user-data-dir>/<profile>/Cookies`. Defaults: `~/Library/Application Support/Google/Chrome`, `~/Library/Application Support/Microsoft Edge`. DB copied to a temp file first (live Chromium holds the lock; WAL sidecar copied too).
  - Row → attrs: `host_key→domain` (leading dot preserved), `name`, `path`, `value`/`encrypted_value`, `is_secure→secure`, `is_httponly→httponly`, `expires_utc` (Chrome 1601-µs epoch → unix seconds; 0/past = session cookie).
  - Decryption: prefix `v10`/`v11` → AES-128-CBC, key = PBKDF2-SHA1(safe-storage password, salt `"saltysalt"`, 1003 iters, 16B), IV = 16×0x20, PKCS7 strip (CommonCrypto CCCrypt). Safe Storage read from Keychain: service `"Chrome Safe Storage"` / `"Microsoft Edge Safe Storage"` (user sees a consent prompt once per binary; deny → `import_denied` error, never a silent empty result).
  - Prefix `v20` (M127+ app-bound encryption) is NOT decryptable by third parties — counted in `skippedAppBound`, honestly reported. Plaintext `value` fallback counts as imported.
- Expectations (builder-check Q2, accepted): on a current Chrome/Edge (M127+) most cookies are v20 → `imported` may be ~0 with a large `skippedAppBound`. That is the honest result of a third-party decrypt attempt; no alternate mechanism is in scope (driving a running Chrome via DevTools is a different feature). The contract doc states Firefox is the strong path, Chromium best-effort. The import counters exist exactly so coworkers/UX can say "Chrome blocked N cookies" instead of silently logging in a stale state.
- Firefox: `~/Library/Application Support/Firefox/Profiles/<profile>/cookies.sqlite` (or the single default profile when `profile` omitted), plaintext columns `host/name/value/path/expiry/isSecure/isHttpOnly/sameSite` (0 → unset, 1 → lax, 2 → strict; verified against Firefox source semantics).
- Injection reuses the existing `wv.injectCookies(attrs, domain:)` path (same attr shape as Keychain creds). Audit log records op/result only (E-39: never cookie names/values).
- Capability: NEW `FBCapabilities.importCookies` bit (1<<8, appended after `.metrics` so existing rawValues stay stable), added to `.all`, NOT in `.default`; `parseCaps` accepts `"importCookies"`. Operators grant via `tokenCapabilities`.
- Builder call (mine): no `domain` allowlist on import — the caller already owns the session; filtering by domain belongs to the caller (cowork passes the site it is automating).

## Part C — Screenshot Stream

- New `FBStreamHub.swift`: per-session subscriber list of `FBClientConnection` (weak via the server's retain set — hub holds strong refs only for active subscriptions, unregistered on connection teardown).
- Subscribe: `{type:"stream_screenshots", payload:{sessionId, enabled:Bool}}` → ack `{type:"stream_ack", payload:{sessionId, active:Bool}}`. Requires `.screenshot` cap + owner check (`manager.get(sid, ownerId:)`).
- Publish hooks (resolves builder-check Q4): (1) end of `FBActionDriver.execute` (covers UDS + CDP action paths); (2) `FBWebView` `WKNavigationDelegate.didFinish` — a click-triggered navigation completes AFTER the driver returned, so action-end alone would leave the panel showing the pre-navigation page. `didFinish` publishes through `FBStreamHub` (hub injected into FBWebView init; no global singleton beyond the hub itself). Both hooks share the per-session throttle, so the nav frame folds into the action frame inside the 200ms window. Session `create`'s initial load needs no hook — nobody can subscribe before create returns.
- Push frame (unsolicited, only on subscribed connections): `{type:"screenshot_frame", payload:{sessionId, seq, png:<base64>, url, title, ts_ms}}`.
- Stream end semantics (resolves Q3): when the subscribed session closes, the engine pushes ONE `{type:"stream_end", payload:{sessionId, reason:"session_closed"}}` then drops the subscription (frame order guaranteed — same connection write path). Engine restart mid-stream = socket EOF; clients reconnect. Python `frames()` iterator terminates on `stream_end` or EOF, never blocks forever.
- Topology (resolves Q3): the stream requires a DIRECT, long-lived UDS connection to the engine on the same node — fusion-gateway is per-call-dial by design (R-10) and structurally cannot hold a subscription. Cowork's backend opens the stream connection locally next to its control connection; cross-node viewing is out of scope (would need a gateway streaming mode — would be a separate gateway issue if ever wanted). Stated explicitly in the cowork contract doc.
- Throttle (builder call, mine): min 200ms between frames per session + skip if a capture is already in flight (never queue more than one) — keeps the stream near-live without slowing the action path. Push never blocks the action path: capture runs off-main async, action response is sent before the frame.
- Frames are pushed ONLY on connections that subscribed — non-subscribing clients (request/response python client) never see interleaved frames, so the existing sync client stays desync-proof.
- Python client: new `FusionBrowserStream` — opens its OWN socket (auth + subscribe + `frames()` iterator yielding dicts). Document: stream connection is separate from the command connection.

## Wire Compat

All additions are new `type` values + one optional `CreateSessionRequest.profileId`. Old server + new client: unknown type → clean `error` frame (documented). New server + old client: old clients never send the new types; `profileId` absent = unchanged behavior.

## Tests (deterministic, `swift test` — no live WKWebView per ARCH-3)

- ProfileRegistry: roundtrip, owner rules, corrupt-file rebuild, delete of unknown id.
- Cookie import: decrypt primitive roundtrip (test encrypts with CommonCrypto + fake key, reader decrypts); Chrome-epoch conversion; host_key leading-dot mapping; row→attrs mapping for chrome/edge/firefox; path probing order; reader seam accepts injected paths (no real browser DB in tests); v20 → skippedAppBound; plaintext value fallback.
- StreamHub: subscribe/ack, publish to N subscribers, throttle window, in-flight skip, seq monotonic, unsubscribe on teardown. Fake sender closure — no socket.
- Protocol: new FBRequest/FBResponse cases encode/decode roundtrip; old-decoder rejects new type cleanly.
- Auth: `importCookies` + `persistentProfiles` bits not in `.default`, present in `.all`, parseCaps names, rawValue stability of existing bits.
- Python (pytest, fake UDS server): stream subscribe/ack/frame iterator; import_cookies response parse; profileId passthrough.

## Live Verification (release binary + harness, NOT swift test)

- `scripts/cowork_smoke.py`: engine up → create(profileId) → import firefox cookies from a handcrafted cookies.sqlite → navigate login-required local page → stream subscribe on second connection → execute click → assert screenshot_frame received → close → engine restart → create(same profileId) → assert persisted cookie visible. PASS report → `scripts/cowork-smoke-report.json`.
- Chrome/Edge real-Keychain import is manual/advisory (prompt needs user consent); deterministic tests cover the decrypt path.
- `release_gate.sh`: add cowork_smoke to the hard list.

## Docs & Cross-Project

- `docs/PROTOCOL.md` + `README.md` updated (new types, caps, profile semantics).
- New `docs/cowork-managed-backend-contract.md`: the cowork-side integration contract (launch binary via UDS path, per-run profileId, import step, stream connection for the panel, cdp_* reuse notes, auth/caps to request).
- File issue on fusion-cowork referencing the contract (monorepo rule). Code lands there later.

## Left to the Builder

- Exact PBKDF2/CCCrypt call shapes (per CommonCrypto headers).
- Screenshot capture size (reuse full 1280×800 PNG as today's screenshot action).
- Registry file locking (single engine process assumed; atomic write suffices).
