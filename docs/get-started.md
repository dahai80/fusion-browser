---
doc_id: fusion-browser/get-started
product: fusion-browser
class: app
entry: service
doc_type: get-started
title: { zh: "fusion-browser 快速上手", en: "fusion-browser quick start" }
audience: engineer
status: draft
version: 0.2.4
updated: 2026-11-07
owner: "@dahai"
source_of_truth:
  - docs/DEVELOPMENT.md
  - CLAUDE.md
  - Package.swift
---

# fusion-browser 快速上手（Get Started）

> 目标：构建引擎、启动 UDS 服务、用 Python 客户端完成一次 create → execute → close。

## 1. 前置条件

- macOS 14+，Apple Silicon；Swift 6 工具链（`swift` 命令可用）
- 纯 Swift 构建：无需 Rust、无需 Python venv（E-17~20 / #68 已删 Rust core）
- 可选：Python3（仅跑 `scripts/` 验证 harness 与 Python 客户端时需要）

## 2. 构建与启动

```bash
cd /Users/dahai/fusion/fusion-browser
swift build -c release      # 产物 -> .build/release/fusion-browser
.build/release/fusion-browser   # 启动 UDS 服务（CDP 默认关）
```

确认点：进程标题为 `fusion-browser`，`/tmp/fusion-browser.sock` 出现（默认路径，`Config.swift` `socketPath` 默认值）。

## 3. 跑通第一条会话（Python 客户端）

```bash
cd client/python
pip install -e ".[test]"
pytest tests/ -v            # 客户端自测：fake UDS server，无需真实引擎
python - <<'PY'
from fusion_browser_client import FusionBrowserClient
c = FusionBrowserClient()
s = c.create_session()
print(c.execute(s, "navigate", {"url": "about:blank"}))
print(c.close(s))
PY
```

确认点：`navigate` 返回结构化结果（snake_case 键）；无 token 时按默认能力集放行本地操作。

## 4. 测试

```bash
swift test --disable-sandbox    # 约 300 个确定性用例（--disable-sandbox 仅为兼容保留）
swift test --disable-sandbox --filter CDPServerTests   # 单类
```

已知限制：WKWebView 活路径（真实 AX walker、截图、导航）不能在 `swift test` 覆盖（无主 run loop 会死锁，ARCH-3），由 `.github/workflows/release-gate.yml` 的 self-hosted GUI job（`scripts/release_gate.sh`，11 个活 harness）把关。

## 5. 配置（可选）

`~/.fusion-browser/config.json`，部分 JSON 即可，缺失字段回退 `FBEngineConfig.default`。常用键：`socketPath`、`cdpEnabled`、`cdpPort`、`authToken`、`tokenCapabilities`、`allowedOrigins`。全量见 `docs/config-reference.md`。

## 常见问题速查

```yaml
troubleshooting:
  - q: { zh: "evaluate 返回 evaluate_denied", en: "evaluate returns evaluate_denied" }
    a: { zh: "默认 token 无 .evaluate 能力，在 tokenCapabilities 里显式加 evaluate/all。", en: "The default token lacks .evaluate; add it explicitly via tokenCapabilities." }
  - q: { zh: "CDP 端口连不上", en: "CDP port unreachable" }
    a: { zh: "cdpEnabled 默认 false，配置里显式开启后重启引擎。", en: "cdpEnabled defaults to false; enable it in config and restart the engine." }
```

## 提交检查清单

- [x] 命令来自 `docs/DEVELOPMENT.md` 与 `client/python/README.md`，真实可执行
- [x] 每步有确认点
- [x] zh/en 成对（命令除外）
