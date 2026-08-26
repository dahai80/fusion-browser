#!/usr/bin/env python3
# P4-5: 1000-action long-run leak check. Drives a single session through 1000
# actions (scroll/screenshot/click rotated, targets rotated to respect FR-13
# repeat-break), samples host RSS every 50 actions, and asserts RSS shows no
# monotonic rise — i.e. the last quartile mean is not meaningfully above the
# first quartile mean (within a tolerance that absorbs allocator jitter).
# Emits longrun-report.json. Live webview requires the release binary.

import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time

SOCK = "/tmp/fusion-browser-longrun.sock"
TOKEN = "longrun-token"
BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "fusion-browser")
CONFIG = os.path.expanduser("~/.fusion-browser/config.json")
OUT = os.path.join(os.path.dirname(__file__), "longrun-report.json")
N_ACTIONS = 1000
SAMPLE_EVERY = 50

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
    # FR-13 default maxActions=200 caps a single task; raise it so the long-run
    # actually completes 1000 actions (leak test, not quota test).
    with open(CONFIG, "w") as f:
        json.dump({"socketPath": SOCK, "authToken": TOKEN, "logLevel": "error",
                   "guards": {"maxActions": N_ACTIONS + 100, "taskTimeoutMs": 3_600_000,
                              "repeatActionBreak": 1000, "rebuildDepthCap": 1}}, f)

def host_rss_kb(pid):
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
        return int(out.stdout.strip()) if out.stdout.strip() else 0
    except Exception:
        return 0

def main():
    if os.path.exists(SOCK): os.unlink(SOCK)
    write_config()
    if not os.path.exists(BIN):
        print(f"[longrun] FAIL: binary missing: {BIN}"); sys.exit(1)
    proc = subprocess.Popen([BIN], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    time.sleep(1.5)
    if proc.poll() is not None:
        print("[longrun] FAIL: binary exited early"); sys.exit(1)

    report = {"ts": int(time.time()), "ok": False}
    errors = []
    rss_series = []
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

        html = ("<html><body>"
                "<button id=a>Login</button>"
                "<input id=b placeholder=Email>"
                "<a id=c href=about:blank>Next</a>"
                "<button id=d>Submit</button>"
                + "<p>filler</p>" * 10 + "</body></html>")
        url = "data:text/html;base64," + base64.b64encode(html.encode()).decode()
        send(s, {"type": "create_session", "payload": {"mode": "headless", "initial_url": url}})
        cr = recv(s); sid = cr.get("payload", {}).get("session_id")
        assert sid, f"create failed: {cr}"
        time.sleep(2)

        # warm up __fbMap so first click resolves.
        send(s, {"type": "execute", "payload": {"session_id": sid, "action": "screenshot", "trace_id": "warm"}})
        recv(s)

        click_pool = ["e1", "e2", "e4"]
        act_ok, act_fail = 0, 0
        for i in range(N_ACTIONS):
            act = ["scroll", "screenshot", "click"][i % 3]
            payload = {"session_id": sid, "action": act, "trace_id": "lr"}
            if act == "scroll":
                payload["scroll_delta_y"] = 50
            elif act == "click":
                payload["target_node_id"] = click_pool[i % len(click_pool)]
            send(s, {"type": "execute", "payload": payload})
            r = recv(s)
            p = r.get("payload", {}) if r else {}
            if p.get("error"):
                act_fail += 1
                if len(errors) < 10:
                    errors.append(f"{act} fail {p['error'].get('code')}")
            else:
                act_ok += 1
            if i % SAMPLE_EVERY == 0:
                rss_series.append({"action": i, "rss_kb": host_rss_kb(proc.pid)})

        send(s, {"type": "close", "session_id": sid}); recv(s)
        s.close()
        time.sleep(1)
        rss_series.append({"action": N_ACTIONS, "rss_kb": host_rss_kb(proc.pid)})

        # leak analysis: compare first-quartile vs last-quartile mean RSS.
        # no monotonic leak => last mean not meaningfully above first mean.
        vals = [x["rss_kb"] for x in rss_series]
        q = len(vals) // 4
        first_q = vals[:q] if q else vals
        last_q = vals[-q:] if q else vals
        first_mean = sum(first_q) / len(first_q)
        last_mean = sum(last_q) / len(last_q)
        # tolerance: 30MB allocator/JS-buffer jitter acceptable.
        jitter_kb = 30 * 1024
        no_leak = last_mean <= first_mean + jitter_kb
        span = max(vals) - min(vals) if vals else 0

        report.update({
            "actions": {"ok": act_ok, "fail": act_fail, "total": N_ACTIONS},
            "rss_series": rss_series,
            "rss_kb": {"first_quartile_mean": round(first_mean), "last_quartile_mean": round(last_mean),
                       "span": span, "jitter_tol_kb": jitter_kb},
            "assertions": {"no_monotonic_rise": no_leak, "all_actions_ok": act_fail == 0},
            "errors_sample": errors,
        })
        report["ok"] = bool(no_leak and act_fail == 0)
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except Exception: proc.kill()
        if os.path.exists(SOCK): os.unlink(SOCK)
        try: os.remove(CONFIG)
        except Exception: pass

    with open(OUT, "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps({k: v for k, v in report.items() if k != "rss_series"}, indent=2))
    print(f"rss series ({len(rss_series)} samples): min={min(x['rss_kb'] for x in rss_series)} max={max(x['rss_kb'] for x in rss_series)}")
    print(f"[longrun] report written to {OUT}")
    if not report.get("ok"):
        sys.exit(1)

if __name__ == "__main__":
    main()
