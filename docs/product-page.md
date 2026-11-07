---
doc_id: fusion-browser/product-page
product: fusion-browser
class: app
entry: service
doc_type: product-page
title: { zh: "fusion-browser 产品页", en: "fusion-browser product page" }
audience: engineer
status: draft
version: 0.2.4
updated: 2026-11-07
owner: "@dahai"
source_of_truth:
  - README.md
  - CLAUDE.md
  - Package.swift
  - Sources/FusionBrowser/Config.swift
---

# fusion-browser 产品页（Product Page）

> 定位：macOS 原生受控浏览器引擎。以本地服务形态常驻，为 fusion-agent-studio 提供 Web 可视 + 结构化交互，为 fusion-cowork 提供 CDP 自动化兼容层（README.md）。
> Positioning: a macOS native controlled-browser engine that runs as a local service, providing web visual + structured interaction for fusion-agent-studio and a CDP compatibility layer for fusion-cowork (README.md).

## 网格定位（Grid position）

- class = `app`：独立运行的本地引擎产品，有明确的服务边界与消费方。
- entry = `service`：入口是常驻 UDS 服务进程（`.build/release/fusion-browser`），不是 GUI 也不是库；消费方（agent-studio、cowork、osagent）经协议接入。
- 证据：`Package.swift` 声明可执行目标 `FusionBrowser`（macOS 14+，纯 Swift，无外部依赖）；`Sources/FusionBrowser/UDSServer.swift` 是 POSIX AF_UNIX 服务端；默认 socket `/tmp/fusion-browser.sock`（`Config.swift:266`）。

## 消费方能力（What consumers no longer have to do）

| 能力 | 消费方不再需要做 | 约束 / 限制 |
|------|------------------|-------------|
| 受控浏览会话 | 不用自己起 Electron/Playwright 或逆向 WKWebView；`create_session`/`execute`/`close` 即可驱动真实 WebKit | WKWebView 不能在 `swift test` 里跑（无主 run loop 会死锁），活路径由 GUI runner 的 CI gate 覆盖 |
| 页面结构读取 | 不用写 DOM 抓取；AXTree 提炼返回结构化指纹 + `eN` 合成定位 + Markdown 降维 | 注入内容由反注入 Sanitizer 静态+渲染后双重清洗 |
| CDP 工具复用 | cowork 的 CDP 客户端不用改协议；`:9222` CDP-WS shim 翻译 Page/Runtime/Accessibility/Input/DOM 方法 | shim 不是真 Chrome；默认关（`cdpEnabled`） |
| 跨语言接入 | Python 兄弟服务（osagent/cowork）不用从 Swift 源码倒推 schema；用 `client/python/fusion_browser_client/` | 客户端是纯 socket UDS 实现，随引擎 wire 协议演进 |
| 多租户隔离 | 不用自己实现会话归属；每条 UDS 连接自动铸造 owner id（E-34），越权返回 `not_owner` | 代理/调度器场景需运维显式配置 `tokenSystemCaller`（默认 false，fail-closed） |
| 资源失控防护 | 不用外部看门狗；内置调度 guards（默认 `maxActions=200`/`taskTimeoutMs=300000`）与可选 RSS watchdog（默认关） | watchdog 动作只有 `close_sessions` 或 `exit`（交给 supervisor 重启） |

## 架构摘要（Architecture summary）

两层（CLAUDE.md §Architecture）：UDS 服务端（POSIX socket + 每连接 `DispatchSourceRead`，token 鉴权，长度前缀 JSON 帧 `[u32 BE len][JSON]`，snake_case）驱动会话管理器（每会话一个 WKWebView）。Phase 2 叠加 CDP-over-WS 兼容层（`:9222`，默认关）。六个基础设施模块各一个文件：Config / Framing / Auth / UDSServer / ErrorModel / Observability（+ Session 调度器）。

## 边界（Boundaries）

- 纯 Swift：Rust core 已在 E-17~20（#68）删除，构建无需 Rust 工具链，无 SPM 外部依赖。
- 引擎不自带模型调用；`visualLocator` 视觉兜底需要 fusion-mlx 先加载对应 VLM。
- 本地引擎，仅监听本机 UDS/TCP；无云依赖。

## 文档地图（Doc map）

- 快速上手：`docs/get-started.md`
- 协议与方法：`docs/api-reference.md`（详细帧格式见 `docs/PROTOCOL.md`）
- 配置项：`docs/config-reference.md`
- 故障排查：`docs/troubleshooting.md`
- Python 客户端：`client/python/README.md`
