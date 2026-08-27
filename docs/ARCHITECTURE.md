# Architecture

> fusion-browser — macOS native controlled browser engine.
> Doc version: Phase 4 + Rust core (2026-08-27). Authoritative spec: `~/fusion/architecture/fusion-browser-prd-0826.md` (v2.0).

## 1. Overview

fusion-browser is a macOS native controlled browser engine providing Web visual +
structured interaction for `fusion-agent-studio`, with CDP-automation reuse for
`fusion-cowork`. Built on macOS native WebKit (WKWebView), dual protocol stack
(UDS length-prefixed JSON main path + CDP-over-WS compatibility layer), with six
built-in infrastructure modules plus a flag-gated **Rust core compile module**
(PRD §4.3 module 5) that re-derives the AXTree markdown/nodes/audit over a C-ABI
FFI; default off, the Swift reducer stays the live path.

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
caller's next-step decision. Inside `extract`, after `mapping.install` (always
Swift — Rust does not own the JS WeakRef mapping), if `useRustCore` is set the
markdown+nodes+audit are re-derived by the Rust core over FFI
(`FBCoreBridge.compileJSON`); on any FFI/decode failure it degrades visibly and
falls back to the Swift reducer. See §8.

## 4. Six Infra Modules

Each a single file (see source map in `README.md`):

| Module | File | Responsibility |
|--------|------|----------------|
| Config | `Config.swift` | FR-08 quota by RAM, FR-13 scheduling guards, watchdog policy, `memoryWatchdog` + `visualLocator` config |
| Framing | `Framing.swift` | FR-09 frame reader, multi-frame split, overflow backpressure drop |
| Auth | `Auth.swift` | FR-10 token + capabilities, EVALUATE origin whitelist |
| ErrorModel | `ErrorModel.swift` | FR-11 structured `{code,message,retryable}` + `FBResult` |
| Observability | `Observability.swift` | FR-12 metrics + trace_id + credential audit log |
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

## 8. Rust Core Engine (FFI, PRD §4.3 module 5)

A flag-gated parallel compile path that re-derives the AXTree markdown + wire
nodes + audit from the walker JSON over a C-ABI FFI. **Default OFF**
(`useRustCore`); the Swift `FBAXTreeReducer` stays the live path. The staticlib
is built + linked on every `swift build` (early Rust-drift detection), but only
*called* when the flag is on. The Rust Worker Pool (PRD §4.2) is LANDED:
`FBCoreWorkerPool` (N=cores-2, floor 2) bounds parallel Rust compiles so a full
FR-08 load (up to 16 sessions) cannot over-subscribe the CPU via the unbounded
`DispatchQueue.global()` the ActionDriver watchdog uses. `extract()` routes the
Rust compile through `FBCoreWorkerPool.shared.compile`; on pool fail/shutdown it
falls back to inline `FBCoreBridge.compileJSON` (pool = perf guard, never
correctness). FR-12 metrics: `rustpool.enqueued`/`active`/`completed`/`fallback`
+ `rustpool.compile` latency.

**FFI contract (authoritative, `rust/fb-core/src/lib.rs`):**
- `fb_core_compile(in, in_len, &out, &out_len) -> i32` — decode walker JSON,
  emit one combined JSON `{markdown, nodes:[...], audit:{...}}`; `FB_OK` /
  `FB_ERR_DECODE` / `FB_ERR_PANIC`.
- `fb_core_free(ptr, len)` — release the Rust-allocated output buffer (must be
  called exactly once per `compile` success).
- `fb_core_estimate_tokens(md, md_len) -> u32` — local token heuristic
  (observability/benchmark consumer, not on the live path).
- `fb_core_version() -> i32` — ABI version (startup log sanity).

**Ownership = Rust-allocates / Rust-frees** (`Box::into_raw`/`from_raw` via
`into_boxed_slice`). Symmetric alloc/free avoids crossing the allocator
boundary. Every export is wrapped in `catch_unwind` → `FB_ERR_PANIC` so a Rust
panic never crashes the Swift host (`panic = "unwind"` is mandatory — do NOT set
`panic = "abort"`).

**Swift bridge (`FBCoreBridge.swift`):** `compile` copies the Rust buffer into a
Swift-owned `Data` and calls `fb_core_free` immediately (NEVER
`Data(bytesNoCopy:)` — that defers free past lifetime and races allocators),
then decodes `{markdown, nodes, audit}` into Swift types. `compileJSON` returns
nil on any failure → `extract()` logs + falls back to the Swift reducer.

**SPM wiring:** `BuildToolPlugin` `FBCoreRustBuilder` runs
`cargo build --release`, stages `libfb_core.a` flat at `rust/fb-core/dist/`; the
cTarget `FBCoreRust` (committed `fb_core.h` + `module.modulemap`) provides
`import FBCoreRust`; both the executable and the test target link `-lfb_core`.
`--disable-sandbox` is REQUIRED for build/test — the plugin writes the package
tree, which the sandbox denies.

**Parity gate (zero regression):** `rust/fb-core/tests/parity.json` (9 cases)
is shared by `cargo test` (Rust side) and
`Tests/FusionBrowserTests/RustCoreParityTests.swift` (5 tests, call the bridge
directly, bypassing the flag, skip if the staticlib is absent). The Rust
markdown must be byte-exact vs the Swift reducer (curly quotes U+201C/U+201D
around name, `[@eN]` prefix, sorted `hiddenFlags` keys + optional
`render:hidden`). Live smoke `scripts/parity_smoke.py` drives the release
binary under two configs (useRustCore false vs true) on the same page and
asserts `ax_tree_markdown` byte-identical.

**Worker pool (`FBCoreWorkerPool.swift`, PRD §4.2):** the Rust `fb_core_compile`
is pure stateless FFI (no statics, no locks, fresh alloc per call), so it is
already safe under concurrent calls — the pool adds **bounded concurrency**, not
parallelism the FFI lacked. Each `extract()` runs on an ActionDriver watchdog
block dispatched to `DispatchQueue.global()` (unbounded), so under a full FR-08
load (up to 16 sessions) up to 16 Rust compiles could contend for CPU. The pool
caps parallel compiles at N=cores-2 (floor 2) via a `DispatchSemaphore`: a caller
submits to a concurrent queue, a worker `wait()`s the semaphore, runs the
compile inline on its thread, `signal()`s, and wakes the caller's per-task done
semaphore. Strict FIFO is NOT preserved (GCD picks the next queued block), but
each caller waits only on its own result, so order does not affect correctness.
On enqueue/shutdown failure the caller falls back to a synchronous inline
compile (the pre-pool path) — the pool is a performance guard, never a
correctness dependency. `shutdownPool()`/`resetForTest()` support test isolation.
