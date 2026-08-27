# fusion-browser

> Doc version: Phase 4 production-hardening landed (2026-08-26)
> Spec: `architecture/fusion-browser-prd-0826.md` (v2.0) + `audit/fusion-browser-audit-0826.md`
> Plan: `~/fusion/fusion-browser-prd-plan-0826.md`
> Docs: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · [`docs/PROTOCOL.md`](docs/PROTOCOL.md) · [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
> Bilingual: this file is English (default) — see [`README_CN.md`](README_CN.md) for Chinese.

macOS native controlled browser engine. Provides Web visual + structured
interaction for `fusion-agent-studio`, with CDP-automation reuse for
`fusion-cowork`. Built on macOS native WebKit (WKWebView), dual protocol stack
(UDS length-prefixed JSON main path + CDP-over-WS compatibility layer), with six
built-in infrastructure modules.

## Current State (Phase 4 production-hardening landed)

Phase 1 engine base + six infra modules + Phase 2 four tasks (AXTree extractor /
anti-injection sanitizer / CDP compat layer / credential closure) + Phase 3 three
tasks (multi-node dynamic quota / CDP domain extension + events / visual-grounding
fallback) + Phase 4 five tasks (non-persistence verification / RSS self-restart /
perf benchmark suite / UMA coexistence baseline / 1000-action long-run no-leak)
complete. Build green, 99 unit tests pass. CDP `:9222` end-to-end smoke pass;
T3.4 visual grounding verified via real VLM smoke; Phase 4 all verified via the
release binary + Python verify scripts.

**Phase 1 landed**
- Swift 6 SPM package, Headless/Headed WKWebView wrapper (`nonPersistent` dataStore isolation, shared `WKProcessPool`)
- UDS server (POSIX socket + `DispatchSourceRead`, bypassing the unreliable `NWListener` AF_UNIX accept)
- Length-prefixed JSON framing (schema-aligned, snake_case; codec swappable to gRPC later)
- FR-08 resource control: dynamic session count / memory budget by physical RAM, over-quota rejected
- FR-09 flow backpressure: per-client read loop, one socket's large frame does not block others, over-cap dropped
- FR-10 auth capability model: shared-secret token, per-action capability check, EVALUATE needs separate capability + origin whitelist
- FR-11 error model: structured `{code,message,retryable}`, predefined error codes (node_stale/credential_locked/quota_exceeded/evaluate_denied/timeout/replay_limit, etc.)
- FR-12 observability: metrics (count + latency quantiles) + trace_id full chain + credential append-only audit log
- FR-13 scheduling guards: max_actions + task_timeout + consecutive-identical-action break + rebuild-depth cap 1
- NFR-R tiered watchdog: navigate 30s / click·type 2s / scroll 500ms / screenshot·evaluate 5s; timeout crashed→rebuild, replay idempotent actions only (navigate/scroll/screenshot), non-idempotent (click/type/evaluate) fail directly

**Phase 2 landed**
- T2.1 AXTree extractor: injected JS walker extracts DOM, structural fingerprint (tag + attribute subset + docPath) + JS-side `window.__fbMap` WeakRef<Node> stable mapping, `eN` synthetic locator; Markdown reduction (interactive nodes one line each, drop non-essential fields); stale `eN` returns `node_stale`
- T2.2 anti-injection sanitizer: static hidden-vector rule catalog (display:none/visibility:hidden/opacity:0/font-size:0/aria-hidden/hidden/offscreen/text-indent/scale/filter-opacity/color=bg/covered-overlay) + post-render measurement (`getBoundingClientRect` size 0/offscreen + `elementFromPoint` hit); purge strips text only, keeps node structure (zero false-kill); adversarial test set + deterministic unit tests cover 100% interception
- T2.3 CDP compat layer: `:9222` CDP-WS shim (NOT real Chrome, a translation layer), POSIX TCP + HTTP discovery (`/json`/`/json/version`/`/json/new`/`/json/close`) + RFC 6455 WS frame codec (SHA1 Sec-WebSocket-Accept), `FBCDPTranslator` translates Page/Runtime/Accessibility/Input/DOM methods into `FBActionDriver` actions + AXTree extract; aligned to cowork `cdp_client.py` contract (`result.result.value`/`result.nodes[...].backendNodeId`/`result.data`/`result.frameId`); non-whitelisted EVALUATE rejected; default off (`cdpEnabled`)
- T2.4 credential closure: Keychain stores **full cookie attributes** (name/value/domain/path/expires/secure/httponly/samesite), account=domain, injected into the session in-memory `httpCookieStore`; LLM gets only `credential_injected:bool` (plaintext never leaves Keychain/memory); `type=password` input values masked to `********` in AXTree; locked screen returns `credential_locked`; credential audit log records op/result only, never the value; NFR-S2/D11 retain by default, `logout` deletes

**Phase 3 landed**
- T3.2 multi-node adaptation: `FBResourcesQuota.forHost(ramGB:)` tiers session count / total memory by RAM (<8GB→2, 8-16GB→4, 16-32GB→10, ≥32GB→16), perSession=150MB, total=sessions×150; over-quota `create` rejected with `quota_exceeded`; explicit RAM reload makes the tier table unit-testable (no dependence on the test machine)
- T3.3 CDP domain extension: `FBCDPTranslator` extended with Network/Console/Emulation/Page.lifecycleEvent (Page.frameNavigated + lifecycleEvent, Network.requestWillBeSent/responseReceived/loadingFinished, Runtime.consoleAPICalled), DOM.focus/setFileInputFiles; events decoupled into a standalone `FBCDPEventEmitter` (send-closure driven, no live socket/webview dependency → deterministic unit-testable); cowork remaining nodes drop in without downgrade
- T3.4 visual-grounding fallback: on click `node_stale`, `FBVisualLocator` takes a `screenshotSync` PNG + the stale node's role/name description → calls fusion-mlx OpenAI-compatible `/v1/chat/completions` (VLM reads `image_url` base64 data URI) → parses `{x,y}` → `elementFromPoint` click; OOB/negative guards reject hallucination; pluggable `FBHTTPClient` protocol makes prediction logic unit-testable (real VLM load is integration smoke only); default off (`visualLocator.enabled`, needs a VLM loaded in fusion-mlx first)

**Phase 4 landed (production-hardening)**
- P4-1 non-persistence verification (FR-04): `nonPersistent` dataStore measured live — drives a data-URL page to write `document.cookie`+`localStorage`, lsof confirms the process holds no persistent WebKit data files (WebsiteData/cookies/localStorage/IndexedDB), zero residue in the bundle container after close. Verify script `scripts/verify_nonpersistent.py`. During verification two real crashes were found + fixed: `create` with `initial_url` calling `WKWebView.load` on a background queue (exit 133) → main-thread async; `close` calling AppKit `destroy()` on a background queue (exit 133) → main-thread sync + release the queue lock before teardown (avoids main↔sessionmgr lock inversion)
- P4-2 jetsam/RSS self-restart (new code): `FBMemoryWatchdog` periodically samples host-process RSS (`mach_task_basic_info.resident_size`), one-shot breach triggers a recovery closure (drain all sessions or exit for external supervisor restart); one-shot arm/disarm prevents repeated drain, re-arms after recovery; pluggable sampler for unit testing (the RSS syscall runs under `swift test`); default off (`memoryWatchdog.enabled`). Scope note: guards host-side growth only (AXTree strings / JS inject buffers / session table); WebContent bloat is indirectly bounded by FR-08 quota. 6 deterministic unit tests
- P4-3 perf benchmark suite: `scripts/perf_bench.py` drives the release binary through a fixed load of scroll/screenshot/click (20 each), collects `execution_time_ms` to compute P50/P95/max, samples host RSS, computes AXTree markdown compression ratio (chars/node). Found + fixed CRITICAL: `evaluateJSSyncArgs` used `replacingOccurrences` replacing ALL `__ARG__` → in multi-arg scripts the first arg fills every slot, expectFp gets the nodeId, fingerprint never matches → EVERY click/type returns `node_stale`; switched to `range(of:)`+`replaceSubrange`, one arg per slot. Report `scripts/perf-report.json`
- P4-4 UMA coexistence baseline measured: `scripts/uma_coexist.py` 10 concurrent sessions × 100 actions (scroll/screenshot/click rotation), while firing inference requests at fusion-mlx; asserts host RSS delta < 150MB×10 quota, `fusion_mlx_model_memory_bytes` not monotonically rising, mlx keeps serving. Measured 100/100 actions ok, RSS delta 38MB, mlx memory delta 0, inference service normal. Report `scripts/uma-report.json`. This is PRD T1.5 measured landing
- P4-5 1000-action long-run no-leak: `scripts/longrun_leak.py` single session runs 1000 actions, samples RSS every 50, compares first-quartile vs last-quartile mean (30MB allocator-jitter tolerance). Measured 1000/1000 ok, RSS span 4.1MB, last-quartile mean not significantly higher than first → no monotonic leak. Report `scripts/longrun-report.json`

**Post-Phase-4 fix landed**
- Node-id format (commit `9b3405e`, 2026-08-27): wire/structured node ids are BARE `eN` (`interactive_nodes[].node_id`, `target_node_id`); the markdown reduction `ax_tree_markdown` shows `[@eN]` for LLM readability only. An LLM forwarding `@e1` verbatim hit a `__fbMap` miss → `node_stale`. `FBActionDriver.execute` now strips a leading `@` from `target_node_id` once before admit/resolve/JS, so both `e1` and `@e1` resolve. Callers SHOULD send bare `eN`. See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) §4.

**Rust core engine landed (PRD §4.3 module 5, T1.4 override)**
- Flag-gated parallel Rust path replicating the AXTree compiler (JSON decode → markdown reduction → wire nodes → audit). Crate `rust/fb-core/` (`crate-type = ["staticlib","rlib"]`, serde + serde_json, `panic = "unwind"` for `catch_unwind`). C-ABI FFI = `fb_core_compile` + `fb_core_free` + `fb_core_estimate_tokens` + `fb_core_version`; ownership is Rust-allocates/Rust-frees (`Box::into_raw`/`from_raw`), every export wrapped in `catch_unwind` → `FB_ERR_PANIC` (never crashes the host)
- SPM wiring: `BuildToolPlugin` `FBCoreRustBuilder` runs `cargo build --release` → stages `libfb_core.a` flat at `rust/fb-core/dist/`; cTarget `FBCoreRust` (committed `fb_core.h` + `module.modulemap`) provides `import FBCoreRust`; both the executable + test target link `-lfb_core`. Build always, link always, **call conditionally** — the staticlib compiles on every `swift build` (catches Rust drift early) but the Swift code only calls it when the flag is on
- Dispatch seam: `FBAXTreeExtractor.extract(webview:)` — after `mapping.install` (stays Swift either way), if `useRustCore` the markdown+nodes+audit come from `FBCoreBridge.compileJSON`; on nil (panic/decode fail) it degrades visibly + falls back to the Swift reducer. Default OFF → Swift path stays live
- Parity gate (zero regression): `rust/fb-core/tests/parity.json` (9 cases) shared by `cargo test` + `Tests/FusionBrowserTests/RustCoreParityTests.swift` (5 tests, calls the bridge directly, bypassing the flag, skips if staticlib absent). `swift test` = 99 green. Live smoke `scripts/parity_smoke.py` drives the release binary under two configs (useRustCore false vs true) on the same page → `ax_tree_markdown` byte-identical (verified len=595, 5 nodes incl. masked password + purged hidden link)
- Config key `useRustCore` (default `false`). Rust Worker Pool (PRD §4.2) LANDED — `FBCoreWorkerPool` (N=cores-2, floor 2) bounds parallel Rust compiles so a full FR-08 load (up to 16 sessions) cannot over-subscribe the CPU via the unbounded `DispatchQueue.global()` the ActionDriver watchdog uses. FIFO submit + `DispatchSemaphore` cap + per-task done semaphore; on enqueue/shutdown failure callers fall back to inline `FBCoreBridge.compileJSON` (pool is a perf guard, never correctness). FR-12 metrics: `rustpool.enqueued`/`active`/`completed`/`fallback` + `rustpool.compile` latency. `extract()` routes the Rust compile through `FBCoreWorkerPool.shared.compile`

**Not done (per roadmap)**
- T3.1 agent-studio full integration: cross-project, this side ships the contract doc + issue only, code lands in fusion-agent-studio (now landed upstream via PR #235; my tracking issue #237 closed as duplicate; #241 open for test-fidelity)

## Build / Test

```bash
cd /Users/dahai/fusion/fusion-browser
swift build                # debug (also runs cargo build --release via the FBCoreRustBuilder plugin)
swift build -c release     # release -> .build/release/fusion-browser
swift test --disable-sandbox   # 99 tests (--disable-sandbox REQUIRED: plugin runs cargo, writes the package tree)
swift test --disable-sandbox --filter CDPServerTests   # single test class
cargo test --manifest-path rust/fb-core/Cargo.toml     # Rust-side parity fixtures (separate stack, PRD L115)
```

Requires: macOS 14+, Xcode CLI Tools (verified Swift 6.3.3 / Xcode 26.6 / macOS 26.5 / arm64), Rust toolchain (`cargo`/`rustc`, arm64-apple-darwin) for the `rust/fb-core` staticlib.

> Note: WKWebView completion handlers depend on the main run loop; `swift test` has no main loop → `evaluateJSSync`/`screenshotSync` semaphores deadlock. So live WKWebView behavior (real AX walker, screenshot, real navigation) is NOT verified inside `swift test`; covered by deterministic unit tests (rule catalog/reducer/translator/codec) + the built binary + Python smoke client. See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) §4.

## Run

```bash
# Default socket /tmp/fusion-browser.sock, CDP off, no token (same-host UDS only; production MUST set a token)
.build/release/fusion-browser

# Config file (optional, ~/.fusion-browser/config.json, partial fields OK, missing fall back to default)
cat > ~/.fusion-browser/config.json <<'JSON'
{"socketPath":"/tmp/fusion-browser.sock","cdpEnabled":true,"cdpPort":9222,
 "authToken":"your-secret","allowedOrigins":["https://example.com"],"logLevel":"info"}
JSON
.build/release/fusion-browser
```

`logLevel`: debug/info/warn/error. Logs go to both `os_log` (Console.app, search `com.fusion.browser`) and stderr.

Config keys: `socketPath`, `cdpEnabled`, `cdpPort`, `authToken`, `logLevel`, `allowedOrigins` (EVALUATE origin whitelist, empty=no limit), `useRustCore` (PRD §4.3 module 5, default `false`; route the AXTree compile markdown+nodes+audit through the Rust core staticlib; on any FFI/decode failure the Rust path degrades visibly and falls back to the Swift reducer), `visualLocator` (T3.4 visual-grounding fallback, default off; enabling needs a VLM loaded in fusion-mlx first; sub-keys `endpoint`/`model`/`timeoutMs`/`enabled`), `memoryWatchdog` (P4-2 RSS self-restart, default off; sub-keys `enabled`/`sampleIntervalMs`/`thresholdMB`/`action`, action=`close_sessions`|`exit`), `guards` (FR-13 scheduling guards, sub-keys `maxActions`/`taskTimeoutMs`/`repeatActionBreak`/`rebuildDepthCap`).

P4-2 RSS self-restart enable example:
```json
{"memoryWatchdog":{"enabled":true,"sampleIntervalMs":30000,"thresholdMB":200,"action":"close_sessions"}}
```

## Verify Scripts (Phase 4)

| Script | Purpose | Output |
|--------|---------|--------|
| `scripts/verify_nonpersistent.py` | P4-1 FR-04 non-persistence (lsof + container residue) | terminal PASS/FAIL |
| `scripts/perf_bench.py` | P4-3 perf benchmark (scroll/screenshot/click latency + AXTree compression ratio) | `scripts/perf-report.json` |
| `scripts/uma_coexist.py` | P4-4 UMA coexistence (10 sessions×100 actions + mlx inference concurrent) | `scripts/uma-report.json` |
| `scripts/longrun_leak.py` | P4-5 1000-action long-run no-leak (RSS quartile comparison) | `scripts/longrun-report.json` |
| `scripts/parity_smoke.py` | Rust-core live parity (useRustCore false vs true, same page → byte-identical `ax_tree_markdown`) | terminal PASS/FAIL |

All drive the release binary (run after `swift build -c release`); live WKWebView is out of `swift test` scope.

Visual-grounding enable example (incremental `~/.fusion-browser/config.json`):
```json
{"visualLocator":{"endpoint":"http://127.0.0.1:11434","model":"mlx-community--Qwen2.5-VL-7B-Instruct-4bit","timeoutMs":30000,"enabled":true}}
```
Note: `model` must use the fusion-mlx registered ID (registry uses `--` not path `/`, e.g. `mlx-community--Qwen2.5-VL-7B-Instruct-4bit`), and that VLM must be loaded in fusion-mlx (`POST /v1/models/<id>/load`, admin Bearer).

## Client Protocol

Full wire reference: [`docs/PROTOCOL.md`](docs/PROTOCOL.md). Summary:

### UDS main path

1. Connect to `/tmp/fusion-browser.sock`
2. First frame MUST be auth: `{"type":"auth","token":"..."}`, success returns `{"type":"auth_ack","caps":95}`
3. Then send requests (length-prefixed `[u32 BE length][JSON]`):
   - create session: `{"type":"create_session","payload":{"mode":"headless","initial_url":null,"max_actions":null,"task_timeout_ms":null,"credential_domain":null}}`
   - execute action: `{"type":"execute","payload":{"session_id":"...","action":"click","target_node_id":"e1","payload_text":null,"trace_id":"..."}}`
   - close session: `{"type":"close","session_id":"..."}`
4. JSON keys are snake_case (aligned to the schema). `target_node_id` is BARE `eN` (not `@eN`).

Smoke client: `python3 scripts/smoke_client.py <token>` (default socket `/tmp/fusion-browser-smoke.sock`, needs a matching config).

### CDP compat layer (`:9222`, default off)

NOT real Chrome — a shim translating cowork `cdp_client.py`'s real CDP transport. cowork code is read-only; this layer aligns to its contract:

- HTTP discovery: `GET /json` (returns `[{id,type,title,url,webSocketDebuggerUrl}]` array), `GET /json/version`, `PUT /json/new?<url>`, `GET /json/close/<id>` (checks 200 only, no target split)
- WS upgrade: `ws://127.0.0.1:<port>/devtools/page/<targetId>`, no subprotocol, no auth header, frames ≤10MiB
- WS messages: `{id,method,params}` → `{id,result}` (caller reads nested: `Runtime.evaluate`→`result.result.value`, `Accessibility.getFullAXTree`→`result.nodes` (each with `backendNodeId`), `Page.captureScreenshot`→`result.data` (base64 PNG), `Page.navigate`→`result.frameId`, `DOM.getDocument`→`result.root.nodeId`, `DOM.querySelector`→`result.nodeId`, `DOM.resolveNode`→`result.object.objectId`)
- Supported domains: Page (navigate/captureScreenshot/handleJavaScriptDialog + frameNavigated/lifecycleEvent), Runtime (evaluate, non-whitelisted origin rejected + consoleAPICalled), Accessibility (getFullAXTree), Input (dispatchMouseEvent click elementFromPoint / dispatchKeyEvent Enter submit / insertText), Network (requestWillBeSent/responseReceived/loadingFinished), DOM (getDocument/querySelector/resolveNode/focus/setFileInputFiles), Emulation (no-op placeholder); Performance/HeapProfiler/Tracing are no-op or minimal. Events carry NO `id` (per spec); cowork `_dispatch_event` buffers Network.*/Runtime.consoleAPICalled
- Auth: the CDP layer does NOT token-gate (cowork `Authorization: Bearer` is optional on `/json` only); security is the EVALUATE origin whitelist + UDS token on the main path

## Source Structure

| File | Responsibility |
|------|----------------|
| `main.swift` | entry, wires config→infra→server, runs the NSApplication run loop; starts `FBCDPServer` when `cdpEnabled` |
| `Logging.swift` | os_log + stderr sink, leveled logging |
| `ErrorModel.swift` | FR-11 structured error-code enum + `FBResult` |
| `Protocol.swift` | schema Swift Codable mapping + length-prefixed framing (snake_case codec) |
| `Auth.swift` | FR-10 token auth + capability + EVALUATE origin whitelist |
| `Config.swift` | FR-08 resource quota (by RAM) + FR-13 scheduling guards + watchdog policy + P4-2 `memoryWatchdog` config + config loading |
| `MemoryWatchdog.swift` | P4-2 process-level RSS monitor (`mach_task_basic_info` sampling) + one-shot breach recovery closure + pluggable sampler |
| `Observability.swift` | FR-12 metrics + trace_id + credential audit log |
| `Framing.swift` | FR-09 frame reader (multi-frame split + over-limit backpressure drop) |
| `Session.swift` | session state machine + scheduler (admit/canRebuild/idempotent classify) |
| `Credentials.swift` | FR-05/T2.4 Keychain credential custody (stores full cookie attributes, lock-screen detect) |
| `AXWalker.swift` | T2.1 injected JS walker script + stable mapping (structural fingerprint/WeakRef) + FBExtractedNode/Result |
| `AXTree.swift` | T2.1 extractor (extract→parse→install mapping→Markdown reduction) + T2.2 sanitizer rule catalog/purge policy + reducer |
| `WebView.swift` | FR-04/06 WKWebView wrapper (Headless offscreen / Headed window, non-persistent dataStore) + `evaluateJSSync`/`screenshotSync` (off-main semaphore) + full cookie-attribute injection |
| `SessionManager.swift` | FR-04/08 session lifecycle + quota enforcement (main-thread WKWebView creation) + `firstSession` (CDP shim target mapping) |
| `ActionDriver.swift` | FR-06 action dispatch + NFR-R tiered watchdog + crash-rebuild replay policy + EVALUATE origin check + node-id normalize (strip leading @) + T3.4 click node_stale visual fallback |
| `UDSServer.swift` | FR-09/10 POSIX socket UDS server + per-client read loop + auth routing |
| `CDPServer.swift` | T2.3/T3.3 CDP-WS shim: POSIX TCP + HTTP discovery + WS upgrade + frame codec + `FBCDPTranslator` (CDP method→ActionDriver, extended Network/Console/Emulation/Page.lifecycleEvent/DOM) + `FBCDPEventEmitter` (events decoupled, deterministic unit-testable) |
| `VisualLocator.swift` | T3.4 visual-grounding fallback: screenshot→fusion-mlx VLM `/v1/chat/completions` predicts `{x,y}` + OOB guards; pluggable `FBHTTPClient` |
| `FBCoreBridge.swift` | PRD §4.3 module 5 Rust-core FFI bridge: `compile`/`compileJSON` (markdown+nodes+audit) + `version` + `estimateTokens`; Rust-alloc/Rust-free ownership, copies Rust buffer to Swift `Data` before `fb_core_free` (never `bytesNoCopy`); nil on panic/decode fail → caller falls back to Swift |
| `FBCoreWorkerPool.swift` | PRD §4.2 Rust Worker Pool: bounds parallel Rust compiles (N=cores-2, floor 2) via `DispatchSemaphore` over a concurrent queue; on enqueue/shutdown failure falls back to inline `FBCoreBridge.compileJSON` (perf guard, never correctness); FR-12 metrics `rustpool.enqueued`/`active`/`completed`/`fallback` + `rustpool.compile` latency |
| `Sources/FBCoreRust/` | cTarget: committed `include/fb_core.h` (C-ABI contract) + `module.modulemap` + `fb_core_stubs.c` anchor; `import FBCoreRust` gated by `#if canImport(FBCoreRust)` |
| `Plugins/FBCoreRustBuilder/` | `BuildToolPlugin`: runs `cargo build --release`, stages `libfb_core.a` flat to `rust/fb-core/dist/`; inputs = `Cargo.toml` + `src/**` so SPM only re-runs cargo on Rust-source change |
| `rust/fb-core/` | Rust crate `fb_core` (`staticlib`+`rlib`, serde + serde_json, `panic = "unwind"`): `compile.rs` (decode→markdown+nodes+audit) + `markdown.rs` (byte-exact reducer) + `token.rs` (estimate_tokens) + `tests/parity.json` (9-case shared fixture) |

## Roadmap (see PRD §4)

- Phase 1 (base): engine base + six infra modules + action passthrough + tiered watchdog ✓
- Phase 2: AXTree extractor + anti-injection sanitizer + CDP compat layer (4 domains) + credential closure ✓
- Phase 3: multi-node adaptation (T3.2) + CDP domain extension + events (T3.3) + visual-grounding fallback (T3.4) ✓; agent-studio full integration (T3.1) cross-project, landed upstream
- Phase 4 (production-hardening): non-persistence verification (P4-1, FR-04) + RSS self-restart (P4-2) + perf benchmark suite (P4-3) + UMA coexistence baseline (P4-4, PRD T1.5) + 1000-action long-run no-leak (P4-5) ✓
- Rust core engine (PRD §4.3 module 5, T1.4 override): flag-gated `fb_core` staticlib + C-ABI FFI + `FBCoreBridge` + `FBCoreWorkerPool` (PRD §4.2, bounded parallel compiles), parity-gated (cargo test + `RustCoreParityTests` + live smoke), default OFF ✓
