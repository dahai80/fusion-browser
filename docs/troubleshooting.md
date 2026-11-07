---
doc_id: fusion-browser/troubleshooting
product: fusion-browser
class: app
entry: service
doc_type: troubleshooting
title: { zh: "fusion-browser 故障排查", en: "fusion-browser troubleshooting" }
audience: engineer
status: draft
version: 0.2.4
updated: 2026-11-07
owner: @dahai
source_of_truth:
  - CLAUDE.md
  - docs/DEVELOPMENT.md
  - docs/PROTOCOL.md
---

# fusion-browser 故障排查（Troubleshooting）

> 症状 → 定位 → 处置。实现约束的完整清单见 `docs/DEVELOPMENT.md` §3。

## 1. 启动与连接

### 1.1 socket 文件不存在 / 客户端连接被拒

- 定位：引擎未启动，或 `socketPath` 配置指向了非默认路径（默认 `/tmp/fusion-browser.sock`，`Config.swift`）。
- 处置：先启动 `.build/release/fusion-browser`；确认配置文件 `~/.fusion-browser/config.json` 是合法 JSON（非法 JSON fail loud，不会静默回退默认）。

### 1.2 首帧鉴权失败

- 定位：token 鉴权在首帧门禁（`FBClientConnection`）；`authToken` 不匹配即断开。
- 处置：客户端与 `~/.fusion-browser/config.json` 的 `authToken` 保持一致；CDP 场景还需 Bearer 头（`Performance.getMetrics` 在 WS 升级时校验）。

### 1.3 `not_owner`

- 定位：E-34 会话归属校验——`execute`/`close` 的连接必须与 `create_session` 同一 owner id。
- 处置：同一会话的生命周期调用复用同一条 UDS 连接；若调用方是代理/调度器（如 fusion-gateway 每操作新拨一条连接），由运维为该 token 配置 `tokenSystemCaller: true`（默认 false，fail-closed）。

## 2. 能力与权限

### 2.1 `evaluate_denied`

- 定位：默认 token 能力集 `.default` 不含 `.evaluate`（H-5 scoped-token 模型）。
- 处置：配置 `tokenCapabilities: ["evaluate"]`（或 `["all"]`）后重启引擎；能力名大小写不敏感，未知名被 fail-closed 丢弃（`FBAuth.parseCaps`）。

### 2.2 EVALUATE 被源白名单拒绝 / CDP 升级失败

- 定位：`allowedOrigins` fail-closed（E-15）——空列表拒绝 EVALUATE、CDP `Page.navigate` 与 CDP WS 升级；仅 `data:`/`about:`/`blob:` 自由导航。
- 处置：把需要 evaluate 的页面源显式加入 `allowedOrigins`。

### 2.3 `metrics` 返回 `.authDenied`

- 定位：`.metrics` 不在 `.default` 能力集（R-3/B-3）。
- 处置：`tokenCapabilities: ["metrics"]` 或 `["all"]`；CDP `Performance.getMetrics` 还需 CDP 已启用。

## 3. CDP 兼容层

### 3.1 `:9222` 连不上

- 定位：`cdpEnabled` 默认 `false`。
- 处置：配置开启后重启引擎；发现端点为 `/json`、`/json/version`、`/json/new`、`/json/close`。
- 边界：这是翻译 shim 不是真 Chrome——仅白名单内 Page/Runtime/Accessibility/Input/DOM 方法被翻译，非白名单 EVALUATE 直接拒绝。

## 4. 会话与资源

### 4.1 会话创建被拒（配额）

- 定位：FR-08 按 RAM 的会话配额（`quota`）。
- 处置：关闭空闲会话；需要更高并发时评估宿主内存后调整配额，或启用 `memoryWatchdog`（P4-2，默认关）自动清场。

### 4.2 动作超时 / 会话"卡死"

- 定位：FR-13 调度护栏：`taskTimeoutMs`（默认 300000）、`maxActions`（默认 200）、`repeatActionBreak`（默认 3）。
- 处置：按护栏语义调整或等待超时回收；连续重复动作会触发 repeat-break，属预期保护。

### 4.3 崩溃后 rebuild 不生效

- 定位：E-23——只有幂等动作会消耗 `rebuildDepthCap` 自动重放；navigate/click/type/evaluate 属非幂等，直接失败。
- 处置：调用方对非幂等动作自行重试；两个慢页点击超时不应把会话打"砖"（这是该语义的设计目标）。

## 5. 测试与 CI

### 5.1 往 `swift test` 里加 WKWebView 用例导致整套挂起

- 定位：`swift test` 无主 run loop，`evaluateJSSync`/`screenshotSync` 的 completion handler 派发到 main 后信号量死锁（ARCH-3）。
- 处置：确定性单测只覆盖 reducer/translator/codec/Keychain 等；活路径用构建产物 + Python smoke 客户端验证，或跑 `scripts/release_gate.sh`（self-hosted GUI runner 的 `live-path-gate` job）。

### 5.2 CI `live-path-gate` 里 `uma_coexist` 失败

- 定位：该 harness 需要 fusion-mlx 在 `:11434` 已加载对应 VLM。
- 处置：启动 fusion-mlx 并加载模型；或设仓库变量 `SKIP_UMA=1` 只跳过该 harness（其余 10 个仍硬性执行，缺失 harness 视为失败，不存在静默跳过）。

## 6. 数据导入

### 6.1 `import_cookies` 计数比浏览器里少

- 定位：计数如实——只统计真实写入会话库的 cookie；Chrome/Edge `v20` app-bound 记录计入 `skippedAppBound`，无法解密的计入 `skippedOther`（#25）。
- 处置：属预期行为；需要导入的站点在非 app-bound 配置下重新登录一次。
