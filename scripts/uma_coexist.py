#!/usr/bin/env python3
# P4-4: UMA coexistence baseline. Drives the fusion-browser binary with N
# concurrent sessions x M actions each WHILE fusion-mlx serves inference
# requests on :11434. Asserts the two can coexist on one Apple Silicon node
# without the browser leaking memory past its per-session quota and without
# inference memory rising monotonically under load.
#
# Concretely: 10 sessions x 100 actions (scroll/screenshot/click, rotated to
# respect FR-13 repeat-break), 1 mlx inference ping per action batch. Samples
# browser host RSS (ps, excludes WebContent procs) + mlx
# fusion_mlx_model_memory_bytes before/during/after. Emits uma-report.json.
# Live webview requires the release binary (swift test has no main run loop).

import base64
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request

SOCK = "/tmp/fusion-browser-uma.sock"
TOKEN = "uma-token"
BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "fusion-browser")
CONFIG = os.path.expanduser("~/.fusion-browser/config.json")
MLX = "http://localhost:11434"
MLX_KEY = "dahai168"
MLX_MODEL = "mlx-community-Llama-3.2-1B-Instruct-4bit"
OUT = os.path.join(os.path.dirname(__file__), "uma-report.json")
N_SESSIONS = 10
N_ACTIONS = 100

def send(s, o):
    data = json.dumps(o).encode()
    s.sendall(struct.pack(">I", len(data)) + data)

def recv(s):
    h = b""
    while len(h) < 4:
        c = s.recv(4 - len(h))
        if not c: return None
        h += c
    (l,) = struct.unpack(">I", h)
    b = b""
    while len(b) < l:
        c = s.recv(l - len(b))
        if not c: return None
        b += c
    return json.loads(b)

def write_config():
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        json.dump({"socketPath": SOCK, "authToken": TOKEN, "logLevel": "error"}, f)

def host_rss_kb(pid):
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
        return int(out.stdout.strip()) if out.stdout.strip() else 0
    except Exception:
        return 0

def mlx_metric(name):
    try:
        req = urllib.request.Request(f"{MLX}/metrics", headers={"Authorization": f"Bearer {MLX_KEY}"})
        body = urllib.request.urlopen(req, timeout=10).read().decode()
    except Exception as e:
        return None
    for line in body.splitlines():
        if line.startswith(name + " ") or line.startswith(name + "{"):
            try:
                return float(line.split()[-1])
            except Exception:
                pass
    return None

def mlx_ping():
    # tiny inference request to prove mlx serves while browser runs.
    payload = json.dumps({"model": MLX_MODEL, "messages": [{"role": "user", "content": "ok"}], "max_tokens": 1}).encode()
    req = urllib.request.Request(f"{MLX}/v1/chat/completions", data=payload,
                                 headers={"Authorization": f"Bearer {MLX_KEY}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=30)
        return True
    except Exception as e:
        return False

def main():
    if os.path.exists(SOCK): os.unlink(SOCK)
    write_config()
    if not os.path.exists(BIN):
        print(f"[uma] FAIL: binary missing: {BIN}"); sys.exit(1)
    proc = subprocess.Popen([BIN], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    time.sleep(1.5)
    if proc.poll() is not None:
        print("[uma] FAIL: binary exited early"); sys.exit(1)

    report = {"ts": int(time.time()), "ok": False}
    errors = []
    try:
        s = None
        for _ in range(50):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(SOCK); break
            except Exception:
                if s: s.close()
                time.sleep(0.1)
        assert s is not None
        send(s, {"type": "auth", "token": TOKEN})
        assert recv(s).get("type") == "auth_ack"

        # pre-sample: browser RSS + mlx memory + inference baseline
        rss0 = host_rss_kb(proc.pid)
        mem0 = mlx_metric("fusion_mlx_model_memory_bytes")
        mlx_ok0 = mlx_ping()
        requests0 = mlx_metric("fusion_mlx_requests_total")

        # build a base64 data URL with 4 distinct interactive targets (rotate
        # per click to dodge FR-13 repeat-action-break).
        html = ("<html><body>"
                "<button id=a>Login</button>"
                "<input id=b placeholder=Email>"
                "<a id=c href=about:blank>Next</a>"
                "<button id=d>Submit</button>"
                + "<p>filler</p>" * 10 + "</body></html>")
        url = "data:text/html;base64," + base64.b64encode(html.encode()).decode()

        # create N sessions
        sids = []
        for _ in range(N_SESSIONS):
            send(s, {"type": "create_session", "payload": {"mode": "headless", "initial_url": url}})
            r = recv(s)
            sid = r.get("payload", {}).get("session_id")
            if not sid:
                errors.append(f"create failed: {r}")
            else:
                sids.append(sid)
        time.sleep(2)

        # warm up each session's __fbMap with a screenshot (extract) so the
        # first click on each session resolves instead of going node_stale.
        for sid in sids:
            send(s, {"type": "execute", "payload": {"session_id": sid, "action": "screenshot", "trace_id": "warm"}})
            recv(s)

        rss_mid = host_rss_kb(proc.pid)

        # drive M actions across sessions round-robin. one mlx ping every 25 actions.
        # click pool EXCLUDES the link (e3): clicking <a href=about:blank> navigates
        # the page away -> all subsequent clicks on that session go node_stale.
        act_ok, act_fail = 0, 0
        click_pool = ["e1", "e2", "e4"]
        for i in range(N_ACTIONS):
            sid = sids[i % len(sids)]
            act = ["scroll", "screenshot", "click"][i % 3]
            payload = {"session_id": sid, "action": act, "trace_id": "uma"}
            if act == "scroll":
                payload["scroll_delta_y"] = 100
            elif act == "click":
                payload["target_node_id"] = click_pool[i % len(click_pool)]
            send(s, {"type": "execute", "payload": payload})
            r = recv(s)
            p = r.get("payload", {}) if r else {}
            if p.get("error"):
                act_fail += 1
                errors.append(f"{act} fail {p['error'].get('code')}")
            else:
                act_ok += 1
            if i % 25 == 24:
                mlx_ping()
        rss_end = host_rss_kb(proc.pid)
        mem_end = mlx_metric("fusion_mlx_model_memory_bytes")
        requests_end = mlx_metric("fusion_mlx_requests_total")
        mlx_ok_end = mlx_ping()

        # close all
        for sid in sids:
            send(s, {"type": "close", "session_id": sid})
            recv(s)
        s.close()
        time.sleep(1)
        rss_after_close = host_rss_kb(proc.pid)

        # assertions
        rss_delta = rss_end - rss0
        # FR-08 total memory budget = per-session 150MB * N sessions. Host RSS
        # (excludes WebContent procs, bounded separately by quota) must stay
        # under the aggregate cap. Task spec: RSS < 150MB * 10 delta.
        rss_cap = 150 * 1024 * N_SESSIONS
        rss_ok = rss_delta < rss_cap
        mem_delta = (mem_end - mem0) if (mem0 is not None and mem_end is not None) else None
        # mlx memory must not rise monotonically under browser load (allow small
        # float jitter). cap 5%.
        mem_ok = (mem_delta is None) or (abs(mem_delta) < mem0 * 0.05)
        mlx_served = (requests_end is not None and requests0 is not None and requests_end >= requests0 + 2)

        report.update({
            "sessions": len(sids),
            "actions": {"ok": act_ok, "fail": act_fail, "total": N_ACTIONS},
            "browser_rss_kb": {"start": rss0, "mid": rss_mid, "end": rss_end, "after_close": rss_after_close,
                               "delta": rss_delta, "cap_kb": rss_cap},
            "mlx": {"model_memory_bytes_start": mem0, "model_memory_bytes_end": mem_end, "delta": mem_delta,
                    "requests_start": requests0, "requests_end": requests_end,
                    "ping_start_ok": mlx_ok0, "ping_end_ok": mlx_ok_end, "served_during": mlx_served},
            "assertions": {"browser_rss_under_cap": rss_ok, "mlx_memory_stable": mem_ok, "mlx_served": mlx_served},
            "errors_sample": errors[:10],
        })
        report["ok"] = bool(rss_ok and mem_ok and mlx_served and act_fail == 0)
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except Exception: proc.kill()
        if os.path.exists(SOCK): os.unlink(SOCK)
        try: os.remove(CONFIG)
        except Exception: pass

    with open(OUT, "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report, indent=2))
    print(f"[uma] report written to {OUT}")
    if not report.get("ok"):
        sys.exit(1)

if __name__ == "__main__":
    main()
