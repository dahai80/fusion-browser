---
doc_id: fusion-browser/config-reference
product: fusion-browser
class: app
entry: service
doc_type: config-reference
title: { zh: "fusion-browser 配置参考", en: "fusion-browser config reference" }
audience: engineer
status: draft
version: 0.2.4
updated: 2026-11-07
owner: @dahai
source_of_truth:
  - Sources/FusionBrowser/Config.swift
  - CLAUDE.md
---

# fusion-browser 配置参考（Config Reference)

> 配置文件：`~/.fusion-browser/config.json`，可选；部分 JSON 即可，缺失字段回退 `FBEngineConfig.default`；非法 JSON 直接报错（fail loud）。键清单以 `Config.swift` 的 `CodingKeys` 为准。

## 顶层键（Top-level keys）

| 键 | 类型 / 默认 | 说明 |
|----|-------------|------|
| `socketPath` | string，`/tmp/fusion-browser.sock` | UDS 监听路径 |
| `cdpEnabled` | bool，`false` | CDP-over-WS 兼容层开关 |
| `cdpPort` | int，`9222` | CDP 监听端口 |
| `authToken` | string，空 | UDS/CDP 鉴权 token |
| `tokenCapabilities` | string 列表，空（→ `.default`） | 提升注册 token 的能力，如 `["evaluate"]`、`["metrics"]`、`["all"]`；名称大小写不敏感，未知名 fail-closed 丢弃（`FBAuth.parseCaps`） |
| `tokenSystemCaller` | bool，`false` | 运维级开关：该 token 的 UDS 连接按系统调用方（owner=nil）处理，绕过 E-34 归属校验。仅供可信代理/调度器（如 fusion-gateway 每次操作新拨连接的场景）；仅此不等于有能力，仍需 `tokenCapabilities` |
| `allowedOrigins` | string 列表，空 | EVALUATE 源白名单，fail-closed（E-15）：空列表拒绝 EVALUATE、CDP `Page.navigate` 与 CDP WS 升级；仅 `data:`/`about:`/`blob:` 本地 scheme 自由导航 |
| `logLevel` | string，`info` | `debug`/`info`/`warn`/`error` |
| `quota` | object | FR-08 按 RAM 的会话配额 |
| `guards` | object | FR-13 调度护栏，默认 `maxActions=200` / `taskTimeoutMs=300000` / `repeatActionBreak=3` / `rebuildDepthCap=1` |
| `watchdog` / `memoryWatchdog` | object，默认关 | P4-2 RSS 自愈：`enabled`/`sampleIntervalMs`/`thresholdMB`/`action`（`close_sessions` 或 `exit`）；经 `mach_task_basic_info.resident_size` 采样，一次性越限触发清场或退出交 supervisor 重启 |
| `sessionReaper` | object | 会话回收策略 |
| `rateLimit` | object | 限速策略 |
| `visualLocator` | object，默认关 | T3.4 视觉定位兜底：`endpoint`/`model`/`timeoutMs`/`enabled`；启用前 VLM 须已在 fusion-mlx 加载，`model` 用 `--` 分隔的注册 ID（如 `mlx-community--Qwen2.5-VL-7B-Instruct-4bit`） |
| `cookieImport` | object | #25 凭据导入来源：`chromeUserDataDir`/`edgeUserDataDir`/`firefoxProfilesDir`；部分覆盖，只覆盖其设置的子键 |

## 子对象细节（Sub-object notes）

- `guards`（FR-13）：调度护栏为引擎稳定性的硬约束，调大需配合容量评估；`rebuildDepthCap` 只统计幂等重放（E-23）。
- `memoryWatchdog`：默认关；`action` 只有 `close_sessions`（清空会话）与 `exit`（退出进程，预期由 supervisor 拉起）。
- `cookieImport`：Chrome/Edge 走 Keychain "Safe Storage" AES-128-CBC 解密，`v20` app-bound 记录如实计入 `skippedAppBound`；Firefox 读 `cookies.sqlite` 明文。计数只报真实写入会话库的数量。
- 已删除键：`useRustCore`（E-17~20 / #68 Rust core 移除后失效，配置里保留会被忽略/报错，取决于解码路径）。

## 不可配置项（Fixed values)

- 每连接 in-flight 批量上限 `maxBatch=64`（E-35，公平性护栏，固定）。
- 帧格式为长度前缀 JSON（FR-09），溢出背压 + B-4 部分帧到达超时；协议切换（如 D12 gRPC-over-UDS）属未来 codec 替换，不改 schema。

## 环境变量（Environment）

- 仓库内 MLX key 解析已委托 fusion-core（#36），契约键为 `FUSION_CLIENT_KEY`，legacy `FUSION_MLX_API_KEY` 已改名（#34，git 提交记录）。
