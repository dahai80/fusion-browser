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

## System-caller proxy bypass (R-10 — the per-call-dial ownership gap)

The gateway is a **system/proxy caller** that mediates all its clients and dials a
**fresh UDS connection per op** (per-call dial, no pooled conn — see client.go). Every
other fusion-browser caller keeps ONE UDS connection for its lifetime, so the E-34
per-connection `ownerId` (UUID minted at init) is stable across create/execute/close.
The gateway's per-call dial breaks that: create's connection is ownerId=A, execute
re-dials → ownerId=B → `not_owner` (503, session owned by another client).

fusion-browser's E-34 ownership **intentionally bypasses** for a system caller
(`ownerId == nil`) — that is how the CDP path already works (`CDPServer.ensureSession`
creates with nil owner). The UDS path had no way to reach it. R-10 adds one:

- **Operator config** `tokenSystemCaller: true` (`~/.fusion-browser/config.json` /
  `FUSION_BROWSER_CONFIG`) designates the node's `authToken` as a system-caller token.
- On auth success, `FBAuth.isSystemCaller(token:)` checks the token hash + the flag; if
  true, the UDS connection sets `ownerId=nil` for create/execute/close → SessionManager
  bypasses E-34 (deny only when session-owner AND caller both non-nil AND differ).
- **Fail-closed**: flag absent / `false` → never system. A normal token never bypasses
  ownership; client-to-client isolation is untouched. The flag is OPERATOR CONFIG, not
  client-supplied — a client only sends the token it was given; it cannot self-elevate.
- **Orthogonal to caps**: a system caller still needs its action caps
  (`tokenCapabilities: ["all"]`) to drive sessions. Do not conflate ownership with
  action permission.
- **Trusted-proxy token only**: `tokenSystemCaller: true` bypasses client isolation.
  Set it ONLY for the gateway's per-node token, never a per-client token. The gateway
  is the single trusted proxy mediating all clients, so this is correct for R-10's
  architecture.

Without this flag, a per-call-dial proxy gets `not_owner` on every execute that
follows a create on a different dial. This is the fusion-browser-side fix for the gap
R-10 live verification surfaced; it is NOT the gateway #132 auth defect (that is
separate, see the note below).

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

> **Auth-handshake defect — RESOLVED (2026-08-30).** fusion-gateway PR #131 (issue #130)
> landed the scheduler + proxy but its `NodeClient` dials and sends the request frame
> WITHOUT the required auth handshake, and `BrowserNodeConfig` carries no node token.
> Against a real fusion-browser node every op returned `auth_denied` → the poll marked
> the node dead → the registry was empty → `POST /v1/browser/sessions` returned 503.
> The gateway's offline `fakenode` tests did not model auth, so CI stayed green while
> the live path was broken. Filed `dahai80/fusion-gateway#132`; **FIXED by PR #133**
> (commit `565fa5c`): `token` added to `BrowserNodeConfig`, `NodeClient.authenticate`
> sends `{type:"auth",token}` + asserts `auth_ack` on every per-call dial
> (create/execute/close/capacity/metrics). R-10 live verification
> (`scripts/verify_gateway_r10.py`) confirmed: no `auth_denied`, 201 creates served,
> scheduler distributes sessions across nodes with stable config-label pins.
>
> **Ownership gap — fusion-browser-side fix landed + verified (2026-08-30).** With #132
> fixed, the per-call-dial proxy then hit `not_owner` on execute (create's ownerId !=
> execute's ownerId — see the "System-caller proxy bypass" section above). fusion-browser
> added the `tokenSystemCaller` operator config so a designated proxy token bypasses E-34
> ownership (mirrors the CDP nil-owner path). The harness config sets
> `tokenSystemCaller: true` per node. **Re-verified end-to-end** by
> `scripts/verify_gateway_r10.py` → PASS: 3 creates distributed across 2 nodes, proxied
> screenshot returns a valid PNG, `report["ok"]==True`. The verification also surfaced and
> fixed a pre-existing crash (E-40): a `create` with no `initial_url` left the WKWebView
> blank → WebContent idled into ProcessThrottler suspension → the first screenshot raced
> the suspend IPC → SIGTRAP exit 133; `create` now loads a minimal blank `data:` document
> so WebContent never idles. This closes the last R-10 gap end-to-end.
>
> **Gateway admin-route defect (2026-08-30, RESOLVED — fusion-gateway PR #138).** The
> browser admin routes `/v1/browser/nodes` + `/v1/browser/metrics` use `withAdminOnly`
> which checked `middleware.IsAdmin` BEFORE the auth middleware ran, so an admin-login
> JWT populated `admin.AdminClaims` but NOT `middleware.Principal` → 403. Fixed upstream:
> `bridgeAdminJWT` now validates the admin Bearer once and sets
> `Principal{Role:RoleAdmin, AuthMethod:"admin-jwt"}` before the `IsAdmin` check, with
> `APIKeyAuth`/`RBAC` short-circuiting on that auth method. Verified live: admin Bearer →
> `/v1/browser/nodes` 200; negatives (no/garbage/non-admin-role Bearer) → 403. Squash-merged
> `14feaab`, branch `fix/admin-only-jwt-bridge` deleted. The verification harness below
> (`verify_gateway_r10.py`) now treats a non-200 admin node-map as a real FAILURE, not
> advisory — the defect is gone. Does not affect the UDS auth contract on this side.
