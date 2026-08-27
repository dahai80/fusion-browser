#!/usr/bin/env python3
# T3.1 live interop: drive agent-studio's REAL BrowserTool against the REAL
# fusion-browser release binary. agent-studio's own tests use a _FakeBrowserServer
# (mocked socket), so no live round-trip was ever exercised. This closes that gap:
# imports tools.browser_tools.BrowserTool, points its config at a live binary
# socket, and runs the PRD §9 acceptance flow (create -> navigate -> extract ->
# click -> node_stale re-extract -> close). Live WKWebView needs the release
# binary (swift test has no main run loop).

import asyncio
import json
import os
import signal
import subprocess
import sys
import time

SOCK = "/tmp/fusion-browser-interop.sock"
TOKEN = "interop-token"
CONFIG = os.path.expanduser("~/.fusion-browser/config.json")
BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "fusion-browser")
AGENT_STUDIO = "/Users/dahai/fusion/fusion-agent-studio"

# agent-studio BrowserTool reads BROWSER_CONFIG_PATH for browser_available();
# the connection itself uses _load_config (socketPath + authToken).
os.environ.setdefault("PYTHONPATH", AGENT_STUDIO)
sys.path.insert(0, AGENT_STUDIO)

import tools.browser_tools as bt  # noqa: E402

PAGE = ("data:text/html;base64," +
        __import__("base64").b64encode(
            ("<html><body>"
             "<button id=a>Login</button>"
             "<input id=b placeholder=Email>"
             "<a id=c href=about:blank>Next</a>"
             "<button id=d>Submit</button>"
             + "<p>filler</p>" * 10 + "</body></html>").encode()).decode())


def write_config():
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        json.dump({"socketPath": SOCK, "authToken": TOKEN, "logLevel": "error",
                   "allowedOrigins": ["https://example.com"]}, f)


async def run():
    tool = bt.BrowserTool()
    results = []

    def step(label, coro_text):
        ok = "Error:" not in coro_text and "error" not in coro_text.lower()[:20]
        results.append((label, ok, coro_text[:200]))
        print(f"[{label}] {'OK' if ok else 'FAIL'}: {coro_text[:180]}")
        return coro_text

    # 1. create_session headless
    r = await tool.execute(action="create_session", mode="headless", url=PAGE)
    out = step("create_session", r)
    if "session_id=" not in out:
        return False, results
    sid = out.split("session_id=")[1].split()[0]
    await asyncio.sleep(2)

    # warm __fbMap (first click needs prior extract per fusion-browser constraint)
    r = await tool.execute(action="extract", session_id=sid)
    step("extract_warmup", r)

    # 2. navigate returns ax_tree_markdown
    r = await tool.execute(action="navigate", session_id=sid, url=PAGE)
    step("navigate", r)

    # 3. extract returns markdown not raw nodes
    r = await tool.execute(action="extract", session_id=sid)
    out = step("extract", r)
    md_ok = "ax_tree" in out.lower() or "@e" in out or "[AXTREE]" in out
    results.append(("extract_markdown_present", md_ok, out[:120]))

    # 4. click a button node (rotate targets, exclude link e3 per FR-13 + nav-away)
    #    @e1/@e2/@e4 — but node ids may be e1.. without @ prefix; try both.
    clicked_ok = False
    for tgt in ["@e1", "e1", "@e2", "e2", "@e4", "e4"]:
        r = await tool.execute(action="click", session_id=sid, target_node_id=tgt, trace_id="interop-click")
        if "node_stale" in r:
            # contract: tool auto re-extracts on node_stale, returns fresh tree
            step(f"click_{tgt}_stale_reextract", r)
            clicked_ok = True
            break
        if "Error:" not in r:
            step(f"click_{tgt}", r)
            clicked_ok = True
            break
        step(f"click_{tgt}_fail", r)
    results.append(("click_resolved", clicked_ok, ""))

    # 5. close
    r = await tool.execute(action="close_session", session_id=sid)
    step("close_session", r)

    all_ok = all(ok for _, ok, _ in results if ok is not None)
    return all_ok, results


def main():
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    write_config()
    if not os.path.exists(BIN):
        print(f"[interop] FAIL: binary missing: {BIN}")
        sys.exit(1)
    proc = subprocess.Popen([BIN], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    time.sleep(1.5)
    if proc.poll() is not None:
        print("[interop] FAIL: binary exited early")
        sys.exit(1)

    report = {"ts": int(time.time()), "ok": False, "steps": []}
    try:
        ok, steps = asyncio.run(run())
        report["steps"] = [{"step": s, "ok": o, "detail": d} for s, o, d in steps]
        report["ok"] = bool(ok)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        if os.path.exists(SOCK):
            os.unlink(SOCK)
        try:
            os.remove(CONFIG)
        except Exception:
            pass

    out = os.path.join(os.path.dirname(__file__), "interop-report.json")
    with open(out, "w") as f:
        json.dump(report, f, indent=2)
    print(f"\n[interop] ok={report['ok']} report={out}")
    sys.exit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()
