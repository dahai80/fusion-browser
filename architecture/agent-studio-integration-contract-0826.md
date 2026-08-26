# fusion-agent-studio ↔ fusion-browser 对接契约

> 版本：v1.0 (2026-08-26)
> 依据：`fusion-browser-prd-0826.md` §3.2/§3.3 + Phase 3 T3.1
> 性质：跨项目对接契约。本侧（fusion-browser）只出本文档 + issue，实现代码落在 fusion-agent-studio（monorepo 规则：上游 issue → PR → 落地代码）。

## 1. 对接目标

fusion-agent-studio 通过 **browser_tool** 接入 fusion-browser，使 Agent 具备 Web Workflow 自动化能力（跨页面表单填写、登录校验、数据导出、多步骤点击跳转）。

- 传输：UDS（Unix Domain Socket）+ 长度前缀 JSON 帧（对齐 Protobuf schema，snake_case）
- 路径：`/tmp/fusion-browser.sock`（可配）
- 鉴权：首帧 shared-secret token
- 引擎：macOS Native WebKit（WKWebView），headless 主路径

## 2. 传输与分帧

- 连接 `AF_UNIX` socket，`SOCK_STREAM`
- 每帧：`[u32 big-endian length][JSON payload]`
- JSON key 一律 snake_case
- 首帧必须鉴权，否则连接被拒

## 3. 消息契约

### 3.1 鉴权帧（首帧，连接后立即发）

请求：
```json
{"type": "auth", "token": "<shared-secret>"}
```
响应（成功）：
```json
{"type": "auth_ack", "caps": 95}
```
失败：连接被服务端关闭，无响应。token 不匹配即拒。

### 3.2 创建会话

请求（type=`create_session`，payload 为 `CreateSessionRequest`）：
```json
{"type": "create_session",
 "payload": {"mode": "headless",
             "initial_url": null,
             "max_actions": null,
             "task_timeout_ms": null,
             "credential_domain": null}}
```
- `mode`：`"headless"`（默认）| `"headed"`（弹出窗口，调试用）
- `initial_url`：可选，建会话即导航
- `max_actions` / `task_timeout_ms`：可选调度护栏覆盖
- `credential_domain`：可选，触发 Keychain 凭据注入（见 §8）

响应（type=`create_session`，payload 为 `CreateSessionResponse`）：
```json
{"type": "create_session",
 "payload": {"session_id": "<sid>", "credential_injected": false}}
```
- `session_id`：后续动作必须带，string
- `credential_injected`：是否注入了凭据（bool，凭据明文永不回传）

失败：`{"type": "error", "payload": {<FBError>}}`（如 `quota_exceeded`）

### 3.3 执行动作

请求（type=`execute`，payload 为 `BrowserActionRequest`）：
```json
{"type": "execute",
 "payload": {"session_id": "<sid>",
             "action": "click",
             "target_node_id": "@e3",
             "payload_text": null,
             "scroll_delta_y": null,
             "trace_id": "<tid>"}}
```
- `action`：`click` | `type_text` | `scroll` | `navigate` | `screenshot` | `evaluate` | `close`
- `target_node_id`：`click`/`type_text` 必带，形如 `@e3`（AXTree 稳定映射 ID）
- `payload_text`：`type_text` 文本 / `navigate` URL / `evaluate` JS
- `scroll_delta_y`：`scroll` 像素位移（默认 300）
- `trace_id`：贯穿 agent-studio→browser→mlx（见 §7）

响应（type=`state`，payload 为 `BrowserStateResponse`）：
```json
{"type": "state",
 "payload": {"session_id": "<sid>",
             "url": "...",
             "title": "...",
             "ax_tree_markdown": "...",
             "interactive_nodes": [{"node_id": "@e3", "role": "button", "name": "Login",
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
- `ax_tree_markdown`：降维 Markdown，交互节点一行一项，供 LLM ≤1500 token 决策
- `interactive_nodes`：结构化节点列表（`@eN` + role + name + disabled + value）
- `screenshot_jpeg`：`screenshot` 动作返回 base64？— **注意**：本字段为 bytes，JSON 编码下为 null，截图实际走独立 screenshot 动作返回值（实现侧以 base64 字符串承载，见 §10）
- `error`：非空则本次失败，见 §6
- `session_recovered`：本次是否经 watchdog 重建
- `trace_id`：回传，日志关联

### 3.4 关闭会话

请求：
```json
{"type": "close", "session_id": "<sid>"}
```
响应：
```json
{"type": "closed", "session_id": "<sid>"}
```


## 4. browser_tool 工具契约

fusion-agent-studio 的工具基类见 `tools/base.py`：子类需声明 `name` / `description` / `parameters`，实现 `async execute(**kwargs) -> str`，自动产出 OpenAI function-calling schema。

建议实现为 **单工具多动作**（而非每动作一工具），减少 schema 数量：

```python
class BrowserTool(BaseTool):
    name = "browser"
    description = (
        "Control a native macOS WebKit browser via fusion-browser for web automation: "
        "create sessions, navigate, extract the interactive element tree (@eN ids), "
        "click/type/scroll/evaluate, and screenshot. Use for cross-page form filling, "
        "login, data export, multi-step navigation."
    )
    parameters = {
        "action": {
            "type": "string",
            "enum": ["create_session", "navigate", "extract", "click",
                     "type_text", "scroll", "screenshot", "evaluate", "close_session"],
            "description": "Browser action to perform."
        },
        "url": {"type": "string", "description": "URL to navigate to (action=navigate)."},
        "node_id": {"type": "string", "description": "Target @eN node id (action=click/type_text)."},
        "text": {"type": "string", "description": "Text to type (action=type_text) or JS (action=evaluate)."},
        "scroll_delta_y": {"type": "integer", "description": "Scroll pixels (action=scroll)."},
        "session_id": {"type": "string", "description": "Browser session id (omitted on create_session)."},
        "credential_domain": {"type": "string", "description": "Domain for Keychain credential inject (action=create_session)."},
        "mode": {"type": "string", "enum": ["headless", "headed"], "description": "Session mode (action=create_session)."}
    }
```

设计要点：
- **会话生命周期由工具内部持有**：`execute` 维护 `self._sessions: dict[str, socket]`（或进程级单例 client），`create_session` 返回 `session_id`，Agent 在后续调用带上。
- **`extract` 是复合动作**：底层发 `action=screenshot`（拿图）+ 读上次 `state` 的 `ax_tree_markdown`/`interactive_nodes`。或导航/点击后 `execute` 已返回 `state`，`extract` 可复用最近一次响应避免重复请求。
- **输出为 string**（基类契约）：`execute` 把 `BrowserStateResponse` 序列化成 LLM 可读文本——`ax_tree_markdown` 直接返回（已降维），附 `url`/`title`/`node_count`，失败附 `error.code`。
- **多会话并发隔离**：每 `session_id` 独立 socket 连接（UDS server 每 client 独立读循环，FR-09），Agent 可并行开多页。

### 4.1 推荐输出格式（`execute` 返回串）

成功（含状态）：
```
[BROWSER] url=https://example.com title=Example
[AXTREE]
<button id=@e1>Login</button>
<input id=@e2 placeholder=Email ...>
...
[/AXTREE]
nodes=12 recovered=false security_blocked=false
```
失败：
```
[BROWSER ERROR] code=node_stale message=target node no longer matches fingerprint retryable=true
```
`node_stale` → Agent 应重新 `extract` 取最新 `@eN` 再点击（见 §5）。


## 5. 控制回路（Data Flow）

PRD §3.3 核心交互控制回路：

```
agent-studio
  │ 1. browser(action=create_session, url=...)          → session_id
  │ 2. browser(action=navigate, url=...)                 → ax_tree_markdown + @eN 节点
  │ 3. LLM ≤1500 token 上下文决策下一步 (经 fusion-mlx)
  │ 4. browser(action=click, node_id=@e3, trace_id=tid)  → 新 ax_tree_markdown
  │    ├─ error.code=node_stale → 重新 extract 取最新 @eN，重试点击（不静默失败）
  │    └─ error.retryable=true & session_recovered=true → 引擎已重建，重发同一动作
  │ 5. 循环 3-4 直到任务完成
  │ 6. browser(action=close_session, session_id=...)
  ▼
fusion-browser (UDS) → WebKit → Sanitizer → AXTree 提炼 → BrowserStateResponse
  │ trace_id 贯穿三方日志 (FR-12)
  ▼
fusion-mlx (LLM 决策，trace_id 关联)
```

关键约束：
- **node_stale 不静默失败**：DOM 在动作间可能变（SPA 重渲染），`@eN` 指纹失配返 `node_stale`。Agent 必须重新 `extract` 拿新 `@eN` 再点击，不要重发旧 `node_id`。
- **trace_id 透传**：每次 `execute` 带 `trace_id`，browser 回传同值；agent-studio 把它透给 fusion-mlx 的 LLM 调用日志，三方可按 trace_id 串联。
- **LLM 决策用 Markdown**：`ax_tree_markdown` 已降维（交互节点一行一项，剔除非必要字段），token 预算 P95 ≤1500。不要喂 `interactive_nodes` 原始 JSON 给 LLM（冗长）。


## 6. 错误处理与重试

错误结构：`{"code": "...", "message": "...", "retryable": true/false}`。Agent 按 `retryable` + `code` 决策，不猜异常。

| code | 含义 | retryable | Agent 处理 |
|------|------|-----------|-----------|
| `node_stale` | 目标节点指纹失配（DOM 变了） | true | 重新 `extract` 取新 `@eN`，重试动作 |
| `credential_locked` | 屏幕锁定，Keychain 不可读 | true | 提示解锁屏幕后重试 |
| `quota_exceeded` | 超 RAM 分档 session 上限 | false | 等其他 session 关闭，或降并发 |
| `evaluate_denied` | EVALUATE origin 非白名单 | false | 检查 `allowedOrigins` 配置 / 改用 navigate |
| `session_not_found` | session_id 无效/已关 | false | 重新 `create_session` |
| `timeout` | 动作超 watchdog（navigate 30s/click 2s 等） | true | 引擎可能已 rebuild；`session_recovered=true` 时重发幂等动作 |
| `replay_limit` | 重建深度达上限 | false | 终止该会话，重建新会话 |
| `internal_error` | 未分类内部错 | false | 记日志，终止 |

幂等性（引擎重建只回放幂等动作）：
- 幂等：`navigate` / `scroll` / `screenshot` — 可安全重发
- 非幂等：`click` / `type_text` / `evaluate` — 引擎不回放，失败直接返错；Agent 看 `session_recovered` 判断是否需自行重试（如点击可能未生效，先 `extract` 确认状态）


## 7. trace_id 贯穿与可观测性

FR-12：`trace_id` 贯穿 agent-studio → browser → mlx 三方日志。

- **生成**：agent-studio 每次发起 browser 动作生成 `trace_id`（如 `fb-<uuid8>`），塞入 `BrowserActionRequest.trace_id`
- **回传**：browser 在 `BrowserStateResponse.trace_id` 回传同值
- **透传到 mlx**：agent-studio 调 fusion-mlx LLM 决策时，把同一 `trace_id` 写入 LLM 请求元数据/日志，三方可按 trace_id 串联一次完整 Workflow
- **browser 侧日志**：UDS server + ActionDriver + VisualLocator 均带 `traceId:` 字段（见 `Observability.swift`），os_log + stderr 可查 `com.fusion.browser`
- **凭据审计**：browser 记 append-only 审计日志（时间/调用方/domain/op/result，**不含明文**）

## 8. 凭据流程

D11 决策：任务结束默认保留 Keychain 凭据（下次免登录），session 内存态清空。

- **建会话**：`create_session` 带 `credential_domain`（如 `example.com`）
- **注入**：browser 从 Keychain 取该 domain 完整 cookie 属性（name/value/domain/path/expires/secure/httponly/samesite），注入 session 内存 `httpCookieStore`
- **回传**：`CreateSessionResponse.credential_injected`（bool，明文永不离开 Keychain/内存）
- **脱敏**：`type=password` 输入框的 `current_value` 在 AXTree 恒为 `********`，LLM 看不到密码
- **锁屏**：屏幕锁定时 Keychain 不可读 → 返 `credential_locked`，Agent 提示解锁
- **注销**：需显式删除 Keychain item（D11「彻底注销」模式，非默认）

前提：凭据需先存入 Keychain（account=domain）。存入流程不在 browser 侧，属 agent-studio 或 fusion-studio 凭据管理职责。


## 9. 验收门（PRD T3.1）

PRD §4 Phase 3 T3.1 验收门：**agent-studio 端到端跑通 Web Workflow 场景**。

最小验收场景（建议作为集成测试）：
1. 启 fusion-browser（`~/.fusion-browser/config.json` 配 `authToken` + `allowedOrigins`）
2. Agent 用 `browser(create_session, mode=headless, url=https://example.com)`
3. `extract` 拿 `ax_tree_markdown` + `@eN`，LLM 决策点击某链接
4. `click(node_id=@eN)` → 验证返回新 `url` 已跳转
5. 触发一次 `node_stale`（导航后立即用旧 `@eN`）→ 验证 Agent 自动重抽重试，不静默失败
6. `type_text` 填表单 + 提交 → 验证 `trace_id` 贯穿三方日志可查
7. `close_session` → 验证资源释放

并发隔离验证：同时开 2 个 session 导航不同站点，动作不串扰。

## 10. 实现指引（agent-studio 侧）

### 10.1 文件清单（新增）

- `tools/browser_tool.py` — `BrowserTool(BaseTool)`：UDS client + 会话管理 + 9 动作 dispatch
- `tools/fusion_browser_client.py`（可选，抽底层 UDS client 复用）— 鉴权帧 / 分帧收发 / 重连

### 10.2 UDS client 参考实现（分帧）

直接对齐 `fusion-browser/scripts/smoke_client.py`：

```python
import json, socket, struct

class FusionBrowserClient:
    def __init__(self, sock_path, token, trace_id=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(sock_path)
        self._send({"type": "auth", "token": token})
        ack = self._recv()
        if not ack or ack.get("type") != "auth_ack":
            raise RuntimeError(f"auth failed: {ack}")

    def _send(self, obj):
        data = json.dumps(obj).encode()
        self.sock.sendall(struct.pack(">I", len(data)) + data)

    def _recv(self):
        hdr = self._recvn(4)
        if not hdr: return None
        (length,) = struct.unpack(">I", hdr)
        body = self._recvn(length)
        return json.loads(body) if body else None

    def _recvn(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk: return None
            buf += chunk
        return buf

    def create_session(self, mode="headless", initial_url=None, credential_domain=None):
        self._send({"type": "create_session",
                    "payload": {"mode": mode, "initial_url": initial_url,
                                "credential_domain": credential_domain}})
        resp = self._recv()
        return resp["payload"] if resp else None

    def execute(self, session_id, action, target_node_id=None, payload_text=None,
                scroll_delta_y=None, trace_id=None):
        self._send({"type": "execute",
                    "payload": {"session_id": session_id, "action": action,
                                "target_node_id": target_node_id,
                                "payload_text": payload_text,
                                "scroll_delta_y": scroll_delta_y,
                                "trace_id": trace_id}})
        resp = self._recv()
        return resp["payload"] if resp else None

    def close(self, session_id):
        self._send({"type": "close", "session_id": session_id})
        self._recv()

    def shutdown(self):
        try: self.sock.close()
        except Exception: pass
```

### 10.3 注册（`tools/__init__.py` `create_default_registry`）

```python
from .browser_tool import BrowserTool
# ...
registry.register(BrowserTool())
```
并加入 `__all__`。`BrowserTool.__init__` 读 `~/.fusion-browser/config.json`（token / socketPath / allowedOrigins），缺省降级（无配置则不注册，记 `failed_plugins`）。

### 10.4 配置

agent-studio 侧读取 fusion-browser 的 `~/.fusion-browser/config.json`（同机部署）。关键：
- `authToken`：UDS 鉴权 token，必须配（生产）
- `socketPath`：默认 `/tmp/fusion-browser.sock`
- `allowedOrigins`：EVALUATE 白名单，空=不限（生产建议配）

### 10.5 依赖与进程前提

- fusion-browser 二进制须先起（`swift build -c release` → `.build/release/fusion-browser`，或纳入 start.sh）
- 无 Python 依赖（纯 stdlib socket/json/struct）
- 仅 macOS（WKWebView）

