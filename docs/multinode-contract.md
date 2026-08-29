# Multi-node Capacity Contract (H-9 / R-10)

fusion-browser is a **non-persistent single-node** WKWebView automation engine (FR-04).
This document is the contract an **external scheduler** (fusion-gateway) consumes to
do cross-node browser-session placement. The scheduler itself lands in fusion-gateway
(audit R-10 改法: "跨节点调度/迁移落地可能在 fusion-gateway，本侧出契约+issue");
this side exposes the capacity plane only.

## The capacity query

UDS request, **auth-gated like every UDS op** (FR-10/H-5 fail-closed): the client MUST
send an auth frame and receive `auth_ack` before any request frame, or the node returns
`auth_denied`. The scheduler (fusion-gateway) must hold each node's `authToken` and send
`{type:"auth", token:<nodeToken>}` on each per-call dial — fusion-browser closes the
connection after one request-response, so there is no pooled authenticated session;
re-auth on every dial. After auth, capability-gated behind `.metrics` (read-only resource
info; an operator exposing metrics already exposes resource shape — reusing the cap, no
new cap minted). "System caller (no per-client owner needed)" means the B-5/E-34 session-
ownership check is bypassed for this read-only query — it does NOT mean auth is skipped.

```jsonc
// auth handshake — REQUIRED first frame on every dial (before any request)
// request:  { "type": "auth", "token": "<node authToken>" }
// response: { "type": "auth_ack" }
//   any other response, incl. {type:"error",payload:{code:"auth_denied"}}, = stop
// request frame (length-prefixed JSON, snake_case) — only after auth_ack
{ "type": "capacity" }

// response frame
{ "type": "capacity", "payload": {
    "node_id": "3C99667C-F28F-4028-8576-0BBD174EDEF6",
    "max_sessions": 16,
    "live_sessions": 1,
    "max_total_memory_mb": 2400,
    "free_memory_mb": 94796,
    "ram_gb": 128
}}
```

| field | meaning | source |
|---|---|---|
| `node_id` | one UUID minted per engine process (NOT persisted) | `FBNodeCapacity.processNodeId` |
| `max_sessions` | session cap from FR-08 RAM tiering (8GB→4, 16GB→10, ≥32GB→16) | `FBResourceQuota.forHost` |
| `live_sessions` | current live session count (under queue lock) | `manager.capacity()` |
| `max_total_memory_mb` | `max_sessions * 150MB` | quota |
| `free_memory_mb` | conservative floor: `physmem - active - wired` (mach HOST_VM_INFO) | `freeMemoryMB()` |
| `ram_gb` | physical RAM | `physicalRAMGB()` |

## Placement contract (scheduler side — fusion-gateway)

1. **Read**: on each known node, dial the UDS, send the **auth frame first**
   (`{type:"auth", token:<nodeToken>}`, expect `auth_ack`), THEN query
   `{type:"capacity"}`. The node's `authToken` is operator-configured per node; the
   scheduler must be configured with each node's token (a node with a token it does not
   know cannot be polled — fail-closed). Without the auth frame the node returns
   `auth_denied` and the node is NOT polled.
2. **Pick**: choose a node with headroom — `live_sessions < max_sessions` AND
   `free_memory_mb` adequate. Prefer most-free-memory for headroom; fall back to
   fewest-live-sessions when `free_memory_mb == 0` (probe failure — treat as unknown,
   never fabricate).
3. **Route**: send the `create_session` to the chosen node's UDS socket.
4. **Track**: a session lives on ONE node for its lifetime (no live migration here).

## What this side does NOT do (gateway-side, out of scope)

- **No migration.** A session is pinned to the node that created it. Node-jetsam
  session migration (evict + recreate on another node) is a gateway responsibility.
- **No oversubscription control across nodes.** The per-node `max_sessions` cap is
  enforced locally; cross-node aggregate limits are gateway-side.
- **No sticky node identity across restarts.** `node_id` is a fresh UUID per process.
  A restarted node is a NEW node identity — the scheduler MUST NOT assume `node_id`
  is stable across restarts. A scheduler's placement session can cache the id for
  one engine lifetime; on reconnect it re-queries.

## Known limitations (documented, not fixed here)

- **Single-node jetsam has no migration.** If a node hits its memory ceiling, the
  P4-2 RSS watchdog drains/closes sessions IN PLACE (no move to another node). The
  gateway can detect a node going down (socket gone / capacity drops) and re-route
  NEW creates elsewhere, but IN-FLIGHT sessions on the dead node are lost — the
  caller (fusion-cowork) must retry on a fresh node. This is the honest
  non-persistent-engine contract.
- **`free_memory_mb` is a conservative floor.** It backs out active+wired only
  (inactive/reclaimable omitted — not guaranteed reclaimable under pressure). The
  reported free is NEVER an optimistic upper bound; oversubscription is worse than
  leaving headroom on the table.

## Evidence

- **Deterministic (hard gate)**: `Tests/FusionBrowserTests/NodeCapacityTests.swift`
  — 6 tests: builder fills fields, nodeId stable within process, liveSessions
  threaded, freeMemoryMB within physmem + non-negative, Codable round-trip
  (snake_case wire keys), manager.capacity() reports live count.
- **Live (informational)**: `scripts/multinode_smoke.py` — starts 3 release binaries
  (each own socket + config via `FUSION_BROWSER_CONFIG` env), creates a session on
  each, queries `{type:"capacity"}` per node. Asserts 3 DISTINCT nodeIds +
  per-node live count 0→1. Writes `scripts/multinode-report.json`.
- **CI**: `multinode_smoke.py` is informational in `scripts/release_gate.sh`
  (multi-process harnesses can be resource-flaky; the capacity UNIT tests are the
  deterministic hard gate).

## Cross-project issue

fusion-gateway cross-node scheduling + migration: tracked in fusion-gateway
(issue → PR → landed code, per monorepo rule). This contract doc is the input;
the gateway implementation consumes `{type:"capacity"}` for placement.

> **Auth-handshake defect (2026-08-30, filed).** fusion-gateway PR #131 (issue #130)
> landed the scheduler + proxy but its `NodeClient` dials and sends the request frame
> WITHOUT the required auth handshake, and `BrowserNodeConfig` carries no node token.
> Against a real fusion-browser node every op returns `auth_denied` → the poll marks
> the node dead → the registry is empty → `POST /v1/browser/sessions` returns 503.
> The gateway's offline `fakenode` tests did not model auth, so CI stayed green while
> the live path is broken. Fix (fusion-gateway-side): add `token` to
> `BrowserNodeConfig`, send `{type:"auth",token}` + await `auth_ack` before each
> request on the per-call dial (create/execute/close/capacity/metrics all need it).
> This contract doc was corrected on 2026-08-30 to state the auth prerequisite
> (the earlier draft omitted it, which is what misled the gateway implementation).
