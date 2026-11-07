---
doc_id: fusion-browser/api-reference
product: fusion-browser
class: app
entry: service
doc_type: api-reference
title: { zh: "fusion-browser 接口参考", en: "fusion-browser API reference" }
audience: engineer
status: draft
version: 0.2.4
updated: 2026-11-07
owner: "@dahai"
source_of_truth:
  - docs/PROTOCOL.md
  - client/python/README.md
  - Sources/FusionBrowser/Protocol.swift
---

# fusion-browser 接口参考（API Reference）

> 传输层：UDS（默认 `/tmp/fusion-browser.sock`），长度前缀 JSON 帧 `[u32 BE len][JSON]`，键名 snake_case。完整帧格式、错误码与示例见 `docs/PROTOCOL.md`（协议稳定契约，schema 类型定义在 `Protocol.swift`）。

## UDS 方法（UDS methods）

| 方法 | 作用 | 鉴权 / 能力 | 归属校验 |
|------|------|-------------|----------|
| `create_session` | 创建会话（按 RAM 配额检查，主线程创建 WKWebView，注入凭据） | token 首帧鉴权 | 记录连接 owner id（E-34） |
| `execute` | 执行动作（navigate/click/type/evaluate 等，经 `FBActionDriver`） | 能力检查 + EVALUATE 源白名单（E-15） | 校验 owner，不符返回 `not_owner` |
| `close` | 关闭会话并回收资源 | token 鉴权 | 校验 owner |
| `metrics` | 引擎指标 + 延迟分位（p50/p95） | 能力 `.metrics`（默认关，需 `tokenCapabilities: ["metrics"]` 或 `["all"]`） | 系统调用方或 owner |
| `capacity` | 当前容量/配额面（gateway 轮询使用） | token 鉴权 | 无 |

补充语义：

- 默认 token 能力集为 `.default`，不含 `.evaluate` 与 `.metrics`（H-5 scoped-token 模型）；越权返回 `evaluate_denied` / `.authDenied`。
- 能力提升通过配置 `tokenCapabilities`（字符串列表，`"all"` 展开为全部；未知名 fail-closed 丢弃，见 `FBAuth.parseCaps`）。
- 会话归属：每条 UDS 连接 init 时铸造 UUID owner id；系统调用方（owner=nil）绕过校验。运维可为可信代理 token 设 `tokenSystemCaller: true`（R-10，默认 false）。
- 崩溃重建（E-23）：`rebuildDepth` 只计幂等动作重放；navigate/click/type/evaluate 等非幂等崩溃直接失败，不消耗重建配额。
- 批量上限（E-35）：每连接 in-flight `maxBatch=64`，固定值，不可配置。

## CDP 兼容层（CDP-over-WS，默认关）

- 端口 `cdpPort`（默认 `:9222`），需 `cdpEnabled: true`。
- HTTP 发现端点：`/json`、`/json/version`、`/json/new`、`/json/close`。
- WS 层：RFC 6455 帧编解码（SHA1 `Sec-WebSocket-Accept`）；`FBCDPTranslator` 把 Page/Runtime/Accessibility/Input/DOM 方法翻译为 `FBActionDriver` 动作 + AXTree 提取。
- 对齐 cowork `cdp_client.py` 契约（`result.result.value` / `result.nodes[...].backendNodeId` / `result.data` / `result.frameId`）；非白名单 EVALUATE 拒绝；`Performance.getMetrics` 在 WS 升级时做 Bearer 门禁。
- 定位：翻译 shim，不是真 Chrome（README.md T2.3）。

## Python 客户端（client/python/fusion_browser_client/）

- 纯 socket UDS 实现，包装上述 wire 协议；`FusionBrowserClient` 提供 `create_session` / `execute` / `close` 等对应方法。
- 测试与真实引擎解耦：`pytest tests/` 使用 fake UDS server。
- 流式截图：`FusionBrowserStream`（#25，`stream_screenshots` 专用连接推送 `screenshot_frame`，200ms 节流，以 `stream_end` 结束）。

## 错误模型

结构化 `{code, message, retryable}`（`ErrorModel.swift`，FR-11）；调用方按 `retryable` 决定重试，禁止静默吞错。
