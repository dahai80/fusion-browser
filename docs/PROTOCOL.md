# Wire Protocol Reference

> fusion-browser UDS + CDP wire contract. Schema source of truth: `Sources/FusionBrowser/Protocol.swift`.
> Doc version: Phase 4 (2026-08-27). Contract for consumers: `architecture/agent-studio-integration-contract-0826.md`.

## 1. Framing

Every UDS frame is length-prefixed JSON:

```
[u32 big-endian length][JSON payload]
```

- JSON keys are **snake_case** (encoder uses `convertToSnakeCase`, decoder
  `convertFromSnakeCase`). Swift camelCase types (`targetNodeId`, `traceId`,
  `initialUrl`, `sessionId`) encode/decode as snake_case wire keys
  (`target_node_id`, `trace_id`, `initial_url`, `session_id`).
- Schema shape is STABLE: `Protocol.swift` types are the contract. D12 (gRPC
  over UDS) is a future codec swap, NOT a schema change.
- First frame MUST be `auth`; otherwise the connection is rejected.

## 2. UDS Message Envelopes

Request (`FBRequest`, discriminator `type`):
- `create_session` — `{type, payload: CreateSessionRequest}`
- `execute` — `{type, payload: BrowserActionRequest}`
- `close` — `{type, session_id}`

Response (`FBResponse`, discriminator `type`):
- `create_session` — `{type, payload: CreateSessionResponse}`
- `state` — `{type, payload: BrowserStateResponse}`
- `closed` — `{type, session_id}`
- `error` — `{type, payload: FBError}`

## 3. Message Types

### 3.1 auth / auth_ack

Request (first frame, immediately after connect):
```json
{"type": "auth", "token": "<shared-secret>"}
```
Response (success):
```json
{"type": "auth_ack", "caps": 95}
```
Failure: server closes the connection, no response. Token mismatch = reject.

### 3.2 create_session

Request:
```json
{"type": "create_session",
 "payload": {"mode": "headless",
             "initial_url": null,
             "max_actions": null,
             "task_timeout_ms": null,
             "credential_domain": null}}
```
- `mode`: `"headless"` (default) | `"headed"` (popup window, debug)
- `initial_url`: optional, navigate on create
- `max_actions` / `task_timeout_ms`: optional scheduling-guard overrides
- `credential_domain`: optional, triggers Keychain credential inject (§8 of contract)

Response:
```json
{"type": "create_session",
 "payload": {"session_id": "<sid>", "credential_injected": false}}
```
- `session_id`: required for subsequent actions
- `credential_injected`: bool, plaintext never returned

Failure: `{"type": "error", "payload": {<FBError>}}` (e.g. `quota_exceeded`)

### 3.3 execute (actions)

Request:
```json
{"type": "execute",
 "payload": {"session_id": "<sid>",
             "action": "click",
             "target_node_id": "e3",
             "payload_text": null,
             "scroll_delta_y": null,
             "trace_id": "<tid>"}}
```
- `action`: `click` | `type_text` | `scroll` | `navigate` | `screenshot` | `evaluate` | `close`
- `target_node_id`: required for `click`/`type_text`, **bare `eN`** (see §4)
- `payload_text`: `type_text` text / `navigate` URL / `evaluate` JS
- `scroll_delta_y`: scroll pixel delta (default 300)
- `trace_id`: traces agent-studio→browser→mlx (§7 of contract)

Response (`state`):
```json
{"type": "state",
 "payload": {"session_id": "<sid>",
             "url": "...",
             "title": "...",
             "ax_tree_markdown": "...",
             "interactive_nodes": [{"node_id": "e3", "role": "button", "name": "Login",
                                    "is_disabled": false, "current_value": ""}],
             "screenshot_jpeg": null,
             "has_security_injection_blocked": false,
             "execution_time_ms": 42,
             "security_audit": {"nodes_audited": 120, "hidden_nodes_purged": 0,
                                "matched_rules": []},
             "session_recovered": false,
             "error": null,
             "trace_id": "<tid>"}}
```

### 3.4 close

Request:
```json
{"type": "close", "session_id": "<sid>"}
```
Response:
```json
{"type": "closed", "session_id": "<sid>"}
```

## 4. Node-Id Format

Interactive node ids have **two representations** — callers MUST distinguish them:

| Context | Format | Example |
|---------|--------|---------|
| Wire / structured (`interactive_nodes[].node_id`, `target_node_id`) | **BARE `eN`** | `e1`, `e3` |
| Markdown reduction (`ax_tree_markdown`) | **`[@eN]`** | `[@e1]`, `[@e3]` |

Mechanism (`AXWalker.swift`): `var id="e"+(nextId++); window.__fbMap.set(id, new WeakRef(el))` — `__fbMap` keyed BARE. `resolveClick` does `window.__fbMap.get(id)` with NO `@` stripping. `FBStableMapping` (`AXTree.swift`) keys `mappings[nodeId]` bare.

**Critical:** an LLM reading `[@e1]` in markdown and forwarding `@e1` as `target_node_id` would hit a map miss → `node_stale`. `FBActionDriver.execute` (commit `9b3405e`) strips a leading `@` from `target_node_id` ONCE before admit/resolve/JS, so both `e1` and `@e1` resolve. Callers SHOULD send bare `eN` per the contract; the strip is defensive compatibility.

`__fbMap` is empty until the first extract, so the first click on a session needs a prior screenshot/extract warmup or it goes `node_stale`.

## 5. Capabilities Bitmask

`auth_ack.caps` is a bitmask (`FBAuth.caps`, FR-10). Capability denied → `evaluate_denied`.

| Action | Bit | Value |
|--------|-----|-------|
| navigate | 1<<0 | 1 |
| click | 1<<1 | 2 |
| type | 1<<2 | 4 |
| scroll | 1<<3 | 8 |
| screenshot | 1<<4 | 16 |
| evaluate | 1<<5 | 32 |
| close | 1<<6 | 64 |

- `default` caps = 95 (all except `evaluate`) — agent-studio tool token.
- `all` caps = 127 — full capability token.
- `evaluate` is off by default; granting it requires the token's capability set AND origin whitelist (§7 of contract).

## 6. Error Codes

`FBError` (`ErrorModel.swift`, FR-11) = `{code, message, retryable}`. Carried in `state.payload.error` or `error` envelope.

| Code | Retryable | Meaning |
|------|-----------|---------|
| `node_stale` | true | target node id no longer maps in `__fbMap` (post-navigate rebuild, id drift, or stale id from warmup). Retry after re-extract. |
| `credential_locked` | true | screen locked → Keychain inaccessible. Retry after unlock. |
| `quota_exceeded` | false | FR-08 RAM-tier session quota full. Reject `create`. |
| `evaluate_denied` | false | `evaluate` action not in token caps OR origin not whitelisted. |
| `session_not_found` | false | `session_id` unknown / already closed. |
| `timeout` | true | tiered watchdog (NFR-R) exceeded. Crash-rebuild attempted for idempotent actions. |
| `replay_limit` | false | FR-13 rebuild-depth-cap exceeded (`guards.rebuildDepthCap`, default 1). |
| `internal_error` | false | unexpected failure; check `Observability` logs with `trace_id`. |

FR-13 repeat-action-break rejects 3+ consecutive identical action keys (admit key = `"\(action):\(target):\(payload)"`) — returns `internal_error` with a repeat-break message (not a dedicated code); distinct targets rotate cleanly.

## 7. CDP Method Mapping

`FBCDPServer` (`:9222`, default off) translates cowork `cdp_client.py` real-CDP transport into `FBActionDriver` actions + `FBAXTreeExtractor`. Shim, not real Chrome. `FBCDPTranslator.dispatch` maps:

| CDP Method | Translation | Result Field |
|------------|-------------|--------------|
| `Page.navigate` | `navigate` action | `result.frameId` |
| `Runtime.evaluate` | `evaluate` action (caps + origin checked) | `result.result.value` |
| `Accessibility.getFullAXTree` | AXTree extract | `result.nodes` (each with `backendNodeId`) |
| `Page.captureScreenshot` | `screenshot` action | `result.data` (base64 PNG) |
| `Input.dispatchMouseEvent` (click) | `click` action | `result` ack |
| `Input.insertText` / `Input.dispatchKeyEvent` | `type_text` action | `result` ack |
| `DOM.getDocument` | AXTree root | `result.root.nodeId` |
| `DOM.resolveNode` | backendNodeId → JS objectId | `result.object.objectId` |
| `DOM.focus` | focus element | `result` ack |
| `DOM.setFileInputFiles` | set file input | `result` ack |
| `Emulation.setDeviceMetricsOverride` | no-op (shim) | `result` ack |

T3.3 extended domains (events via `FBCDPEventEmitter`, pushed with NO `id` per spec):
- `Network` — `requestWillBeSent`, `responseReceived`, `loadingFinished`
- `Runtime` — `consoleAPICalled`
- `Page` — `frameNavigated`, `lifecycleEvent`

CDP layer does NOT token-gate; security = EVALUATE origin whitelist + UDS token on the
main path. Default off (`cdpEnabled`); enable in config only when cowork needs it.

HTTP discovery: `/json`, `/json/version`, `/json/new?<url>`, `/json/close/<id>`.
WS endpoint: `ws://127.0.0.1:<port>/devtools/page/<targetId>` (RFC 6455; SHA1
Sec-WebSocket-Accept via `Insecure.SHA1`).
