# Architecture

> fusion-browser — macOS native controlled browser engine.
> Doc version: Phase 4 (2026-08-27); Rust core removed E-17~20 (#68). Authoritative spec: `~/fusion/architecture/fusion-browser-prd-0826.md` (v2.0).

## 1. Overview

fusion-browser is a macOS native controlled browser engine providing Web visual +
structured interaction for `fusion-agent-studio`, with CDP-automation reuse for
`fusion-cowork`. Built on macOS native WebKit (WKWebView), dual protocol stack
(UDS length-prefixed JSON main path + CDP-over-WS compatibility layer), with six
built-in infrastructure modules. (E-17~20 / #68: a flag-gated Rust core compile
module that re-derived the AXTree markdown/nodes/audit over a C-ABI FFI was
removed — PRD §2 T1.4 evaluation concluded pure Swift covers it; the Swift
reducer was always the default + fallback path.)

**Two layers:**
- **UDS server** — POSIX socket + per-client `DispatchSourceRead`, token auth,
  length-prefixed JSON framing (snake_case keys, schema-aligned to a Protobuf
  contract).
- **Session manager** — owns per-session `WKWebView` instances; the action driver
  runs navigate/click/type/scroll/screenshot/evaluate against them.

A parallel **CDP-over-WS shim** (`FBCDPServer` on `:9222`, default off) translates
cowork's real-CDP transport into the same `FBActionDriver` actions + AXTree
extraction — it is a shim, not real Chrome.

## 2. Layer Diagram

```
   fusion-agent-studio              fusion-cowork
   (BrowserTool, UDS)               (CDPClient, :9222)
         │                               │
         │  length-prefixed JSON         │  HTTP /json + WS {id,method,params}
         ▼                               ▼
   ┌─────────────────┐           ┌──────────────────┐
   │  FBUDSServer    │           │  FBCDPServer     │  (shim, default off)
   │  (AF_UNIX)      │           │  (TCP + WS)      │
   │  auth + route   │           │  FBCDPTranslator │
   └────────┬────────┘           └────────┬─────────┘
            │   FBRequest                 │  translated FBActionDriver calls
            └──────────────┬──────────────┘
                           ▼
                  ┌──────────────────┐
                  │ FBSessionManager │  quota check (FR-08) + main-thread create
                  │  per-session     │  credential inject (Keychain -> memory)
                  │  WKWebView       │
                  └────────┬─────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────────┐
        │FBAction  │ │FBAXTree  │ │FBVisual      │  (T3.4 fallback,
        │Driver    │ │Extractor │ │Locator       │   default off)
        │ watchdog │ │ sanitizer│ │ mlx VLM      │
        └────┬─────┘ └────┬─────┘ └──────────────┘
             │            │
             └─────┬──────┘
                   ▼
            WKWebView (headless offscreen / headed window)
            nonPersistent dataStore (FR-04 no disk)
```

## 3. Request Flow

UDS path (main):
```
FBUDSServer
  → FBClientConnection (auth-gates FIRST frame; strong-retained in [ObjectIdentifier: conn])
    → FBRequest route
      → SessionManager.create  : quota check (FR-08) + main-thread WKWebView
                                  creation + credential inject
      → ActionDriver.execute   : capability check (FR-10) + EVALUATE origin check
                                  + node-id normalize (strip leading @)
                                  + tiered watchdog (NFR-R) + crash rebuild
                                  (idempotent actions only)
      → close                  : extract session under queue lock, teardown webview
                                  on main WITHOUT holding lock (avoid lock inversion)
```

Each action ends with an AXTree re-extract (`FBAXTreeExtractor.extract`) so the
state response carries a fresh `ax_tree_markdown` + `interactive_nodes` for the
caller's next-step decision. Inside `extract`, `mapping.install` (Swift — owns
the JS WeakRef mapping) runs first, then `FBAXTreeReducer.toMarkdown` derives the
markdown+nodes+audit in pure Swift. (E-17~20 / #68: the Rust-core FFI branch was
removed; the Swift reducer was always the default + the fallback the Rust path
degraded to.)

## 4. Six Infra Modules

Each a single file (see source map in `README.md`):

| Module | File | Responsibility |
|--------|------|----------------|
| Config | `Config.swift` | FR-08 quota by RAM, FR-13 scheduling guards, watchdog policy, `memoryWatchdog` + `visualLocator` config |
| Framing | `Framing.swift` | FR-09 frame reader, multi-frame split, overflow backpressure drop |
| Auth | `Auth.swift` | FR-10 token + capabilities, EVALUATE origin whitelist |
| ErrorModel | `ErrorModel.swift` | FR-11 structured `{code,message,retryable}` + `FBResult` |
| Observability | `Observability.swift` | FR-12 metrics + trace_id + credential audit log. R-3/B-3: `metricsArray()` surfaces counters + latency p50/p95 via UDS `{type:"metrics"}` (`.metrics` cap, opt-in) + CDP `Performance.getMetrics` (was write-only / empty `[]`) |
| Session | `Session.swift` | scheduler: admit / repeat-break / rebuild-depth-cap / idempotent classify |

## 5. CDP-over-WS Shim Layer

`FBCDPServer` (`:9222`, default off) is a **translation shim, not real Chrome.**
It translates cowork `cdp_client.py`'s real-CDP transport into `FBActionDriver`
actions + AXTree extraction.

- HTTP discovery: `/json`, `/json/version`, `/json/new?<url>`, `/json/close/<id>`
- WS upgrade: `ws://127.0.0.1:<port>/devtools/page/<targetId>`, RFC 6455 framing
  (SHA1 Sec-WebSocket-Accept in `Insecure` namespace)
- `FBCDPTranslator.dispatch` maps CDP methods → actions; `FBCDPEventEmitter`
  (T3.3) pushes events with NO `id` (per spec), decoupled from live socket so
  it is unit-testable

Contract: callers read nested results —
`Runtime.evaluate`→`result.result.value`, `Accessibility.getFullAXTree`→`result.nodes`
(each with `backendNodeId`), `Page.captureScreenshot`→`result.data` (base64 PNG),
`Page.navigate`→`result.frameId`, `DOM.getDocument`→`result.root.nodeId`,
`DOM.resolveNode`→`result.object.objectId`.

CDP layer does NOT token-gate; security = EVALUATE origin whitelist + UDS token.

## 6. Visual Grounding Fallback

T3.4 visual fallback is **best-effort, never primary.** `FBVisualLocator` fires
ONLY on click `node_stale`:

```
click node_stale
  → screenshotSync (WKSnapshot PNG, not CoreGraphics — headless offscreen webview
                    isn't on a CoreGraphics display)
  → derive description from stale node's role+name
  → POST fusion-mlx /v1/chat/completions  (VLM reads image_url base64 data URI)
  → parse {x,y}
  → OOB + negative guards reject VLM hallucination past viewport
  → elementFromPoint(x,y).click()
```

Pluggable `FBHTTPClient` protocol makes `predict`/`parseCoord`/`buildRequestBody`
unit-testable with a fake client; real VLM load is integration-only. Default OFF
(`visualLocator.enabled`) — needs a VLM loaded in fusion-mlx to be useful. `model`
is the fusion-mlx registered ID using `--` separators, not HF `/`.

## 7. Memory & Lifecycle

- **FR-08 quota by RAM** — `FBResourcesQuota.forHost(ramGB:)` tiers session count /
  total memory by physical RAM (<8GB→2, 8-16GB→4, 16-32GB→10, ≥32GB→16),
  perSession=150MB, total=sessions×150. Over-quota `create` → `quota_exceeded`.
  Explicit RAM reload makes the tier table unit-testable.
- **FR-04 non-persistence** — `nonPersistent` dataStore isolates each session;
  verified zero on-disk residue (P4-1: lsof + container check, no WebsiteData /
  cookies / localStorage / IndexedDB held).
- **B-2 process-cap mechanism** — WebContent process count is bounded by the
  session cap (`quota.maxSessions`, enforced in `SessionManager.create`) + WebKit's
  built-in per-site process isolation, NOT a shared process pool. `WKProcessPool`
  was deprecated in macOS 12.0 ("creating and using multiple instances no longer
  has any effect") — the old `sharedPool` + `config.processPool` assignment was a
  no-op that never enforced a cap and was removed. The dead `maxWebContentProcesses`
  config field (set but read nowhere) was removed in H-2. `FBMemoryWatchdog` is the
  real memory backstop (host+WebContent RSS).
- **P4-2 RSS watchdog** — `FBMemoryWatchdog` samples host RSS
  (`mach_task_basic_info.resident_size`, host process — excludes separate
  WebContent procs bounded by FR-08). One-shot breach fires `onBreach` once,
  disarms, re-arms only after RSS recovers below threshold (prevents repeated
  drain). Default OFF. Pluggable sampler for unit test.
- **Main-thread constraints** — `WKWebView` & `NSWindow` MUST be created on main.
  `SessionManager.create` dispatches to `DispatchQueue.main.sync` when off-main.
  `create` with `initial_url` wraps navigate in `DispatchQueue.main.async`;
  `FBSession.close` dispatches `destroy()` to main. Violating hangs (exit 133).
- **Client connection retention** — store the `FBClientConnection` object itself
  in `[ObjectIdentifier: FBClientConnection]`, NOT just an `ObjectIdentifier` in
  a `Set` (a Set does not retain; the `DispatchSourceRead` handler never fires).

## 8. Rust Core Engine — REMOVED (E-17~20 / #68)

A flag-gated Rust core compile path (PRD §4.3 module 5, `useRustCore`, default
OFF) that re-derived the AXTree markdown + nodes + audit over a C-ABI FFI was
**removed** in the E-17~20 audit fix. PRD §2 task T1.4 required an evaluation of
whether pure Swift was sufficient before shipping Rust; that evaluation
concluded pure Swift (`FBAXTreeReducer.toMarkdown` + `JSONDecoder`) covers
Sanitizer+AXTree, and the Rust path was never the live path (it was default OFF
and the Swift reducer was the fallback it degraded to on any FFI/decode
failure).

Removal closed all four E-17~20 findings at once:
- **E-17** (build not portable: hardcoded arm64 triple, `PATH` drops rustup,
  absolute `-L`) — the `FBCoreRustBuilder` plugin + `rust/fb-core/` + absolute
  link paths deleted.
- **E-18** (worker pool not a dedicated FIFO worker) — `FBCoreWorkerPool`
  deleted.
- **E-19** (no runtime parity check, wrong bytes ship silently) —
  `RustCoreParityTests` + `scripts/parity_smoke.py` deleted; no Rust bytes to
  drift.
- **E-20** (`Cargo.lock` not in plugin inputs) — no plugin, no `Cargo.lock`.

Deleted files: `Sources/FusionBrowser/FBCoreBridge.swift`,
`Sources/FusionBrowser/FBCoreWorkerPool.swift`, `Sources/FBCoreRust/` (dir),
`Plugins/FBCoreRustBuilder/` (dir), `Tests/FusionBrowserTests/RustCoreParityTests.swift`,
`scripts/parity_smoke.py`, `rust/` (dir). The `useRustCore` config key was
dropped from `FBEngineConfig` (existing configs with the key ignore it —
Codable drops unknown keys).

The `FBAXTreeExtractor.extract` seam is now pure Swift: `mapping.install`
(owns the JS WeakRef mapping) → `FBAXTreeReducer.toMarkdown` →
`SecurityAuditResult`. Wire schema + AXTree output (markdown + nodes + audit)
are unchanged; `fusion-cowork` (UDS/CDP consumer, never the Rust core) is
unaffected. No Rust toolchain needed; `--disable-sandbox` was mandatory only
because the plugin ran `cargo` and is no longer required.

