# fusion-browser 全面审视报告（2026-10-16）

- 审视对象：`/Users/dahai/fusion/fusion-browser`（HEAD `95bc0a8`，v0.2.1，main 分支）
- 审视方式：全量源码阅读（20 个 Swift 源文件，9205 行；14 个测试文件）+ 测试/脚本/CI/文档交叉核对 + 本机构建与全量测试实测
- 本机验证结果：`swift build -c release` **构建绿（9.5s）**；`swift test --disable-sandbox` **215/215 全部通过**（7.6s）
- 方法说明：报告发现均经子代理通读源码产出，P0/P1 级关键发现已由主线逐条抽查源码原文复核属实；标注〔复核〕的为已确认，其余为待复核但证据充分

---

## 一、总体结论

**质量评级：B+（中上，适合作为企业级组件继续演进，但存在 3 个应在下个迭代内修复的结构性缺陷）。**

这是一座被审计"雕"出来的代码库：注释中保留了几乎每一个历史缺陷（E-*/H-*/L-*/F-*/B-*/R-*/P-*）的根因、竞态窗口与修复不变量，fail-closed 意识贯穿认证、能力、origin 白名单、会话所有权全部关键门禁；215 个确定性测试 + 10 个 live harness + 双 job CI 的纪律在同级项目中明显高于平均。

但本轮审视发现，残余风险集中在四类此前审计未覆盖的结构性盲区：

1. **多连接/多会话场景的正确性假设缺口**——CDP 能力（caps）是服务器级单例，多连接互相污染权限（可越权）；
2. **跨线程销毁路径未按既有标准补齐**——FBWebView 自身字段存在数据竞争，reaper 与主线程之间存在真实 AB-BA 死锁窗口；
3. **失败语义静默降级**——click/type 执行失败被吞掉并返回"成功"，对 agent 消费方而言"报成功但没执行"比崩溃危害更大；
4. **CI 硬门缺自我保护**——harness 文件缺失静默跳过、SKIP_UMA 分支漏掉 R-7 SLA 门，"绿"不完全等于"全门都跑过"。

另有一个下游契约风险：`PROTOCOL.md` 的 CDP 认证描述落后代码一至两个迭代（下文 D-1）。

---

## 二、发现清单

严重级别：P0=阻断发布 / P1=迭代内必修 / P2=计划修复 / P3=择机。本仓当前无 P0。

### 2.1 并发与生命周期（P1）

#### C-1〔复核〕CDP `authedCaps` 服务器级共享，多连接权限互相污染 — P1
`CDPServer.swift:37,147-153`。caps 存在 `FBCDPServer` 而非 `FBCDPConnection` 上：
```swift
fileprivate private(set) var authedCaps: FBCapabilities = []
```
连接 A 以只读 token 升级后，连接 B 以 `.all` token 升级会覆盖 A 的 caps，此后 A 的所有 CDP 方法按 `.all` 执行——跨连接越权。反之 B 断开后 A 被降级；且连接关闭不清除 caps，最后一个客户端的权限永久驻留。
**修复**：caps 移入 `FBCDPConnection`，`executeAction` 由连接传入自己的 caps。

#### C-2〔复核〕Session 关闭路径 AB-BA 死锁（sessionmgr 队列 ↔ main） — P1
`Session.swift:128-133` 配合 `SessionManager.swift:198-217`。`reapIdle()` 定时器跑在 sessionmgr 串行队列上，锁外调用 `s.close()` → 非主线程 → `DispatchQueue.main.sync { wv.destroy() }`。若主线程此刻正在执行任何 `manager` 的 `queue.sync`（`close/touch/count/listIds/create`），即形成 reaper（占 sessionmgr 队列）等 main、main 等 sessionmgr 队列的永久死锁。
**修复**：`close()` 的 webview 销毁改 `DispatchQueue.main.async`（局部强引用 `wv` 已保证存活），或为 manager 引入"禁止 main.sync"不变量并审计全部调用点。

#### C-3 FBWebView 内部状态跨线程无同步 — P1
`WebView.swift:15,24,16,422-429`。`webView`/`jsWedged`/`hostWindow` 为普通属性：`evaluateJSSync/injectCookies/screenshotSync/navigate` 在后台线程读 `webView`，`destroy()` 在 main 上置 nil，`jsWedged` 在 watchdog 线程写、完成回调线程读写。FBSession 已按 E-21 用 NSLock 修过同构问题，FBWebView 自身没修——这是 Swift 6 strict concurrency 会报编译错级别的 UB。
**修复**：统一加锁访问器；销毁后后台访问走捕获的局部强引用 + closing 检查。

#### C-4 listenFd / 客户端 fd 的 close 竞争 — P2
`UDSServer.swift:64-67,74,355-377`。`stop()` 的 cancel handler 无锁读写 `listenFd`，与 `acceptOnce` 的 `accept(listenFd,...)` 竞争；同理客户端连接：`writeAll` 的 EAGAIN 重试期间 read source cancel 异步 close(fd)，后续 `write` 可能命中被 OS 复用的新 fd——跨连接数据泄漏窗口（窄但真实）。
**修复**：close 前锁内置 -1，I/O 前校验 fd 有效；或 close 交由唯一 cancel handler 串行执行。

#### C-5 navigate 超时路径在后台线程调 `WKWebView.stopLoading()` — P2
`WebView.swift:267,278`。超时分支直接在等待导航的后台线程调 `stopLoading()`，违反 WKWebView 主线程契约（本仓其他地方反复强调 off-main → exit 133），且可能与 `destroy()` 竞争（叠加 C-3）。
**修复**：main-hop stopLoading 并先判 nil。

#### C-6 Framing 超时只在"下一次 append"时检查，完全静默的半帧永不超时 — P2
`Framing.swift:49-62`。B-4 的部分帧超时依赖新字节到达触发；客户端发半个 length prefix 后挂住连接，超时永不置位，连接与 8MB 缓冲一直被持有。
**修复**：在连接层加 dispatch timer 主动扫描 `partialStartedAt`，超时主动断开。

### 2.2 动作执行与失败语义（P1）

#### A-1〔复核〕click/type 失败被静默吞掉并返回"成功" — P1
`ActionDriver.swift:216-261`。三层静默失败：(a) evaluate 超时/返回 nil → `if let raw` 不成立，直接落到 extract 并返回无 error 的成功响应；(b) `ok:false && stale:false`（脚本异常返回）不处理；(c) JSON 解析失败（`try?`）静默。结果：点击/输入根本没发生，调用方拿到成功 + 新 AXTree，代理循环基于错误状态继续推进。visual fallback 分支的 `e.click()` 返回 `'miss'` 同样被忽略（L240）。
**修复**：`ok:false`（含 stale 与否）统一返回失败；raw 缺失/解析失败返回 `internalError`。

#### A-2 watchdog 超时后泄漏的 block 仍会真实执行动作，且与 rebuild 状态机竞争 — P1
`ActionDriver.swift:118-135,362-390`。取消令牌只在 block 入口检查一次；调用方收 `.timeout` 后 `handleCrash` 走 rebuild，此时泄漏 block 可能仍在写同一 webview / 重建 `__fbMap` → 动作重复执行与映射竞态。join 二次等待仍是完整 `timeoutMs`，最坏 2×timeout（与 R-9 已声明的限制一致，但泄漏执行是新问题）。
**修复**：dispatch 各阶段插入 cancel 检查点；或超时即把会话标记为不可用直至泄漏 block 结束。

#### A-3 fingerprint 为空时跳过 JS 指纹校验，盲目点击 — P2
`ActionDriver.swift:213-215,251`。`resolve(nid)` 返回 nil 时 fp 传空串，JS 侧 `if(expectFp && fp!==expectFp)` 对空 expectFp 直接放行——映射与 `__fbMap` 不同步的任何场景下会绕过校验点错节点。未知 id 本应直接 `node_stale`。
**修复**：`mp == nil` 提前返回 `nodeStale`。

#### A-4 visual fallback 的 30s VLM 超时发生在 click watchdog（毫秒级）之内 — P2
`ActionDriver.swift:224-252`。`FBVisualLocatorConfig.timeoutMs` 默认 30000，click watchdog 档为 50ms–2s；fallback 真正发起 VLM 请求几乎必然触发 watchdog 超时 → 会话误判 crashed、VLM 结果作废。T3.4 在设计上不可用（默认 OFF 掩盖了这一点）。
**修复**：fallback 前检查剩余预算，或为该动作放宽 watchdog 档。

#### A-5 markdown 输出未转义，页面内容可注入伪造节点行 — P2
`AXTree.swift:68-81`。`name`（截自页面 `innerText`）、`url`、`title` 原样嵌入 `- [@eN] role "name"` 行。恶意页面可注入换行 + 伪造节点行或指令文本，直接欺骗下游 LLM 的节点定位与动作决策——对 agent 是真实注入面（与本仓防注入 sanitizer 的目标自相矛盾）。
**修复**：对 name/url/title 做换行与 markdown 标记剥离/转义。

#### A-6 `Input.insertText` 用裸赋值，React 受控输入静默丢字 — P2
`CDPServer.swift:1313-1321`。`resolveType` 已按 R-10 改用原生 prototype value setter + InputEvent，CDP 的 `Input.insertText` 仍是 `ae.value=...` + 旧式 `Event('input')`，React/Vue 页面文本不进框架状态且返回 `'ok'`。
**修复**：复用 resolveType 的 nativeSetter 路径。

#### A-7 AXWalker 命中测试对 `pointer-events:none` 判定反向 — P2
`AXWalker.swift:190-196`。`elementFromPoint` 跳过 `pointer-events:none` 元素：含禁用态/装饰层的节点会被误判 hidden 并 purge（L-4 后永不可操作）；反之 `opacity:0` 透明覆盖层若自身可 hit-test 会被判可见。影响 purge/可操作性这一安全相关语义。

#### A-8 CDP 事件推送依赖 server 级 session，多会话下报错状态 — P2
`CDPServer.swift:480-484,496`。`ensureSession()` 取 `firstSession()` 或新建，读到的 `lastResponse`/console buffer 可能属于另一会话；单会话无害，多会话是真实正确性缺陷。

### 2.3 凭据与安全面（P1）

#### S-1〔复核〕Keychain 写入失败时错误码误报为 `.credentialInjected` — P1
`Credentials.swift:55-56`。`SecItemAdd` 失败（磁盘满、权限等）返回的是表示"已注入成功"的 `.credentialInjected`，上层统计与决策会把真实失败计入成功路径，违背文件头"诚实区分 engine bug 与 keychain 不可用"的设计原则。
**修复**：新增专用错误码 `.credentialStoreFailed`。

#### S-2 per-cookie 删除的 path 缺省可能与存储键不一致，Keychain 残留会话 cookie — P2
`Credentials.swift:133-186`。存储键为 `domain|name|path`；删除侧 `cookieAttrs["path"] ?? "/"`，若调用方传入的精简 cookie 字典缺 `path`（实际存的是 `/admin`），`SecItemDelete` 静默 not-found，过期登录态残留 Keychain（E-14 语义被绕过）。
**修复**：not-found 时回退按 `domain|name` 前缀枚举删除，并把 not-found 记为可观测审计事件。

#### S-3 domain 直接拼入复合键，无输入校验 — P2
`Credentials.swift:102-106,148`。domain 为客户端可控字符串（`CreateSessionRequest.credentialDomain`），含 `|` 时可发生跨会话键碰撞（误删/误读他域凭据）。
**修复**：domain 规范化 + 拒绝空串/含 `|`/非法字符。

#### S-4〔复核〕CDP navigate/`PUT /json/new` 对 origin 解析失败的 URL fail-open — P1
`CDPServer.swift:285,855-860`。`originOfUrl(url)` 解析不出 scheme/host 时返回 `""`，`if let navOrigin = ..., !navOrigin.isEmpty` 整个门禁被跳过，原始字符串直接导航——构造解析不出的 URL 变体即可绕过 E-15 白名单，再配合 evaluate 完成 navigate+evaluate 配对攻击（正是原注释要防的）。
**修复**：解析失败一律 deny，仅保留显式 `data:`/`about:` 豁免（豁免收进返回 nil 分支内）。

#### S-5 logout 在主线程调用时静默跳过 cookie 撤销 — P2
`WebView.swift:199-202` + `SessionManager.swift:448`。Keychain 已删但 runtime cookie 被跳过，登录态仍留在 webview，只有一条 warn，违背 F-12 "logout 必须撤销两层"。
**修复**：main 上异步链式删除后 signal，或拒绝并返回错误。

#### S-6 os_log `%{public}@` 全量输出，敏感字段持久落入系统日志 — P3
`Logging.swift:90`。Credentials 的 `path=`、审计日志的 domain 均以 public 级别进统一日志（同机 admin 可 `log show` 读取）。建议敏感行改 `%{private}@`。

### 2.4 健壮性杂项（P2/P3）

| # | 位置 | 问题 | 级别 |
|---|---|---|---|
| M-1 | `MemoryWatchdog.swift:67-75`〔复核〕 | `stop()` 的 `queue.sync {}` 在 watchdog 回调线程内被 `onBreach`（默认动作 close_sessions 的恢复逻辑）自调用即死锁 | P1 |
| M-2 | `MemoryWatchdog.swift:56-65` | 二次 `start()` 泄漏旧 timer，tick 频率翻倍、breach 冷却语义破坏 | P2 |
| M-3 | `MemoryWatchdog.swift:157-201` | `totalRSSBytes` 计入全部 WebKit 子进程（Networking/GPU 常驻几百 MB），默认 200MB 阈值开机即 breach，watchdog 等效失效 | P3 |
| M-4 | `UDSServer.swift:41-48` | `sun_path`(104B) 超长静默截断且可能无 NUL，bind 在垃圾路径上"成功"，客户端连不上而日志显示 listening | P2 |
| M-5 | `UDSServer.swift:347` | AuthAck 编码失败 `try?` 吞掉，客户端无限等 ack | P3 |
| M-6 | `UDSServer.swift:236-258,272` | 限流只对 `.execute`；认证阶段可无限试 token，create 请求可打满 main | P3 |
| M-7 | `UDSServer.swift:97-102` | `stop()` 不清理客户端连接（read source/fd 残留） | P3 |
| M-8 | `main.swift:30` | `try?` 混淆"文件不存在"与"不可读"，安全敏感配置加载 fail-open 语义（兜底 deny-all，实际风险低） | P3 |
| M-9 | `SessionManager.swift:474-482` | `firstSession()` 只查 state，可能返回 mid-close 会话（与 `get(_:)` 的 isClosing 防护不一致） | P3 |
| M-10 | `SessionManager.swift:409-417` | close 所有权拒绝的 remove/put-back 窗口：并发 get/close 短暂看到 sessionNotFound | P3 |
| M-11 | `RateLimiter.swift:27-32` | `ratePerSec=0`/`burst=0` 配置错误静默全拒（等效 DoS）且无告警 | P3 |
| M-12 | `CDPServer.swift:85-105` | maxConnections 检查与插入间 TOCTOU（轻微超限） | P3 |
| M-13 | `CDPServer.swift:1356-1361` | FNV 回退哈希可与 `eN` 整数碰撞，`resolveNode` 可能解引用错误 idStr | P3 |
| M-14 | `CDPServer.swift:295-297` | `/json/close/<id>` 恒返 200 不关闭任何会话，调用方误以为已清理 | P3 |
| M-15 | `CDPServer.swift:545-558` | `writeAll` EAGAIN 时 `usleep(1000)` 忙等，无写超时上限 | P3 |
| M-16 | `VisualLocator.swift:175-179` | `numberValue` 未排除 Bool，`{"x":true}` 被接受为 (1,1) 坐标 | P3 |

### 2.5 Python 客户端（v0.2.1）

| # | 位置 | 问题 | 级别 |
|---|---|---|---|
| P-1 | `client.py:168-194` | 帧读取中途超时后局部 `hdr`/`body` 已读字节丢失但连接不关、`_authed` 仍 True，下次请求复用失步连接——可能从上一响应 body 中间读起，长度字段变任意值（最坏 4GB），请求/响应错配到别的 session | P1 |
| P-2 | `client.py:199-206` | auth 失败时假定 ack 为 error 帧，非预期帧 payload 产出 `code="unknown"` 误导异常，掩盖真实失配 | P2 |
| P-3 | `client.py:244` | 日志读 camelCase `credentialInjected`，线上是 snake_case（服务端 `.convertToSnakeCase`），恒打 None | P3 |

P-1 的修复：捕获 `socket.timeout`/`OSError` 一律 `close()` 后抛错；length 加上限（如 64MB）。

---

## 三、测试与 CI

### 测试覆盖缺口

| # | 问题 | 级别 |
|---|---|---|
| T-1 | `FBUDSServer`/`FBClientConnection.onReadable` 的并发路径零确定性测试（多客户端并发、EAGAIN 慢客户端、批量帧跨 read 排水无损性）——`IntegrationTests.swift:139-177` 只测了纯函数 `splitBatch` | P1 |
| T-2 | `perf_multipage.py:215-222` scored 页数无下限：10 页中 9 页 extract 0 节点被 excluded，剩 1 页也能算 P50 并 PASS，R-7 SLA 门禁可被"排除"掏空，违反脚本自述的 anti-false-pass 原则 | P1 |
| T-3 | SessionManager 并发测试只断言"不崩"，不断言无残留条目/容量归零 | P2 |
| T-4 | Framing 溢出/背压的真实 socket 行为可做成确定性单测（不需要 WKWebView，不受 ARCH-3 约束）但未做 | P2 |
| T-5 | `verify_gateway_r10.py`（唯一证明 gateway↔browser 容量面打通的端到端 harness）不在任何 gate 中 | P2 |

### 测试质量

- **假测试（P2）**：`InfraTests.swift:232-243` `testRebuildDepthNotConsumedByNonIdempotentCrash` 在测试体内复刻了"E-23 顺序"if，没有调用生产 `handleCrash`——回归照样绿。建议把判定逻辑抽成可注入纯函数后针对真实实现断言。
- **时序脆弱（P3）**：`CDPServerTests` 8 处 `usleep(100_000)` 等待 server 就绪；`InfraTests:522/535` 限流 refill 依赖 15ms/120ms 精确窗口，慢机 flaky。
- **live 脚本裸 `assert`（P3）**：`ownership_smoke.py:101,111`、`multinode_smoke.py` —— Python `-O` 下被剥除静默变 pass。统一改 `raise RuntimeError`。
- 正面确认：无占位/恒真断言之外的问题；InjectionFuzzTests 的 2^11 幂集穷举与 fail-closed 矩阵质量优秀。

### CI 门禁漏洞

| # | 问题 | 级别 |
|---|---|---|
| G-1〔复核〕 | `release-gate.yml:109-114` SKIP_UMA 分支的内联 harness 清单漏掉 `perf_multipage.py`（R-7 SLA 硬门）；设 `SKIP_UMA=1` 即从 CI 静默消失。workflow 内"8 of 9 / 7 of 8"计数自相矛盾 | P1 |
| G-2〔复核〕 | `release_gate.sh:93-99` harness 文件缺失时 `info "skipping"`——重命名/删除脚本文件不会 fail，live-path gate 可变 build-only 空壳全绿。硬门应默认 fail-on-missing | P1 |
| G-3 | self-hosted runner 离线时 required check 永远 pending，live 路径 CI 覆盖是"尽力而为"；建议加 runner 心跳/定时空跑告警 | P2 |
| G-4 | 测试数漂移：gate 脚本/workflow/ARCHITECTURE 写死 198，实际 215；README 同文件 183→210→213。数字一旦被解析断言会出错 | P2 |
| G-5 | `SKIP_UMA` 是仓库级 var，有 var 写权限者即可静默关检查；`xcode-select ... \|\| true` 吞错；self-hosted 上改 `--global` git config 残留 | P3 |

---

## 四、文档与契约一致性（对下游 cowork 的实际风险）

| # | 问题 | 级别 |
|---|---|---|
| D-1 | **`PROTOCOL.md:196` 与代码/CLAUDE.md 直接矛盾**：文档写 "CDP layer does NOT token-gate"，实际 H-5 后 CDP HTTP `/json` + WS upgrade 均 Bearer-gate 且 fail-closed。cowork 照旧文档实现会被 401/403。必须更新 §7 | P1 |
| D-2 | `PROTOCOL.md` 缺失已落地契约：`metrics`/`capacity` 请求类型；错误码 `not_owner`/`auth_denied`/`evaluate_denied`/`credential_locked`；`tokenSystemCaller`（影响所有 per-call-dial 调用方）完全未提 | P2 |
| D-3 | CLAUDE.md/ARCHITECTURE 写 `macos-14`，workflow 实际 `macos-15`（macos-14 只有 Swift 5.10 会挂，照文档"恢复"会弄坏 CI） | P2 |
| D-4 | live harness 数量：文档说 9，`release_gate.sh` HARD 列表实为 10（perf_multipage 加入后未同步） | P2 |
| D-5 | `verify_gateway_r10.py` 在 README/ARCHITECTURE harness 清单缺席；`scripts/.github/workflows/` 是可疑的嵌套重复目录，疑似误提交，应清理 | P3 |

---

## 五、修复优先级建议

**第一波（迭代内，均为小改动、高收益）**
1. C-1：CDP caps 移到连接级（越权，改动小）
2. S-4：origin 解析失败 deny（安全门 fail-open，改动小）
3. A-1：click/type 失败诚实上报（agent 正确性根基）
4. G-1/G-2：CI 硬门自保（SKIP_UMA 改由脚本内部处理；harness 缺失默认 fail）
5. D-1：更新 PROTOCOL.md §7（对下游契约）
6. S-1 + M-1 + P-1：三个各自一行级的死锁/误报/失步修复

**第二波（下个迭代）**
- C-2/C-3：销毁路径死锁与 FBWebView 数据竞争（需要一次专门的并发梳理）
- A-2：watchdog cancel 检查点
- A-5：AXTree markdown 转义（agent 注入面）
- T-1/T-2：UDS 并发单测 + perf_multipage scored 页数下限
- D-2~D-4：契约文档补齐

**第三波（择机）**
- 其余 P2/P3：fd 竞争、framing 主动超时、RateLimiter 参数防御、visual fallback 预算、日志 private 化等

---

## 六、方法论附注

- 四个子代理分别覆盖：①传输与会话管理层 ②动作驱动与 CDP 层 ③凭据/配置/可观测性 + Python 客户端 ④测试/脚本/CI/文档一致性；主线对 P0/P1 关键主张逐条抽查源码复核（authedCaps 单例、origin fail-open、watchdog queue.sync、gate skip、SKIP_UMA 清单均属实）。
- 已核实并排除的疑点：帧编码 u32 BE 与 Python `>I` 一致；snake_case 编解码两侧对称；watchdog 冷却重臂（L-20）逻辑正确；token bucket 单调时钟、拒绝不耗 token 无绕过；`_recv_one` 短读处理正确（除超时失步）。
- 本报告为只读审视，未修改任何仓库代码。
