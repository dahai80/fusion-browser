# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current State

**Phase 4 production-hardening landed (2026-08-26).** Swift 6 SPM package, macOS 14+
native. Phase 1 engine base + six infra modules (FR-08~13) + action driver with
tiered watchdog + UDS server; Phase 2 adds AXTree extractor (T2.1) + anti-injection
sanitizer (T2.2) + CDP-over-WS compat layer (T2.3) + credential closure (T2.4);
Phase 3 adds multi-node RAM-tiered quota (T3.2) + CDP domain extension & event
emitter (T3.3) + visual-grounding fallback via fusion-mlx VLM (T3.4); Phase 4 adds
FR-04 non-persistence verification (P4-1) + RSS watchdog/OOM self-heal (P4-2) +
perf benchmark suite (P4-3) + UMA coexistence baseline (P4-4, PRD T1.5) + 1000-action
long-run no-leak (P4-5). T3.1 (agent-studio 对接) is cross-project: contract doc +
issue only on this side, code lands in fusion-agent-studio. Build green, 198 tests
pass, end-to-end UDS smoke pass, CDP `:9222` smoke pass, T3.4 verified via real VLM
smoke, Phase 4 all verified via release binary + Python verify scripts
(`scripts/verify_nonpersistent.py` / `perf_bench.py` / `uma_coexist.py` /
`longrun_leak.py` / `metrics_smoke.py` → reports in `scripts/*-report.json`).
Source lives in `Sources/FusionBrowser/`, tests in `Tests/FusionBrowserTests/`.

Authoritative spec: `architecture/fusion-browser-prd-0826.md` (v2.0). Audit:
`audit/fusion-browser-audit-0826.md`. This project's `README.md` documents the
landed scope, source map, and protocol shape in detail.

## Build / Test / Run

```bash
cd /Users/dahai/fusion/fusion-browser
swift build -c release     # binary -> .build/release/fusion-browser (pure Swift, no plugin)
swift test --disable-sandbox   # 198 tests (--disable-sandbox no longer required:
                               #  plugin gone; kept for compatibility)
swift test --disable-sandbox --filter CDPServerTests
.build/release/fusion-browser
```

No venv / Python needed for build (pure Swift). E-17~20 (#68): the Rust core was
removed — PRD §2 T1.4 evaluation concluded pure Swift (`FBAXTreeReducer` +
`JSONDecoder`) covers Sanitizer+AXTree, so the `FBCoreRustBuilder` plugin, the
`FBCoreRust` target, the `rust/` tree, and the `useRustCore` config key were
deleted (the staticlib was default OFF + never the live path). No Rust toolchain
needed; `--disable-sandbox` was mandatory only because the plugin ran `cargo` and
is now no longer required (kept on the gate lines for compatibility). The Python
`scripts/` are verify harnesses (smoke_client / perf_bench / uma_coexist /
longrun_leak / verify_nonpersistent), not part of the build.

**WKWebView cannot run under `swift test`** — no main run loop means
`evaluateJSSync`/`screenshotSync` semaphores deadlock (completion handlers dispatch
to main, which never spins). Live webview behavior (real AX walker, screenshot,
navigation) is verified via the built binary + Python smoke client, NOT `swift test`.
`swift test` holds deterministic unit tests only (rule catalogs, reducer, translator,
codec, Keychain, credential surface). Do not add live-WKWebView assertions to the
test target — they will hang the suite.

Config (optional): `~/.fusion-browser/config.json` — partial JSON OK, missing
fields fall back to `FBEngineConfig.default`. Keys: `socketPath`, `cdpEnabled`,
`cdpPort`, `authToken`, `logLevel` (debug/info/warn/error), `allowedOrigins`
(FAIL-CLOSED per E-15 — an empty list denies EVALUATE, CDP `Page.navigate`,
and the CDP WS upgrade; only local schemes `data:`/`about:`/`blob:` navigate
freely),
`tokenCapabilities` (E-9/H-5, default empty → `.default` — a string list that
elevates the registered token's capabilities, e.g. `["evaluate"]` or `["all"]`.
The default token lacks `.evaluate` (H-5 scoped-token model), so without this
key the UDS/CDP evaluate action is cap-gated off (`evaluate_denied` / `.authDenied`).
R-3/B-3 added `.metrics` (read-only engine metrics) — also NOT in `.default`; set
`["metrics"]` (or `["all"]`) to make the UDS `{type:"metrics"}` request and CDP
`Performance.getMetrics` return real counters + latency quantiles (p50/p95).
Without it the metrics read path is cap-gated off (`.authDenied`); CDP
`Performance.getMetrics` is Bearer-gated at the WS upgrade, not per-method.
Parsed by `FBAuth.parseCaps`: names case-insensitive, match `FBCapabilities`
members; "all" → `.all`; unknown names dropped fail-closed (never broaden)),
`visualLocator` (T3.4 visual-grounding fallback, default OFF — sub-keys
`endpoint`/`model`/`timeoutMs`/`enabled`; when enabled the VLM must be loaded in
fusion-mlx first; `model` is the registered ID with `--` not `/`, e.g.
`mlx-community--Qwen2.5-VL-7B-Instruct-4bit`), `memoryWatchdog` (P4-2 RSS
self-heal, default OFF — sub-keys `enabled`/`sampleIntervalMs`/`thresholdMB`/
`action` where action=`close_sessions`|`exit`; samples host RSS via
`mach_task_basic_info.resident_size`, one-shot breach fires drain-all-sessions
or exit-for-supervisor-restart), `guards` (FR-13 scheduling guards, default
`maxActions=200`/`taskTimeoutMs=300000`/`repeatActionBreak=3`/`rebuildDepthCap=1`).
B-5/E-34: session ownership is AUTOMATIC — no config key. Every UDS connection
mints a UUID owner id at init; `create` records it, `execute`/`close` verify it
(`not_owner` on mismatch). System callers (nil owner) bypass. E-35 in-flight
batch cap (`maxBatch=64`) is also fixed, not configurable — a fairness guard.
E-23: `rebuildDepth` counts ONLY real replays — `handleCrash` checks `isIdempotent`
FIRST and calls `scheduler.canRebuild()` (which increments) only on the idempotent
replay branch; a non-idempotent crash (navigate/click/type/evaluate) fails directly
without consuming the cap, so two slow-page click timeouts no longer brick the session.

## Architecture

Two-layer: **UDS server** (POSIX socket + per-client `DispatchSourceRead`, token
auth, length-prefixed JSON framing aligned to a Protobuf schema) drives a
**session manager** owning per-session `WKWebView` instances. Phase 2 adds a
**CDP-over-WS compat layer** (`FBCDPServer` on `:9222`, default off) that
translates cowork's real-CDP transport into `FBActionDriver` actions + AXTree
extraction — it is a shim, not real Chrome.

Wire codec = length-prefixed JSON (`[u32 BE len][JSON]`, snake_case keys). Schema
types in `Protocol.swift` are the stable contract — D12 (gRPC over UDS) is a
future codec swap, not a schema change. CDP `:9222` is live, default off
(`cdpEnabled`); cowork `cdp_client.py` is the read-only contract source.

Request flow: `FBUDSServer` → `FBClientConnection` (auth-gates first frame) →
`FBRequest` route → `FBSessionManager.create` (quota check + main-thread WKWebView
creation + credential inject) / `FBActionDriver.execute` (capability check +
EVALUATE origin check + tiered watchdog + crash rebuild of idempotent actions
only) / `close`.

The six infra modules (each a single file, see README source map):
- `Config.swift` — FR-08 quota by RAM, FR-13 scheduling guards, watchdog policy
- `Framing.swift` — FR-09 frame reader, overflow backpressure + B-4 partial-frame arrival timeout
- `Auth.swift` — FR-10 token + capabilities, EVALUATE origin whitelist
- `UDSServer.swift` — B-5/E-34 per-connection owner id (UUID) + E-35 per-client in-flight batch cap
- `ErrorModel.swift` — FR-11 structured `{code,message,retryable}`
- `Observability.swift` — FR-12 metrics + trace_id + credential audit log
- `Session.swift` — scheduler: admit / repeat-break / rebuild-depth-cap / idempotent

## Critical Implementation Constraints

- **WKWebView & NSWindow must be created on the main thread.** `SessionManager.create`
  dispatches to `DispatchQueue.main.sync` when off-main. Violating hangs forever.
- **Client connections must be strongly retained.** `ObjectIdentifier` keys in a
  `Set` do NOT retain — store the object itself in `[ObjectIdentifier: FBClientConnection]`
  or the `DispatchSourceRead` handler never fires. (Hard-won fix.)
- **AF_UNIX accept: use POSIX `socket/bind/listen/accept` + `DispatchSourceRead`,
  NOT `NWListener`.** `NWListener`'s `newConnectionHandler` never fires for
  AF_UNIX sockets (confirmed via repro). This is why `UDSServer.swift` is POSIX.
- **Non-blocking client fd + EAGAIN handling** so one slow client can't block the
  shared accept queue.
- **B-5/E-34 session ownership: every UDS connection mints a UUID `ownerId` at init
  (NOT the reusable fd).** `create` records it on the session; `execute` and
  `close` route through the owner-aware `manager.get(_:ownerId:)` /
  `manager.close(sessionId:ownerId:)` and deny a mismatch with `not_owner`
  (distinct from `session_not_found` so callers can audit "not yours" vs "gone").
  System callers pass `ownerId: nil` and BYPASS ownership — this is load-bearing:
  `manager.close(sessionId:)` (main teardown), the idle reaper, CDP `ensureSession`,
  and the existing test helpers all pass the default nil owner, so they must bypass
  or teardown breaks. The deny check is `if let owner = s.ownerId, let caller =
  ownerId, owner != caller` — denies ONLY when BOTH the session has an owner AND
  the caller is non-nil AND they differ. CDP's single-tenant shim leaves owner nil
  (no per-client isolation). Live-pinned by `scripts/ownership_smoke.py` (two
  connections: B's execute+close on A's session → `not_owner`; A keeps full control).
- **B-5/E-35 per-client in-flight batch cap: `onReadable` processes at most
  `maxBatch=64` frames per read.** A 64KB recv can carry ~2000 small frames; without
  the cap that queues 2000 blocking `driver.execute` on main in one burst. Excess
  complete frames buffer in `pendingFrames` and drain on the next readable event
  (DispatchSourceRead is level-triggered — a still-pending buffer re-fires
  `onReadable`) plus a `queue.async` re-arm for the remainder: lossless, no frame
  dropped, just spread across reads instead of monopolizing main. `splitBatch` is a
  pure static (`inout [Data]`, max) so the bound is unit-testable without a live
  socket. `FBError.busy` exists for a hard-deny variant but the live path uses the
  lossless defer (the cap is a fairness guard, not a rejection).
- **WKWebView completion handlers dispatch to main; never sync-wait on main.**
  `evaluateJSSync`/`screenshotSync` guard `Thread.isMainThread == false` and block
  a background semaphore — calling on main deadlocks (and `swift test` has no main
  run loop at all, so live-webview tests hang there; keep them out of the target).
- **CryptoKit SHA1 is in the `Insecure` namespace:** `Insecure.SHA1.hash(data:)`,
  not `SHA1`/`CryptoKit.SHA1`. Used for the RFC 6455 Sec-WebSocket-Accept in
  `CDPServer.swift`. Plain `SHA1` fails to compile.
- **CDP is a translation shim, not real Chrome.** `FBCDPServer` (`:9222`, default
  off) translates cowork `cdp_client.py`'s real-CDP transport (HTTP `/json`
  discovery + WS `{id,method,params}` JSON-RPC) into `FBActionDriver` actions +
  AXTree extraction. Contract: callers read nested results —
  `Runtime.evaluate`→`result.result.value`, `Accessibility.getFullAXTree`→`result.nodes`
  (each with `backendNodeId`), `Page.captureScreenshot`→`result.data` (base64 PNG),
  `Page.navigate`→`result.frameId`, `DOM.getDocument`→`result.root.nodeId`,
  `DOM.resolveNode`→`result.object.objectId`. T3.3 extended domains:
  Network (requestWillBeSent/responseReceived/loadingFinished), Runtime
  consoleAPICalled, Page.frameNavigated + lifecycleEvent, DOM.focus /
  DOM.setFileInputFiles, Emulation (no-op). The CDP layer DOES Bearer-gate since
  H-5 (HTTP `/json` + WS upgrade require `Authorization: Bearer <token>`,
  fail-closed), and the origin gate is strict since E-15: WS upgrade, CDP
  `Page.navigate`, and `PUT /json/new?<url>` all deny on an empty Origin header
  or an empty `allowedOrigins` list (fail-closed, consistent with EVALUATE);
  local schemes `data:`/`about:` still navigate. Default off (`cdpEnabled`).
  NOTE: cowork's CDP client omits the Origin header and ships an empty allowlist
  by default, so under strict E-15 its WS upgrade + remote navigate are DENIED —
  cowork must send an allowlisted Origin + configure `allowedOrigins` to use CDP.
  This is a deliberate cross-project contract change (issue → PR in fusion-cowork).
- **CDP events are decoupled into `FBCDPEventEmitter`** (T3.3). Event emission
  was originally inline in `FBCDPConnection` tied to the live socket + webview;
  that made it untestable (Page.navigate triggers live WKWebView → `swift test`
  deadlock). The emitter takes a `send: (String) -> Void` closure, holds the
  domain-enable flags, and pushes events with NO `id` (per CDP spec; cowork's
  `_dispatch_event` buffers Network.*/Runtime.consoleAPICalled). Test it with a
  `CaptureBox` reference wrapper — a value-type `var` captured by a closure
  snapshots BEFORE the append, so the caller sees empty (hard-won fix).
  **E-11 (#67) resolution:** `pushConsoleEvents` was dead code (defined, never
  called) — wired: `FBCDPConnection.drainConsoleEvents` reads `window.__fbConsole`
  (the console shim buffer installed in `WebView.swift`) via `evaluateJSSync` after
  navigate + after `Runtime.evaluate` and drains it into
  `Runtime.consoleAPICalled` events. Nav event order fixed to real-Chrome
  (`Network.requestWillBeSent → responseReceived → loadingFinished` then
  `Page.frameNavigated → DOMContentLoaded → load`; was inverted). `loaderId`/
  `requestId` now per-nav (`fb-loader-<seq>`/`fb-req-<seq>`, was constants);
  `frameId` stays constant per frame (real-Chrome semantics).
  `Network.responseReceived` now reports the REAL status captured by a new
  `WKNavigationDelegate.decidePolicyFor navigationResponse` on FBWebView
  (`lastResponse`, NSLock-guarded, cleared on nav start + destroy); was hardcoded
  `200`. status `0` when no response captured (local schemes, no session).
  Subresource responses still unknown (WKWebView hides them; only the main-document
  response is captured) — documented limitation, cowork's navigate is main-document
  only. Events emit in one synchronous burst after load completion (the shim cannot
  stream during load; `executeAction` blocks to didFinish, so the response is
  already captured). cowork buffers Network+console raw, no field-level reader —
  these are contract-honesty fixes, no cowork runtime-behavior change. Live-pinned
  by `scripts/cdp_event_smoke.py` (403 status surfaces as 403, console.log wired,
  real-Chrome order, per-nav loaderId; R-7 hard gate).
- **T3.4 visual fallback is best-effort, never primary.** `FBVisualLocator`
  fires ONLY on click `node_stale`. It screenshots via `screenshotSync` (WKSnapshot
  PNG, not CoreGraphics — headless offscreen webview isn't on a CoreGraphics
  display), derives a description from the stale node's role+name, calls
  fusion-mlx `/v1/chat/completions` with a base64 data-URI image, and parses
  `{x,y}`. OOB + negative guards reject VLM hallucination past the viewport.
  Pluggable `FBHTTPClient` protocol makes `predict`/`parseCoord`/`buildRequestBody`
  unit-testable with a fake client; the real VLM load is integration-only (start
  fusion-mlx, load a VLM via `POST /v1/models/<id>/load` with admin Bearer, run a
  smoke). Default OFF (`visualLocator.enabled`) — needs a VLM loaded to be useful.
  `model` is the fusion-mlx registered ID using `--` separators, not HF `/`.
- **Credentials never leave Keychain/in-memory in plaintext.** `CreateSessionResponse`
  carries only `credentialInjected: Bool`; full cookie attrs (name/value/domain/
  path/expires/secure/httponly/samesite) live in Keychain (account=domain) and the
  session's in-memory `httpCookieStore`. `type=password` input values are masked to
  `********` in AXTree markdown. Credential audit log records op/result only, never
  the value. Locked screen → `credential_locked`.
- **`evaluateJSSyncArgs` replaces ONE `__ARG__` placeholder per arg, in order** —
  uses `range(of: "__ARG__")` + `replaceSubrange`. Do NOT switch to
  `replacingOccurrences(of: "__ARG__", with:)` (replaces ALL occurrences per arg):
  with multi-arg scripts (resolveClick gets `id` then `expectFp`) the first arg
  fills every placeholder, starves the rest, so `expectFp` gets the nodeId →
  fingerprint never matches → EVERY click/type returns `node_stale`. This was the
  most severe Phase 4-found bug; it broke the entire click+type contract.
- **`create` with `initial_url`, `close`, AND execute navigate MUST run AppKit
  ops on main.** `WKWebView.load` traps (exit 133) off-main. `create` wraps the
  navigate in `DispatchQueue.main.async`; `FBSession.close` dispatches
  `destroy()` to main via `DispatchQueue.main.sync`; `manager.close` extracts
  the session under the queue lock FIRST, then tears down the webview on main
  WITHOUT holding the queue lock (avoids main↔sessionmgr lock inversion).
  Execute navigate hits the SAME trap: `ActionDriver.dispatch` runs inside the
  `runWithWatchdog` block on `DispatchQueue.global()`, so `WebView.navigate`
  must main-hop `wv.load` when off-main (sync semaphore wait; never sync-wait
  ON main). Covers UDS + CDP — both route through `runWithWatchdog`. Verified
  via `scripts/navigate_execute_smoke.py` (create WITHOUT initial_url, then
  execute navigate).
- **E-17~20 (#68) resolution: Rust core removed.** PRD §2 T1.4 evaluation
  concluded pure Swift (`FBAXTreeReducer` + `JSONDecoder`) covers Sanitizer+
  AXTree; the Rust path was default OFF and never the live path. Removed
  `FBCoreBridge` / `FBCoreWorkerPool` / `FBCoreRust` target / `FBCoreRustBuilder`
  plugin / `rust/` tree / `useRustCore` config key / `RustCoreParityTests` /
  `parity_smoke.py`. The `FBAXTreeExtractor.extract` seam is now pure Swift:
  `mapping.install` (always Swift) + `FBAXTreeReducer.toMarkdown` +
  `SecurityAuditResult` — the same path the Rust core degraded to on failure.
  `--disable-sandbox` no longer required (no plugin runs cargo; kept on gate
  lines for compatibility). Wire schema + AXTree output unchanged; cowork
  unaffected. See `docs/ARCHITECTURE.md` §8.
- **`FBMemoryWatchdog` guards host-side RSS only, not WebContent.** It samples
  `mach_task_basic_info.resident_size` (host process, excludes the separate
  WebContent procs bounded by FR-08 quota). One-shot breach: fires `onBreach` once,
  disarms, re-arms only after RSS recovers below threshold (prevents repeated drain).
  Pluggable sampler makes `tick()`/`shouldTrigger` unit-testable without a live
  timer; the RSS syscall itself runs under `swift test`. Default OFF
  (`memoryWatchdog.enabled`).
- **FR-13 repeat-action-break rejects 3+ consecutive identical action keys.** The
  admit key is `"\(action):\(target):\(payload)"`; hammering the same `click:e1:`
  trips the guard on the 3rd (by design — stuck-loop protection). Verify scripts
  rotate distinct click targets (and exclude links whose `href` navigates the page
  away, making all subsequent clicks on that session stale). `__fbMap` is empty
  until the first extract, so the first click on a session needs a prior
  screenshot/extract warmup or it goes `node_stale`.
- **E-9 Runtime.evaluate returns the real JS result, not a synthetic `"ok"`.**
  `ActionDriver`'s `.evaluate` case captures `evaluateJSSync`'s return (a
  Foundation JSON-deserialized value: NSString/NSNumber/NSNull/NSArray/NSDictionary),
  JSON-encodes it with `.fragmentsAllowed` (bare top-level values — NOT the
  default `.withoutEscapingSlashes`-style object-only path) into
  `BrowserStateResponse.evaluateResult: String?`. CDP `handleEvaluate` mirrors
  this through `cdpRemoteObject` (NSNull→`undefined`, Bool→`boolean`,
  NSNumber→`number`, String→`string`, array/dict→`object`). void/undefined →
  nil (no field). The default token lacks `.evaluate` (H-5 scoped-token
  model) → elevate via the `tokenCapabilities` config key (`["all"]`/`["evaluate"]`),
  else UDS/CDP evaluate is cap-gated off. `evaluateJSSyncArgs` replaces ONE
  `__ARG__` per arg IN ORDER (range+replaceSubrange) — do NOT switch to
  `replacingOccurrences(of:)` (replaces ALL per arg, starves later args).
- **E-8 CDP DOM domain derefs real elements via a per-connection registry.** The
  5 `DOM.*` methods route through ONE persistent `FBCDPTranslator` per
  `FBCDPConnection` (minted at WS upgrade, reused for every frame — NOT a fresh
  translator per message, which would wipe the registry between `getFullAXTree`
  and the later `resolveNode`/`focus`/`getBoxModel` and break both cowork
  flows). The registry (`intToIdStr` / `objectIdToIdStr` / `idStrToSelector`,
  `NSLock`-guarded on `FBCDPTranslator`) bridges CDP handles (integer
  `nodeId`/`backendNodeId`, opaque `objectId`) to the walker's idStr (`"eN"`
  from `getFullAXTree`/`getDocument`, `"qN"` from `querySelector`). All derefs
  go through one JS resolver `window.__fbMap.get(idStr)`. `getFullAXTree` +
  `getDocument` call `registerIdStr` for every observed `eN` (else
  `resolveNode(backendNodeId)` finds an empty registry → no objectId).
  `querySelector` mints a `qN` id, registers the match in `__fbMap` under it,
  AND stores `selector→idStr` in `idStrToSelector` for a re-query fallback
  (the walker rebuilds `__fbMap` fresh each extract, dropping `qN` entries —
  `buildBoxModelJS`/`buildFocusJS` re-`querySelector` the stored selector when
  the `WeakRef` is gone). The JS builders return BARE JS OBJECTS
  (`{ok:true,...}`), NOT `JSON.stringify(...)` — E-9 made `.evaluate`
  JSON-encode the deserialized JS return, so a `JSON.stringify` here
  double-encodes (`"{\"ok\":...}"`) and the handler's `[String:Any]` decode
  fails → silent `nodeId:0`. The `querySelector` IIFE arg must be the FULL
  `jsStr(selector)` (with quotes), not the unwrapped inner — `})(#u);` is a JS
  syntax error (bare `#u`), throws → no result. `getBoxModel` returns the REAL
  `getBoundingClientRect` quad (8 coords, TL→TR→BR→BL), not the old 1280×800
  stub; stale/missing → `-32000 node stale` (honest, E-13 cross-extract
  stability is #66). `resolveNode` returns a registered `"fb-obj-<seq>"`
  objectId, not the old unregistered `"fb-node-N"`. E-8 guarantees a handle
  derefs against the CURRENT `__fbMap` only; a SPA re-render between
  `getFullAXTree` and the click is E-13 (#66), not E-8. Live-verified by
  `scripts/cdp_dom_smoke.py` (both cowork flows over CDP WS; R-7 hard gate).
- **E-13 (#66) `backendNodeId` stability — option (b), document as order-based.**
  `backendNodeId` is a DOCUMENT-ORDER POSITION (1-based Nth interactive node in
  `getFullAXTree`), stable only for static pages. SPA reorders shift it —
  `backendNodeId:5` after a re-render derefs the CURRENT 5th node, not the
  snapshotted element (honest order-based identity). Tree-shrink fail-closes
  (`-32000 node stale` when the idStr is absent from the fresh `__fbMap`).
  `handleResolveNode` re-extracts + re-registers observed `eN` before minting an
  objectId (self-priming, mirrors `handleGetDocument` — it was the only DOM
  handler that did not extract+register). Cross-extract handle reuse is
  UNSUPPORTED: callers MUST re-fetch `getFullAXTree` before acting on a reordered
  page. `intToIdStr[N]→"eN"` is a pure identity (`stableNodeId` reversible),
  never stale; `"eN"` is rebound to the current Nth element each extract. A
  fingerprint-based stable id (option a) was rejected: the existing `fingerprint`
  embeds sibling indices via `docPath` (order-bound), and making it order-free
  risks wrong-element clicks on attr-less siblings for no cowork benefit
  (cowork treats handles as single-use — no cross-action cache, so E-13 is not
  a failure mode cowork triggers). Live-pinned by `scripts/cdp_dom_smoke.py`
  Flow C (reorder between getFullAXTree and resolveNode → resolves current Nth,
  NOT the snapshotted element).

## Downstream Consumer

`fusion-cowork` is the primary consumer of the automation surface. Phase 2 ships
the CDP-over-WS compat layer (`FBCDPServer` on `:9222`) that `fusion-cowork`'s
`CDPClient` (`cdp_client.py`) expects, alongside UDS. When modifying the wire
schema (`Protocol.swift`), action contract (`ActionDriver.swift`), or CDP method
mapping (`CDPServer.swift`'s `FBCDPTranslator.dispatch`), check `fusion-cowork`'s
browser node code for matching changes. `fusion-cowork` is READ-ONLY per monorepo
rule — contract changes go issue → PR → landed code in that order.

## Monorepo Context

One of ~27 `fusion-*` sub-projects under `/Users/dahai/fusion`. Authoritative
monorepo guide: `/Users/dahai/fusion/CLAUDE.md` (env setup, fusion-mlx inference
engine at `localhost:11434`, architecture layers, "一核九端" overview).

Per monorepo rules: only modify code in this project's own directory; upstream
issues go to `architecture/` and the owning project first, then a PR; all code
uses 4-space indentation, no docstrings, and always includes logging.
