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
issue only on this side, code lands in fusion-agent-studio. Build green, 89 tests
pass, end-to-end UDS smoke pass, CDP `:9222` smoke pass, T3.4 verified via real VLM
smoke, Phase 4 all verified via release binary + Python verify scripts
(`scripts/verify_nonpersistent.py` / `perf_bench.py` / `uma_coexist.py` /
`longrun_leak.py` → reports in `scripts/*-report.json`).
Source lives in `Sources/FusionBrowser/`, tests in `Tests/FusionBrowserTests/`.

Authoritative spec: `architecture/fusion-browser-prd-0826.md` (v2.0). Audit:
`audit/fusion-browser-audit-0826.md`. This project's `README.md` documents the
landed scope, source map, and protocol shape in detail.

## Build / Test / Run

```bash
cd /Users/dahai/fusion/fusion-browser
swift build -c release     # binary -> .build/release/fusion-browser
swift test                 # 89 tests, asyncio not used here (pure Swift)
swift test --filter CDPServerTests
.build/release/fusion-browser
```

No venv / Python needed for build (Swift only). The Python `scripts/` are verify
harnesses (smoke_client / perf_bench / uma_coexist / longrun_leak /
verify_nonpersistent), not part of the build.

**WKWebView cannot run under `swift test`** — no main run loop means
`evaluateJSSync`/`screenshotSync` semaphores deadlock (completion handlers dispatch
to main, which never spins). Live webview behavior (real AX walker, screenshot,
navigation) is verified via the built binary + Python smoke client, NOT `swift test`.
`swift test` holds deterministic unit tests only (rule catalogs, reducer, translator,
codec, Keychain, credential surface). Do not add live-WKWebView assertions to the
test target — they will hang the suite.

Config (optional): `~/.fusion-browser/config.json` — partial JSON OK, missing
fields fall back to `FBEngineConfig.default`. Keys: `socketPath`, `cdpEnabled`,
`cdpPort`, `authToken`, `logLevel` (debug/info/warn/error), `allowedOrigins`,
`visualLocator` (T3.4 visual-grounding fallback, default OFF — sub-keys
`endpoint`/`model`/`timeoutMs`/`enabled`; when enabled the VLM must be loaded in
fusion-mlx first; `model` is the registered ID with `--` not `/`, e.g.
`mlx-community--Qwen2.5-VL-7B-Instruct-4bit`), `memoryWatchdog` (P4-2 RSS
self-heal, default OFF — sub-keys `enabled`/`sampleIntervalMs`/`thresholdMB`/
`action` where action=`close_sessions`|`exit`; samples host RSS via
`mach_task_basic_info.resident_size`, one-shot breach fires drain-all-sessions
or exit-for-supervisor-restart), `guards` (FR-13 scheduling guards, default
`maxActions=200`/`taskTimeoutMs=300000`/`repeatActionBreak=3`/`rebuildDepthCap=1`).

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
- `Framing.swift` — FR-09 frame reader, overflow backpressure
- `Auth.swift` — FR-10 token + capabilities, EVALUATE origin whitelist
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
  DOM.setFileInputFiles, Emulation (no-op). The CDP layer does NOT token-gate;
  security is EVALUATE origin whitelist + UDS token. Default off (`cdpEnabled`);
  enable in config only when cowork needs it.
- **CDP events are decoupled into `FBCDPEventEmitter`** (T3.3). Event emission
  was originally inline in `FBCDPConnection` tied to the live socket + webview;
  that made it untestable (Page.navigate triggers live WKWebView → `swift test`
  deadlock). The emitter takes a `send: (String) -> Void` closure, holds the
  domain-enable flags, and pushes events with NO `id` (per CDP spec; cowork's
  `_dispatch_event` buffers Network.*/Runtime.consoleAPICalled). Test it with a
  `CaptureBox` reference wrapper — a value-type `var` captured by a closure
  snapshots BEFORE the append, so the caller sees empty (hard-won fix).
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
- **`create` with `initial_url` and `close` MUST run AppKit ops on main.**
  `WKWebView.load` in `create` and `stopLoading`/`removeFromSuperview`/`hostWindow.close`
  in `close` trap (exit 133) when called off the sessionmgr background queue.
  `create` wraps the navigate in `DispatchQueue.main.async`; `FBSession.close`
  dispatches `destroy()` to main via `DispatchQueue.main.sync`. `manager.close`
  extracts the session under the queue lock FIRST, then tears down the webview on
  main WITHOUT holding the queue lock (avoids main↔sessionmgr lock inversion).
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
