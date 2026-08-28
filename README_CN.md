# fusion-browser

> 文档版本：Phase 4 生产化加固落地（2026-08-26）
> 依据：`architecture/fusion-browser-prd-0826.md` (v2.0) + `audit/fusion-browser-audit-0826.md`
> 配套技术方案：`~/fusion/fusion-browser-prd-plan-0826.md`
> 文档：[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) · [`docs/PROTOCOL.md`](docs/PROTOCOL.md) · [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
> 双语：本文为中文，英文版见 [`README.md`](README.md)（默认）。

macOS 原生受控浏览器引擎，为 fusion-agent-studio 提供 Web 视觉与结构化交互终端，兼顾 fusion-cowork CDP 自动化复用。基于 macOS Native WebKit (WKWebView)，双协议栈（UDS 长度前缀 JSON 主路径 + CDP-over-WS 兼容层），内建六大基础设施。

## 当前状态（Phase 4 生产化加固已落地）

Phase 1 引擎基座 + 六大基础设施 + Phase 2 四任务（AXTree 提炼器 / 反注入 Sanitizer / CDP 兼容层 / 凭据闭环）+ Phase 3 三任务（多节点动态配额 / CDP 扩 Domain + 事件 / 视觉定位兜底）+ Phase 4 五任务（无痕落盘验收 / RSS 自重启 / 性能基准套件 / UMA 共存基线 / 1000-action 长跑无泄漏）完成，编译通过，99 单元测试通过。CDP `:9222` 端到端冒烟通过；T3.4 视觉定位经真 VLM 冒烟验证；Phase 4 全部经 release 二进制 + Python 验收脚本实测通过。

**Phase 1 已落地**
- Swift 6 SPM 包，Headless/Headed WKWebView 封装（`nonPersistent` dataStore 隔离，共享 `WKProcessPool`）
- UDS 服务端（POSIX socket + `DispatchSourceRead`，绕开 `NWListener` AF_UNIX accept 不可靠问题）
- 长度前缀 JSON 分帧（schema 对齐，snake_case，codec 可后续替换为 gRPC）
- FR-08 资源管控：按物理 RAM 动态核定 session 数/内存预算，超配额拒绝
- FR-09 流控背压：每 client 独立读循环、单 socket 大帧不阻塞他人、超 cap 丢弃
- FR-10 鉴权能力模型：shared-secret token，每 action capability 校验，EVALUATE 需独立 capability + origin 白名单
- FR-11 错误模型：结构化 `{code,message,retryable}`，预定义错误码枚举（node_stale/credential_locked/quota_exceeded/evaluate_denied/timeout/replay_limit 等）
- FR-12 可观测性：metrics（计数 + 延迟分位数）+ trace_id 全链路 + 凭据 append-only 审计日志
- FR-13 调度护栏：max_actions + task_timeout + 连续相同 action 中断 + 重建深度上限 1
- NFR-R 分档 watchdog：navigate 30s / click·type 2s / scroll 500ms / screenshot·evaluate 5s；超时 crashed→rebuild，仅回放幂等 action（navigate/scroll/screenshot），非幂等（click/type/evaluate）直接 fail

**Phase 2 已落地**
- T2.1 AXTree 提炼器：注入 JS walker 抽 DOM，结构指纹（tag + 属性子集 + docPath）+ JS 侧 `window.__fbMap` WeakRef<Node> 稳定映射，`eN` 合成定位；Markdown 降维（交互节点一行一项，弃非必要字段）；`eN` 失效返 `node_stale`
- T2.2 反注入 Sanitizer：静态隐藏向量规则目录（display:none/visibility:hidden/opacity:0/font-size:0/aria-hidden/hidden/offscreen/text-indent/scale/filter-opacity/color=bg/covered-overlay）+ 渲染后实测（`getBoundingClientRect` 尺寸 0/离屏 + `elementFromPoint` 命中）；purge 仅抹文本保留节点结构（零误杀）；对抗测试集 + 确定性单元测试覆盖 100% 拦截
- T2.3 CDP 兼容层：`:9222` CDP-WS shim（非真 Chrome，翻译层），POSIX TCP + HTTP 发现（`/json`/`/json/version`/`/json/new`/`/json/close`）+ RFC 6455 WS 帧编解码（SHA1 Sec-WebSocket-Accept），`FBCDPTranslator` 把 Page/Runtime/Accessibility/Input/DOM 方法翻成 `FBActionDriver` 动作 + AXTree 提炼；对齐 cowork `cdp_client.py` 契约（`result.result.value`/`result.nodes[...].backendNodeId`/`result.data`/`result.frameId`）；非白名单 EVALUATE 拒绝；默认关（`cdpEnabled`）
- T2.4 凭据闭环：Keychain 存**完整 cookie 属性**（name/value/domain/path/expires/secure/httponly/samesite），account=domain，注入到 session 内存态 `httpCookieStore`；LLM 仅得 `credential_injected:bool`（明文永不离开 Keychain/内存）；`type=password` 输入框值在 AXTree 脱敏为 `********`；锁屏返 `credential_locked`；凭据审计日志只记 op/result 不含明文；NFR-S2/D11 默认保留、`logout` 删除

**Phase 3 已落地**
- T3.2 多节点适配：`FBResourcesQuota.forHost(ramGB:)` 按 RAM 分档核定 session 数/总内存（<8GB→2、8-16GB→4、16-32GB→10、≥32GB→16），perSession=150MB，total=sessions×150；超配额 `create` 拒绝返 `quota_exceeded`；显式 RAM 重载使分档表可单元测试（不依赖跑测机器）
- T3.3 CDP 扩 Domain：`FBCDPTranslator` 扩 Network/Console/Emulation/Page.lifecycleEvent（Page.frameNavigated + lifecycleEvent、Network.requestWillBeSent/responseReceived/loadingFinished、Runtime.consoleAPICalled），DOM.focus/setFileInputFiles；事件解耦为独立 `FBCDPEventEmitter`（send-closure 驱动，不依赖 live socket/webview → 可确定性单测）；cowork 剩余节点免降级接入
- T3.4 视觉定位兜底：click 节点 `node_stale` 时，`FBVisualLocator` 取 `screenshotSync` PNG + 失效节点 role/name 描述 → 调 fusion-mlx OpenAI 兼容 `/v1/chat/completions`（VLM 读 `image_url` base64 data URI）→ 解析 `{x,y}` → `elementFromPoint` 点击；OOB/负值防护拦幻觉；可插拔 `FBHTTPClient` 协议使预测逻辑可单测（真 VLM 加载走集成冒烟）；默认关（`visualLocator.enabled`，需先在 fusion-mlx 加载 VLM）

**Phase 4 已落地（生产化加固）**
- P4-1 无痕落盘验收（FR-04）：`nonPersistent` dataStore 实测——驱动 data-URL 页写 `document.cookie`+`localStorage`，lsof 确认进程未持有任何持久化 WebKit 数据文件（WebsiteData/cookies/localStorage/IndexedDB），关闭后本 bundle 容器零残留。验收脚本 `scripts/verify_nonpersistent.py`。验收期间定位并修复两处真实崩溃：`create` 带 `initial_url` 在后台队列调 `WKWebView.load`（exit 133）→ 改主线程 async；`close` 在后台队列调 AppKit `destroy()`（exit 133）→ 主线程 sync + 释放队列锁后再 teardown（避免 main↔sessionmgr 锁倒置）
- P4-2 jetsam/RSS 自重启（新代码）：`FBMemoryWatchdog` 周期采样宿主进程 RSS（`mach_task_basic_info.resident_size`），超阈值一次性触发恢复闭包（drain 全部 session 或 exit 待外部 supervisor 重启）；one-shot arm/disarm 防重复 drain，恢复后重 armed；可插拔 sampler 便于单测（RSS syscall 在 `swift test` 可跑）；默认关（`memoryWatchdog.enabled`）。作用域注记：仅守宿主侧增长（AXTree 串/JS 注入缓冲/会话表），WebContent 膨胀由 FR-08 配额间接约束。6 个确定性单测
- P4-3 性能基准套件：`scripts/perf_bench.py` 驱动 release 二进制跑 scroll/screenshot/click 固定负载（各 20），收 `execution_time_ms` 算 P50/P95/max，采样宿主 RSS，算 AXTree markdown 压缩比（chars/node）。期间定位并修复 CRITICAL：`evaluateJSSyncArgs` 用 `replacingOccurrences` 替全部 `__ARG__` → 多参脚本首参填满所有槽位，expectFp 拿到 nodeId、指纹永不匹配 → 全部 click/type `node_stale`；改为 `range(of:)`+`replaceSubrange` 一参一槽。报告 `scripts/perf-report.json`
- P4-4 UMA 共存基线实测：`scripts/uma_coexist.py` 10 并发 session × 100 动作（scroll/screenshot/click 轮转），期间对 fusion-mlx 发推理请求；断言宿主 RSS 增量 < 150MB×10 配额、`fusion_mlx_model_memory_bytes` 无单调上升、mlx 持续服务。实测 100/100 动作 ok，RSS delta 38MB，mlx 内存 delta 0，推理服务正常。报告 `scripts/uma-report.json`。此即 PRD T1.5 实测落地
- P4-5 1000-action 长跑无泄漏：`scripts/longrun_leak.py` 单 session 连跑 1000 动作，每 50 动作采样 RSS，比首四分位 vs 末四分位均值（容差 30MB allocator jitter）。实测 1000/1000 ok，RSS span 4.1MB，末四分位均值不显著高于首 → 无单调泄漏。报告 `scripts/longrun-report.json`

**Phase-4 后修复已落地**
- 节点 id 格式（commit `9b3405e`，2026-08-27）：wire/结构化节点 id 为裸 `eN`（`interactive_nodes[].node_id`、`target_node_id`）；Markdown 降维 `ax_tree_markdown` 显示 `[@eN]` 仅供 LLM 可读。LLM 原样转发 `@e1` 会 `__fbMap` 未命中 → `node_stale`。`FBActionDriver.execute` 现在在 admit/resolve/JS 前一次性剥离 `target_node_id` 前导 `@`，故 `e1` 与 `@e1` 均可解析。调用方应发裸 `eN`。见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md) §4。

**Rust 核心已移除（E-17~20 / #68，2026-08-27）**
- PRD §2 T1.4 评估结论：纯 Swift（`FBAXTreeReducer.toMarkdown` + `JSONDecoder`）已覆盖 Sanitizer+AXTree——Rust 核心默认关、从未是活路径（纯 Swift 路径正是 Rust 核心失败时回退的那条）。已移除整个 FFI 边界：`FBCoreBridge` / `FBCoreWorkerPool` / `FBCoreRust` SPM target / `FBCoreRustBuilder` 插件 / `rust/` crate 树 / `useRustCore` 配置键 / `RustCoreParityTests` / `scripts/parity_smoke.py`。一次性关闭审计 E-17（构建不可移植：arm64 硬编码）、E-18（worker pool 非专用 FIFO）、E-19（无运行时对齐检查）、E-20（Cargo.lock 未进插件输入）。无需 Rust 工具链；`--disable-sandbox` 不再必须（此前必须仅因插件跑 cargo）。wire schema + AXTree 输出（markdown + 节点 + audit）不变 → cowork 不受影响。

**未做（按路线图）**
- T3.1 agent-studio 全对接：跨项目，本侧只出契约文档 + issue，落地在 fusion-agent-studio（已上游经 PR #235 落地；我的跟踪 issue #237 关为重复；#241 开，测试保真度）

## 构建与测试

```bash
cd /Users/dahai/fusion/fusion-browser
swift build                # debug（纯 Swift，无插件）
swift build -c release     # release -> .build/release/fusion-browser
swift test --disable-sandbox   # 183 测试（--disable-sandbox 不再必须：插件已移除；保留为兼容）
swift test --disable-sandbox --filter CDPServerTests   # 单个测试套
```

要求：macOS 14+，Xcode CLI Tools（已验证 Swift 6.3.3 / Xcode 26.6 / macOS 26.5 / arm64）。纯 Swift 构建——无需 Rust 工具链（Rust 核心已移除，E-17~20 / #68）。

> 注：WKWebView 完成回调依赖主 run loop，`swift test` 无主循环 → `evaluateJSSync`/`screenshotSync` 信号量会死锁。故 live WKWebView 行为（AX walker 实跑、截图、真实导航）不在 `swift test` 内验证，靠确定性单元测试（规则目录/reducer/translator/codec）+ 起二进制 + Python smoke 客户端覆盖。见 [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) §4。

## 运行

```bash
# 默认 socket /tmp/fusion-browser.sock，CDP 关，无 token（仅同机 UDS，生产须配 token）
.build/release/fusion-browser

# 配置文件（可选，~/.fusion-browser/config.json，部分字段可省略用默认）
cat > ~/.fusion-browser/config.json <<'JSON'
{"socketPath":"/tmp/fusion-browser.sock","cdpEnabled":true,"cdpPort":9222,
 "authToken":"your-secret","allowedOrigins":["https://example.com"],"logLevel":"info"}
JSON
.build/release/fusion-browser
```

`logLevel`：debug/info/warn/error。日志同时写 `os_log`（Console.app 可查 `com.fusion.browser`）与 stderr。

配置键：`socketPath`、`cdpEnabled`、`cdpPort`、`authToken`、`logLevel`、`allowedOrigins`（EVALUATE origin 白名单，空=不限）、`visualLocator`（T3.4 视觉定位兜底，默认关；启用需先在 fusion-mlx 加载 VLM，子键 `endpoint`/`model`/`timeoutMs`/`enabled`）、`memoryWatchdog`（P4-2 RSS 自重启，默认关；子键 `enabled`/`sampleIntervalMs`/`thresholdMB`/`action`，action=`close_sessions`|`exit`）、`guards`（FR-13 调度护栏，子键 `maxActions`/`taskTimeoutMs`/`repeatActionBreak`/`rebuildDepthCap`）。遗留的 `useRustCore` 键在现有 `~/.fusion-browser/config.json` 中会被静默忽略（Codable 丢弃未知键）——Rust 核心已在 E-17~20 / #68 移除。

P4-2 RSS 自重启启用示例：
```json
{"memoryWatchdog":{"enabled":true,"sampleIntervalMs":30000,"thresholdMB":200,"action":"close_sessions"}}
```

## 验收脚本（Phase 4）

| 脚本 | 用途 | 产出 |
|------|------|------|
| `scripts/verify_nonpersistent.py` | P4-1 FR-04 无痕落盘（lsof + 容器残留） | 终端 PASS/FAIL |
| `scripts/perf_bench.py` | P4-3 性能基准（scroll/screenshot/click 延迟 + AXTree 压缩比） | `scripts/perf-report.json` |
| `scripts/uma_coexist.py` | P4-4 UMA 共存（10 session×100 动作 + mlx 推理并发） | `scripts/uma-report.json` |
| `scripts/longrun_leak.py` | P4-5 1000-action 长跑无泄漏（RSS 四分位对比） | `scripts/longrun-report.json` |
| `scripts/navigate_execute_smoke.py` | navigate-via-execute SIGTRAP 修复验证（execute navigate 离主线程 → 引擎存活、页面加载） | 终端 PASS/FAIL |

均驱动 release 二进制（`swift build -c release` 后执行），live WKWebView 不在 `swift test` 覆盖范围。

视觉定位启用示例（`~/.fusion-browser/config.json` 增量）：
```json
{"visualLocator":{"endpoint":"http://127.0.0.1:11434","model":"mlx-community--Qwen2.5-VL-7B-Instruct-4bit","timeoutMs":30000,"enabled":true}}
```
注：`model` 须用 fusion-mlx 注册 ID（注册表用 `--` 非路径 `/`，如 `mlx-community--Qwen2.5-VL-7B-Instruct-4bit`），且该 VLM 已在 fusion-mlx 加载（`POST /v1/models/<id>/load`，需 admin Bearer）。

## 客户端协议

完整线协议参考：[`docs/PROTOCOL.md`](docs/PROTOCOL.md)。摘要：

### UDS 主路径

1. 连接 `/tmp/fusion-browser.sock`
2. 首帧必须为鉴权：`{"type":"auth","token":"..."}`，成功返 `{"type":"auth_ack","caps":95}`
3. 之后发请求（长度前缀 `[u32 BE length][JSON]`）：
   - 创建会话：`{"type":"create_session","payload":{"mode":"headless","initial_url":null,"max_actions":null,"task_timeout_ms":null,"credential_domain":null}}`
   - 执行动作：`{"type":"execute","payload":{"session_id":"...","action":"click","target_node_id":"e1","payload_text":null,"trace_id":"..."}}`
   - 关闭会话：`{"type":"close","session_id":"..."}`
4. JSON 字段为 snake_case（对齐 schema）。`target_node_id` 为裸 `eN`（非 `@eN`）。

冒烟客户端：`python3 scripts/smoke_client.py <token>`（默认 socket `/tmp/fusion-browser-smoke.sock`，需配套 config）。

### CDP 兼容层（`:9222`，默认关）

非真 Chrome，是翻译 cowork `cdp_client.py` 真实 CDP 传输的 shim。cowork 代码只读，契约由本层对齐：

- HTTP 发现：`GET /json`（返 `[{id,type,title,url,webSocketDebuggerUrl}]` 数组）、`GET /json/version`、`PUT /json/new?<url>`、`GET /json/close/<id>`（仅查 200，不拆 target）
- WS 升级：`ws://127.0.0.1:<port>/devtools/page/<targetId>`，无子协议、无 auth 头，帧 ≤10MiB
- WS 消息：`{id,method,params}` → `{id,result}`（caller 读嵌套：`Runtime.evaluate`→`result.result.value`、`Accessibility.getFullAXTree`→`result.nodes`（每节点带 `backendNodeId`）、`Page.captureScreenshot`→`result.data`（base64 PNG）、`Page.navigate`→`result.frameId`、`DOM.getDocument`→`result.root.nodeId`、`DOM.querySelector`→`result.nodeId`、`DOM.resolveNode`→`result.object.objectId`）
- 支持 Domain：Page（navigate/captureScreenshot/handleJavaScriptDialog + frameNavigated/lifecycleEvent）、Runtime（evaluate，非白名单 origin 拒绝 + consoleAPICalled）、Accessibility（getFullAXTree）、Input（dispatchMouseEvent 点击 elementFromPoint / dispatchKeyEvent Enter 提交 / insertText 录入）、Network（requestWillBeSent/responseReceived/loadingFinished）、DOM（getDocument/querySelector/resolveNode/focus/setFileInputFiles）、Emulation（no-op 占位）；Performance/HeapProfiler/Tracing 为 no-op 或最小返回。事件无 `id`（per spec），cowork `_dispatch_event` 缓冲 Network.*/Runtime.consoleAPICalled
- 鉴权：CDP 层不做 token 网关（cowork `Authorization: Bearer` 仅 `/json` 可选），安全由 EVALUATE origin 白名单 + UDS token 兜底

## 源码结构

| 文件 | 职责 |
|------|------|
| `main.swift` | 入口，装配 config→infra→server，启动 NSApplication run loop；cdpEnabled 时起 `FBCDPServer` |
| `Logging.swift` | os_log + stderr sink，分级日志 |
| `ErrorModel.swift` | FR-11 结构化错误码枚举 + `FBResult` |
| `Protocol.swift` | schema 的 Swift Codable 映射 + 长度前缀分帧（snake_case codec） |
| `Auth.swift` | FR-10 token 鉴权 + capability + EVALUATE origin 白名单 |
| `Config.swift` | FR-08 资源配额（按 RAM）+ FR-13 调度护栏 + watchdog 策略 + P4-2 `memoryWatchdog` 配置 + 配置加载 |
| `MemoryWatchdog.swift` | P4-2 进程级 RSS 监控（`mach_task_basic_info` 采样）+ 一次性 breach 恢复闭包 + 可插拔 sampler |
| `Observability.swift` | FR-12 metrics + trace_id + 凭据审计日志 |
| `Framing.swift` | FR-09 帧读取器（多帧拆分 + 超限背压丢弃） |
| `Session.swift` | 会话状态机 + 调度器（admit/canRebuild/幂等分类） |
| `Credentials.swift` | FR-05/T2.4 Keychain 凭据托管（存完整 cookie 属性，锁屏检测） |
| `AXWalker.swift` | T2.1 注入 JS walker 脚本 + 稳定映射（结构指纹/WeakRef）+ FBExtractedNode/Result |
| `AXTree.swift` | T2.1 提炼器（extract→解析→install 映射→Markdown 降维）+ T2.2 Sanitizer 规则目录/purge 策略 + Reducer |
| `WebView.swift` | FR-04/06 WKWebView 封装（Headless offscreen / Headed 窗口，无痕 dataStore）+ `evaluateJSSync`/`screenshotSync`（off-main 信号量）+ 完整 cookie 属性注入 |
| `SessionManager.swift` | FR-04/08 会话生命周期 + 配额强制（WKWebView 主线程创建）+ `firstSession`（CDP shim target 映射） |
| `ActionDriver.swift` | FR-06 动作派发 + NFR-R 分档 watchdog + 崩溃重建回放策略 + EVALUATE origin 校验 + 节点 id 归一化（剥离前导 @）+ T3.4 click node_stale 视觉兜底 |
| `UDSServer.swift` | FR-09/10 POSIX socket UDS 服务端 + 每 client 读循环 + 鉴权路由 |
| `CDPServer.swift` | T2.3/T3.3 CDP-WS shim：POSIX TCP + HTTP 发现 + WS 升级 + 帧编解码 + `FBCDPTranslator`（CDP 方法→ActionDriver，扩 Network/Console/Emulation/Page.lifecycleEvent/DOM）+ `FBCDPEventEmitter`（事件解耦，可确定性单测） |
| `VisualLocator.swift` | T3.4 视觉定位兜底：截图→fusion-mlx VLM `/v1/chat/completions` 预测 `{x,y}` + OOB 防护；可插拔 `FBHTTPClient` |

> E-17~20 / #68 已移除：`FBCoreBridge.swift`、`FBCoreWorkerPool.swift`、`Sources/FBCoreRust/`、`Plugins/FBCoreRustBuilder/`、`rust/fb-core/`——Rust 核心路径。AXTree 编译现走纯 Swift（`FBAXTreeReducer.toMarkdown` + `JSONDecoder`），在 `AXTree.swift` 的 `FBAXTreeExtractor.extract` 内——即 Rust 核心失败时一贯回退的那条路径。

## 路线图（详见 PRD §4）

- Phase 1（基座）：引擎基座 + 六大基础设施 + action 透传 + 分档 watchdog ✓
- Phase 2：AXTree 提炼器 + 反注入 Sanitizer + CDP 兼容层（4 Domain）+ 凭据闭环 ✓
- Phase 3：多节点适配（T3.2）+ CDP 扩 Domain + 事件（T3.3）+ 视觉定位兜底（T3.4）✓；agent-studio 全对接（T3.1）跨项目，已上游落地
- Phase 4（生产化加固）：无痕落盘验收（P4-1，FR-04）+ RSS 自重启（P4-2）+ 性能基准套件（P4-3）+ UMA 共存基线（P4-4，PRD T1.5）+ 1000-action 长跑无泄漏（P4-5）✓
- Rust 核心引擎（PRD §4.3 module 5，T1.4）：原为标志位门控 `fb_core` 静态库 + C-ABI FFI；**已在 E-17~20 / #68 移除**——PRD §2 T1.4 评估结论为纯 Swift 足以覆盖 Sanitizer+AXTree（Rust 路径默认关，纯 Swift reducer 为其回退）。审计 E-17~20（构建不可移植 / worker pool 非专用 FIFO / 无运行时对齐检查 / Cargo.lock 未进插件输入）一并随移除关闭。默认关的纯 Swift 路径现为唯一路径 ✓
