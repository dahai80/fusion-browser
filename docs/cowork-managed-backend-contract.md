# fusion-cowork managed-browser backend contract

> Issue #25. This is the frozen contract fusion-cowork codes against; the wire
> schema itself is `docs/PROTOCOL.md` §3 + `Protocol.swift`.
> Status: fusion-browser side IMPLEMENTED and live-verified
> (`scripts/cowork_smoke.py`). cowork side is not implemented yet — issue filed
> on `dahai80/fusion-cowork`.

## 1. Topology

```
fusion-cowork  ──launch──▶  fusion-browser (one process per node)
     │                            │
     ├── command connection ──────┤  create / execute / close / import_cookies
     │   (one UDS socket,         │  delete_profile
     │    long-lived)
     │                            │
     └── panel connection ────────┘  stream_screenshots → screenshot_frame*
         (SECOND UDS socket,          → stream_end
          long-lived)

      same auth token, same machine, same user
```

Three rules follow from this shape:

- The engine is ONE process; every connection authenticates with the node's
  `authToken`. Multiple connections are normal (command + panel), not a proxy.
- The stream lives on the connection that subscribed. **A per-call-dial proxy
  (fusion-gateway) cannot hold a subscription** — it closes the socket after
  each op, which cancels the stream. Panel streaming is a direct-local-UDS
  feature, not a gateway feature.
- Local only. There is no cloud hop in this contract; the engine is
  `127.0.0.1`/UDS and never dials out except to the URLs the workflow visits.

## 2. Engine launch and operator config

cowork launches `.build/release/fusion-browser` as a child process and points it
at its OWN config file via `FUSION_BROWSER_CONFIG` (an absolute path), so it
never touches the operator's `~/.fusion-browser/config.json`:

```json
{
  "socketPath": "/tmp/fusion-cowork-browser.sock",
  "authToken": "<shared secret chosen by cowork>",
  "tokenCapabilities": ["all"],
  "allowedOrigins": ["https://example.com"],
  "logLevel": "info",
  "cookieImport": {
    "chromeUserDataDir": "~/Library/Application Support/Google/Chrome",
    "edgeUserDataDir": "~/Library/Application Support/Microsoft Edge",
    "firefoxProfilesDir": "~/Library/Application Support/Firefox/Profiles"
  }
}
```

- `socketPath` — cowork picks it (per node/instance) and dials it. Default is
  `/tmp/fusion-browser.sock`.
- `authToken` — required. Without it every UDS connection is denied.
- `tokenCapabilities` — must include `persistentProfiles` + `importCookies`
  (plus `screenshot`; the action set for driving a session). `["all"]` is the
  simple answer for a single-tenant node.
- `allowedOrigins` — FAIL-CLOSED. `evaluate` and CDP navigation are denied
  unless the page's origin is listed. A workflow that evaluates on arbitrary
  sites must list those origins.
- `cookieImport.*` — optional per key; missing keys fall back to the real
  macOS defaults shown above.
- A present-but-malformed config **exits non-zero with the parse error on
  stderr** (never a silent default fallback).
- Cowork should start the engine once per run session and stop it with
  SIGTERM; the process holds a `.userInitiated` activity token so snapshots do
  not race WebKit suspension.

`tokenSystemCaller` is NOT needed for this integration: cowork is a direct
client (its command connection owns what it creates) and the panel stream is
admitted by principal (§6). Set it only for a real per-call-dial proxy.

## 3. Capabilities

`auth_ack.caps` is a bitmask; `tokenCapabilities` in the config elevates it.

| Bit | Value | Grants |
|-----|-------|--------|
| screenshot | 1<<4 | 16 | `screenshot` action + `stream_screenshots` |
| evaluate | 1<<5 | 32 | `evaluate` action (also origin-gated) |
| metrics | 1<<7 | 128 | `metrics` + `capacity` reads |
| importCookies | 1<<8 | 256 | `import_cookies` |
| persistentProfiles | 1<<9 | 512 | `create_session.profile_id` + `delete_profile` |

- `.default` = 95 (no evaluate, no metrics, no import, no profiles).
- `.all` = 1023.
- Unknown capability names in config are DROPPED (fail-closed); never broaden
  by typo.
- The recommended cowork node config is `["all"]`: a workflow both drives and
  streams. A stricter deployment can use
  `["navigate","click","type_text","scroll","screenshot","close","evaluate",
  "import_cookies","persistent_profiles"]`.

## 4. Session lifecycle with a per-run profile

```json
{"type": "create_session",
 "payload": {"mode": "headless",
             "initial_url": "https://example.com/login",
             "profile_id": "run-2026-10-21-7f3c"}}
```

- `profile_id` is cowork's own label for a workflow run (any stable string,
  e.g. `run-<uuid>`). It maps to a persistent `WKWebsiteDataStore` on disk, so
  cookies/localStorage survive a session close AND an engine restart.
- Omitting `profile_id` keeps today's FR-04 behaviour: an in-memory,
  non-persistent store, wiped at close. Nothing else about create changes.
- A profile is owned by the AUTH-TOKEN hash that first used it. A second token
  creating the same `profile_id` gets `profile_denied` — login state never
  crosses trust domains.
- Re-using a `profile_id` after a restart resumes the login (verified live).
- `delete_profile` (`{"profile_id": ...}` → `{"profile_id", "deleted"}`) drops
  the registry entry and the on-disk WebKit store. Call it at the end of a run
  unless the run must be resumable. `deleted: false` means there was nothing to
  delete — not an error.
- `initial_url` is fire-and-forget: create returns before the page finishes
  loading. When the next action MUST see the loaded page, either
  `create_session()` with no URL + `execute navigate`, or wait for a
  `screenshot_frame` whose `url` is the expected page.
- A create with NO `initial_url` still loads a minimal blank document on
  purpose (WebKit crash guard) — do not treat that as a spurious navigation.

## 5. Cookie / login-state import

```json
{"type": "import_cookies",
 "payload": {"session_id": "…", "browser": "firefox"}}
```
```json
{"type": "import_cookies",
 "payload": {"session_id": "…", "browser": "chrome", "profile": "Profile 1"}}
```

Response:
```json
{"session_id": "…", "browser": "firefox",
 "imported": 1, "skipped_app_bound": 0, "skipped_other": 0}
```

- `browser`: `firefox` | `chrome` | `edge` (case-insensitive).
- `profile` — optional. Firefox: full profile dir name (`xxxx.default-release`)
  or just the suffix (`default-release`); nil picks the `.default*` profile.
  Chrome/Edge: a `User Data` subdirectory (`Default`, `Profile 1`).
- The import reads the user's REAL browser profile. It never writes to it: the
  cookie DB is copied (with `-wal`/`-shm`) to a temp dir and read-only opened.
- `imported` counts cookies the session actually holds — read AND committed to
  the WKWebView cookie store. Anything read but rejected is a skip, never a
  silent success.

Per-browser honesty:

| Browser | Path on macOS | Value encryption | Reality |
|---------|---------------|------------------|---------|
| Firefox | `~/Library/Application Support/Firefox/Profiles/<p>/cookies.sqlite` | plaintext | STRONG — full attr fidelity |
| Chrome | `…/Google/Chrome/<profile>/Network/Cookies` | AES-128-CBC, key from Keychain "Chrome Safe Storage" | BEST-EFFORT. First read may show a macOS consent prompt; denied consent → encrypted rows skipped |
| Edge | `…/Microsoft Edge/<profile>/Network/Cookies` | same scheme (Keychain "Microsoft Edge Safe Storage") | BEST-EFFORT, same as Chrome |

- Chromium `v20` (app-bound) cookies cannot be decrypted by any third party by
  design: they are counted in `skipped_app_bound` and never imported.
- A cookie whose value decrypts to an empty string is skipped (`skipped_other`).
- Source unreadable / Keychain denial → `import_denied` (not a partial success).
- Expiry: Chromium's 1601-epoch microsecond timestamps are converted to Unix
  seconds; 0/past expiries become session cookies (no `Expires`). Second-granular
  and clamped to CFNetwork's ~400-day cap on commit.
- **Import only at the start of a run** (before or right after the first
  navigation). The engine injects into the live session's cookie store; a page
  already loaded does not retroactively see them.
- After import, verify the login survived: navigate to a page whose body
  differs when logged in, or `evaluate` `document.cookie` (needs the `evaluate`
  cap + the origin allowlist). Do NOT assume import == logged in.

## 6. Screenshot stream for the side panel

Subscribe on the PANEL connection (its own socket, same token):

```json
→ {"type": "stream_screenshots", "payload": {"session_id": "…", "enabled": true}}
← {"type": "stream_ack", "payload": {"session_id": "…", "active": true}}
← {"type": "screenshot_frame", "payload": {"session_id": "…", "seq": 1,
     "png": "<base64 PNG>", "url": "https://…", "title": "…", "ts_ms": 1761...}}
← {"type": "stream_end", "payload": {"session_id": "…", "reason": "session_closed"}}
```

- The ack is sent BEFORE the subscription starts, then one immediate frame
  follows, so the panel is never blank while waiting for the next action.
- Frames are published after every successful action and after each page
  `didFinish`. Throttled to one per session per 200 ms; a capture still in
  flight is never stacked (in-flight skip) — the panel gets the newest frame at
  a bounded rate, not every frame.
- `seq` increments per session; a gap means throttling, not loss of ordering.
  `url`/`title` describe the frame's page.
- Ownership: the panel's connection UUID differs from the creator's, so the
  engine admits a subscriber with the SAME AUTH TOKEN as the session creator
  (read-only channel). A connection with a different token gets `not_owner`.
  Control (`execute`/`close`) stays connection-scoped — the panel cannot drive.
- `enabled: false` unsubscribes and acks `active: false`.
- The stream ends with exactly one `stream_end` when the session closes or the
  connection drops. Clients must treat `stream_end` and EOF as normal terminal
  states and re-subscribe only after creating a new session.
- **Do not route the panel stream through a per-call-dial proxy** — the socket
  close cancels it. Direct UDS only.

## 7. AX-tree and visual-locator action reuse

Nothing changes for cowork's existing action surface — this feature is additive.

- `execute` with `navigate` / `click` / `type_text` / `scroll` / `screenshot` /
  `evaluate` keeps its contract (`docs/PROTOCOL.md` §3.3). `state` responses
  carry `interactive_nodes` (each with `node_id`, `role`, `name`,
  `current_value`, `bbox`) + the markdown tree.
- Node ids are BARE `eN` on the wire; the markdown tree shows `[@eN]` for the
  LLM only. Send back what `interactive_nodes` gave you.
- The CDP shim (`cdpEnabled`) is untouched: `Runtime.evaluate`,
  `Accessibility.getFullAXTree`, `Page.captureScreenshot`, `Page.navigate`,
  `DOM.*`, events — cowork's `cdp_client.py` keeps working as documented,
  including the strict Origin gate (cowork must send an allowlisted Origin).
- Visual locator (T3.4) still fires only on click `node_stale` as a
  best-effort fallback; it needs a VLM loaded in fusion-mlx and is OFF by
  default (`visualLocator.enabled`).
- Practical loop for cowork's `cdp_*` nodes and the managed-browser path:
  extract → act on ids → re-extract after any navigation or SPA re-render.
  Handles are single-use; a reordered page invalidates positional ids.

## 8. Errors, limits, and honest counters

New codes from this feature (full table in `docs/PROTOCOL.md` §6):

| Code | Retryable | When |
|------|-----------|------|
| `import_denied` | false | browser DB unreadable, or Keychain consent refused |
| `profile_denied` | false | profile belongs to another token, or no token identity |
| `auth_denied` | false | missing capability (`importCookies`, `persistentProfiles`, `screenshot`) |
| `not_owner` | false | stream subscribe / control op from a different principal |
| `session_not_found` | false | session closed before the op |
| `quota_exceeded` | false | node session cap reached (RAM-tiered) |

Limits worth designing around:

- Max 16 live sessions per node by default (RAM-tiered by the host).
- Repeat-action guard: 3+ consecutive identical `action:target:payload` is
  rejected (`internal_error` with a repeat-break message). Rotate targets.
- The first click on a fresh session needs a prior extract (a screenshot or a
  navigate that returned state) — otherwise `node_stale`.
- `import_cookies` is bounded by the browser's DB size; a few thousand cookies
  is normal, and each commit waits on WebKit (off-main), so expect seconds, not
  milliseconds, on a large profile.
- The engine logs counts and codes only — never cookie names or values.

## 9. cowork-side deliverables

Everything below lands in fusion-cowork (this project ships the engine side
only). Filed as `dahai80/fusion-cowork#162`
(https://github.com/dahai80/fusion-cowork/issues/162):

1. **Managed launch** — spawn `.build/release/fusion-browser` with
   `FUSION_BROWSER_CONFIG` pointing at a per-run config; wait for the socket;
   SIGTERM on run teardown. No operator setup, no `~/.fusion-browser` writes.
2. **Per-run profile** — `create_session(profile_id: "run-<id>")`; keep the id
   in run state so a resumed run re-attaches; `delete_profile` when the run is
   finished and non-resumable.
3. **Login import step** — an optional pre-step that calls `import_cookies`
   (browser + optional profile) and reports the honest counters to the user
   ("imported N, skipped M app-bound") instead of claiming success.
4. **Panel stream consumer** — a second connection running
   `stream_screenshots`, rendering `screenshot_frame.png`; treat `stream_end`
   as terminal; never route it through a per-call-dial proxy.
5. **Node wiring** — the managed browser is reachable from the existing
   `cdp_*` / browser node family with no contract change; the UDS client
   already exists at `client/python/fusion_browser_client/`.

Acceptance for the issue: cowork opens a login-required site and completes a
form with zero manual browser setup, and the Python client drives the same
session.

## 10. Verification

| Layer | Command | Proves |
|-------|---------|--------|
| deterministic | `swift test --disable-sandbox` (294) | cookie crypto, import mapping, stream hub, ownership rules, protocol codec |
| Python client | `cd client/python && pytest tests/` (14) | wire codec + stream client against a fake UDS server |
| live E2E | `python3 scripts/cowork_smoke.py` | profile + real Firefox import + login + stream frames + engine-restart persistence + delete, all against the release binary |
| full gate | `scripts/release_gate.sh` | build + 294 tests + 11 live harnesses (cowork_smoke included) |

`scripts/cowork_smoke.py` self-cleans (temp dir, temp profile, engine stop) and
writes `scripts/cowork-smoke-report.json` with the per-phase evidence. It is a
HARD gate in `release_gate.sh` and in CI's `live-path-gate` job.
