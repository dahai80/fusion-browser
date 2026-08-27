# Development Guide

> fusion-browser — contributor conventions and hard constraints.
> Doc version: Phase 4 (2026-08-27).

## 1. Build / Test / Run

```bash
cd /Users/dahai/fusion/fusion-browser
swift build -c release          # binary -> .build/release/fusion-browser
swift test                      # full suite (deterministic unit tests only)
swift test --filter CDPServerTests   # single test class
swift test --filter AXTreeTests/StableMappingTests   # single test method
.build/release/fusion-browser   # run engine (UDS server, CDP off by default)
```

No venv / Python needed for build (pure Swift). Python `scripts/` are verify
harnesses (smoke_client, perf_bench, uma_coexist, longrun_leak,
verify_nonpersistent), NOT part of the build.

## 2. Coding Conventions

- **Swift 6**, SPM, macOS 14+. Match existing file style — do not introduce a
  second pattern (two patterns is worse than one, even if the new one is better).
- **4-space indentation (multiples of 4)** — never 2/5/9/11 spaces.
- **No docstrings.** Comments are fine where they explain non-obvious WHY;
  document what code cannot say on its own. Do not narrate what code already says.
- **Always include logging.** Use `FBLog` / the module logger (`log.info`,
  `log.warn`, `log.error`) with `traceId` + `sessionId` context for
  triage. Silent failure is a bug.
- **Fail visibly.** Throw / return `FBError` with a real `code` + `message`;
  never swallow. A test that passes for the wrong reason is worse than no test.
- **Surgical changes.** Touch only what the task requires. Do not "improve"
  adjacent code, reformat, or refactor what is not broken (Rule 3).

## 3. Critical Implementation Constraints

These are hard-won, load-bearing. Violating them hangs or crashes the engine.

- **WKWebView & NSWindow MUST be created on the main thread.** `SessionManager.create`
  dispatches to `DispatchQueue.main.sync` when off-main. Violating hangs forever.
- **Client connections MUST be strongly retained.** Store the `FBClientConnection`
  object itself in `[ObjectIdentifier: FBClientConnection]`, NOT an
  `ObjectIdentifier` in a `Set` — a Set does not retain, so the
  `DispatchSourceRead` handler never fires.
- **AF_UNIX accept: use POSIX `socket/bind/listen/accept` + `DispatchSourceRead`,
  NOT `NWListener`.** `NWListener.newConnectionHandler` never fires for AF_UNIX
  sockets (confirmed via repro). This is why `UDSServer.swift` is POSIX.
- **Non-blocking client fd + EAGAIN handling** so one slow client cannot block the
  shared accept queue.
- **WKWebView completion handlers dispatch to main; never sync-wait on main.**
  `evaluateJSSync`/`screenshotSync` guard `Thread.isMainThread == false` and block
  a background semaphore. Calling them on main deadlocks.
- **`create` with `initial_url` and `close` MUST run AppKit ops on main.**
  `create` wraps the navigate in `DispatchQueue.main.async`; `FBSession.close`
  dispatches `destroy()` to main via `DispatchQueue.main.sync`. `manager.close`
  extracts the session under the queue lock FIRST, then tears down the webview on
  main WITHOUT holding the queue lock (avoids main↔sessionmgr lock inversion).
- **CryptoKit SHA1 is in the `Insecure` namespace:** `Insecure.SHA1.hash(data:)`,
  not `SHA1`/`CryptoKit.SHA1`. Used for the RFC 6455 Sec-WebSocket-Accept in
  `CDPServer.swift`. Plain `SHA1` fails to compile.
- **`evaluateJSSyncArgs` replaces ONE `__ARG__` placeholder per arg, in order**
  (`range(of:)` + `replaceSubrange`). Do NOT switch to
  `replacingOccurrences(of: "__ARG__", with:)` (replaces ALL occurrences per arg):
  with multi-arg scripts the first arg fills every placeholder and starves the
  rest, so the fingerprint never matches → EVERY click/type returns `node_stale`.

## 4. Testing Boundaries

- **WKWebView cannot run under `swift test`** — no main run loop means
  `evaluateJSSync`/`screenshotSync` semaphores deadlock (completion handlers
  dispatch to main, which never spins). Live webview behavior (real AX walker,
  screenshot, navigation) is verified via the built binary + Python smoke client,
  NOT `swift test`.
- **`swift test` holds deterministic unit tests only:** rule catalogs, reducer,
  translator, codec, Keychain, credential surface, event emitter, stable mapping.
- **Do NOT add live-WKWebView assertions to the test target** — they will hang
  the suite. New tests that need a webview go in the Python verify harnesses.
- **Verify scripts** (`scripts/verify_nonpersistent.py`, `perf_bench.py`,
  `uma_coexist.py`, `longrun_leak.py`) run against the release binary and write
  `scripts/*-report.json` (gitignored). Run them for integration verification;
  clean up process data after, keep only final outputs + logs.
- **Test fidelity matters.** A mock that emits a shape the real engine never
  produces gives false confidence. Mocks MUST match the real wire schema (e.g.
  bare `eN` node ids, not `@eN`) — see `docs/PROTOCOL.md` §4.

## 5. Adding a New Action

A new action touches several points — keep them in sync:

1. **`ActionType` enum** (`Protocol.swift`) — add the case. Wire key is
   `convertToSnakeCase` of the raw value (e.g. `typeText` → `type_text`).
2. **Capability bit** (`Auth.swift`) — add `1<<N` to the bitmask; update
   `default` (95) and `all` (127) token sets only if the action should be gated.
3. **`ActionDriver.execute` switch** (`ActionDriver.swift`) — implement the case;
   admit via the scheduler, run on the right thread, end with an AXTree re-extract
   so the state response carries fresh `ax_tree_markdown` + `interactive_nodes`.
4. **Scheduler idempotent classify** (`Session.swift`) — mark whether the action
   is idempotent (eligible for crash-rebuild) or not.
5. **CDP mapping** (`CDPServer.swift` `FBCDPTranslator.dispatch`) — if cowork
   needs it, add the CDP method → action translation + result field.
6. **Contract doc** (`architecture/agent-studio-integration-contract-0826.md`)
   and `docs/PROTOCOL.md` §3.3 — document the action, payload, and result shape.
7. **Tests** — deterministic codec/translator test in the test target; live
   behavior in a Python verify harness (NOT `swift test`).

## 6. Schema / Wire Changes

- **`Protocol.swift` types are the STABLE contract.** Wire shape = Swift type +
  snake_case codec (`convertToSnakeCase` / `convertFromSnakeCase`). Adding an
  optional field is backward-compatible; renaming or removing a field is a
  breaking change — bump and coordinate with consumers first.
- **D12 (gRPC over UDS) is a future CODEC swap, NOT a schema change.** The schema
  types stay; only the bytes-on-wire encoding changes. Do not conflate the two.
- **Check the downstream consumer before changing the schema or action contract.**
  `fusion-cowork` (`cdp_client.py`) and `fusion-agent-studio`
  (`tools/browser_tools.py`) consume the surface. They are READ-ONLY per the
  monorepo rule — contract changes go issue → PR → landed code in that order.
- **Node-id format is load-bearing** (see `docs/PROTOCOL.md` §4): wire/structured
  is BARE `eN`; markdown shows `[@eN]`. Do not change either representation
  without updating both + the strip in `ActionDriver.execute`.

## 7. Cross-Project Rules

- **Only modify code in this project's own directory** (`/Users/dahai/fusion/fusion-browser`).
  Do not edit `fusion-cowork`, `fusion-agent-studio`, `fusion-mlx`, `fusion-gateway`,
  or `fusion-studio` source.
- **Upstream problems follow issue → PR → landed code.** File an issue in the
  owning repo first (English for GitHub), then a PR, then land the code. Do not
  fork the fix into this repo.
- **`fusion-cowork` and `fusion-agent-studio` are READ-ONLY** — read them to
  verify contract compatibility, never edit.
- **GitHub operations default to English** (issue titles, bodies, PR descriptions,
  commit messages on the remote).
- **LLM testing loads the real model.** Start/stop fusion-mlx via
  `~/claude-home/fusion-mlx/start.sh start|stop`; download models through the
  mirror `https://hf-mirror.com`. Do not mock the model.

## 8. Doc Maintenance

- **Bilingual READMEs:** `README.md` is English (default), `README_CN.md` is
  Chinese. Keep them in sync — a content change goes in both.
- **`docs/`** holds `ARCHITECTURE.md`, `PROTOCOL.md`, `DEVELOPMENT.md`. Update the
  relevant doc alongside the code change that motivates it.
- **`architecture/agent-studio-integration-contract-0826.md`** is the consumer
  contract — update it when the wire schema or action contract changes.
- **Keep the test count and landed fixes current** in `README.md` /
  `README_CN.md` (e.g. node-id bare `eN` fix, test count). Stale numbers erode
  trust faster than no number.
- **Clean up process data after verification** — keep only final outputs + logs.
  `scripts/*-report.json` is gitignored; do not commit transient run artifacts.
