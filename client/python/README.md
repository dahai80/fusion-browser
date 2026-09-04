# fusion-browser-client (Python)

A thin, maintained Python client for the **fusion-browser** UDS JSON-RPC server
(closes [issue #8](https://github.com/dahai80/fusion-browser/issues/8)).

fusion-browser exposes a Swift UDS server (`/tmp/fusion-browser.sock`) handling
`create_session` / `execute` / `close` / `metrics` / `capacity` with length-
prefixed JSON framing (`[u32 BE len][JSON]`, snake_case keys). This client wraps
that wire protocol so Python siblings (fusion-osagent, fusion-cowork, etc.) drive
the browser without reverse-engineering the schema from Swift sources.

## Install

```bash
cd client/python
pip install -e ".[test]"
```

## Usage

```python
from fusion_browser_client import FusionBrowserClient

with FusionBrowserClient(socket_path="/tmp/fusion-browser.sock", token="<authToken>") as c:
    sid = c.create_session(mode="headless")
    st = c.navigate(sid, "https://example.com")  # blocks to didFinish -> page loaded
    for n in st.interactiveNodes:
        print(n.nodeId, n.role, n.name, n.bbox)  # Issue #9: bbox per node
    c.click(sid, "e1")
    c.close_session(sid)
```

### `create_session(initial_url=...)` is fire-and-forget

The engine's `create` with `initial_url` loads the URL on main without waiting
for `didFinish` (E-40: a blank page must paint immediately so WebContent never
idles into suspend). So an action fired right after `create_session(initial_url=...)`
may run against a still-loading page — `interactiveNodes` can be empty on the very
first action. **Use `create_session()` (no URL) + `navigate(url)`** (blocks to
`didFinish`) when you need the page loaded before the next action. This mirrors
the engine's documented design (`WebView.navigate` main-thread fire-and-forget).

## Ops

| method | wire type | notes |
|---|---|---|
| `create_session(mode, initial_url, credentials)` | `create_session` | returns session id |
| `execute(session_id, action, target_node_id, payload_text, trace_id)` | `execute` | returns `SessionInfo` with `interactiveNodes` + `bbox` + `screenshotPng` |
| `navigate / click / type_text / scroll / screenshot / evaluate` | `execute` (convenience) | action-specific wrappers |
| `close_session(session_id)` | `close` | |
| `metrics()` | `metrics` | capability-gated (`.metrics`) |
| `capacity()` | `capacity` | returns `CapacityInfo` (H-9 multi-node plane) |

## Auth

The auth handshake (`{type:"auth",token}` → `auth_ack`) runs once on connect.
Fail-closed: a wrong/missing token raises `FBError(code="auth_denied")`. The
engine may close after an error; the client auto-reconnects + re-auths on the
next call.

## Issue #9 — bounding boxes

Every `AXTreeNode` carries an optional `bbox: BBox(x, y, width, height)` (viewport-
relative `getBoundingClientRect`), populated by the walker for SOM / visual-
grounding overlays. Additive field — `None` only if the source omitted it.

## Tests

```bash
pytest tests/ -v   # fake UDS server, no live engine needed
```
