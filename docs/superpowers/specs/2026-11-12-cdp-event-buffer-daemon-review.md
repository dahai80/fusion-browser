---
doc_id: fusion-browser/guide
product: fusion-browser
class: app
entry: service
doc_type: guide
title: { zh: "Design review: browser-use CDP event-buffer daemon pattern (ax.py) — adopt/adapt/reject", en: "Design review: browser-use CDP event-buffer daemon pattern (ax.py) — adopt/adapt/reject" }
audience: engineer
status: draft
version: 0.2.5
updated: 2026-11-12
owner: "@dahai"
source_of_truth:
  - docs/superpowers/specs/2026-11-12-cdp-event-buffer-daemon-review.md
issue: dahai80/fusion-browser#39
---

# Design review: CDP event-buffer daemon pattern vs fusion-browser

## Source pattern (browser-use 1.0.2, `browser_use/ax.py`)

A per-client daemon thread (`_watch`, 25 ms poll) drains a CDP event queue into
a bounded per-connection buffer (`deque(maxlen=EVENT_BUFFER)`) and maintains
incremental state (in-flight requests, nav errors, open dialogs). Agent clients
then QUERY state (`bu.state()`, `bu.click(id)`) instead of polling DOM
snapshots; events are replayed from the buffer to a reader thread. The REPL /
worker split (`repl/worker.py` + `repl/session.py`) is the process boundary.

Documented upstream limitation: the buffer is per-connection — several agents
sharing one daemon MISS events.

## Current fusion-browser contract (what the pattern would replace)

1. **Event emission is a burst, not a stream.** `FBCDPEventEmitter` (T3.3)
   fires ONE synchronous burst AFTER load completion (`executeAction` blocks to
   `didFinish`, then emits `Network.*` main-document → `Page.frameNavigated` →
   lifecycle events; console is drained post-hoc via the `window.__fbConsole`
   shim, E-11). The shim CANNOT stream during load — WKWebView gives no CDP
   stream to tap. There is no event existing before load completion, so a
   buffer/watch thread has nothing to buffer.
2. **AXTree is extract-on-demand, not replicated.** Clients poll
   `Accessibility.getFullAXTree` per action; handles are order-based and
   single-use (E-13 — callers MUST re-fetch after any reorder). An incremental
   a11y-state replica would duplicate what WKWebView's own AX walker already
   owns, with exactly the drift class E-13 exists to prevent.
3. **Multi-client isolation is enforced, not multiplexed.** UDS: E-34
   ownership — `execute`/`close` on another client's session → `not_owner`
   (live-pinned by `scripts/ownership_smoke.py`). CDP: single-tenant shim,
   `ensureSession` per connection — two connections get two sessions. There is
   no shared session and no shared event stream today, so the upstream
   "multiple agents miss events" failure mode is structurally absent.

## Verdict: REJECT (revisit under two named triggers)

**Why reject.** The pattern's value = replace polling with push-buffered
state during REAL streaming. Both preconditions are absent here: no streaming
event source exists (burst-after-load is the honest contract of a WKWebView
shim), and a11y state is already owned natively by the webview (extraction is
O(1)-ish and always fresh). Adopting a daemon buffer would add a thread, a
bounded queue, and a replay cursor around events that do not exist yet, plus a
second copy of AX state that E-13 makes hazardous.

**Trigger 1 — real CDP backend.** If the shim is ever replaced by a real
Chromium/CDP stream (D12 direction), revisit: a server-side ring buffer +
per-subscriber replay cursor, owned by the SESSION (not the connection), with
explicit `events.subscribe` / `events.replay(cursor)` methods. Never implicit
per-connection buffers.

**Trigger 2 — concurrent multi-agent sessions on one managed browser.** If
product demand lands for N agents sharing one managed browser session
(cowork DAG nodes, autotest), the fan-out contract MUST be defined and
landed BEFORE enabling concurrency: per-agent subscriptions with explicit
 acknowledgement of delivery, or broadcast with per-agent monotonic cursors.
Silent loss (the upstream limitation) is a rejected design, not an accepted
trade-off.

## Regression pin (landed with this review)

`CDPServerTests.testTwoConnectionsEventIsolation` (deterministic, no live
webview): two emitters stand in for two concurrent client connections.
Asserts: (a) events pushed on connection A are delivered exactly once to A and
zero times to B (no cross-connection bleed); (b) A connection that did NOT
enable a domain receives none of that domain's events (subscribe semantics —
no silent delivery); (c) a subscribed connection receives every pushed event of
its enabled domains (no silent loss within a subscription). The UDS-side
"two clients, one session" case is already pinned: `not_owner`
(`ownership_smoke.py` + E-34 unit tests).
