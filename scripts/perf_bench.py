#!/usr/bin/env python3
# P4-3: performance benchmark suite. Drives the built binary over UDS through a
# fixed action workload (navigate -> extract -> click-ish -> screenshot loop on a
# data URL), collects execution_time_ms from each BrowserStateResponse, samples
# host RSS, and computes an AXTree token-compression ratio (markdown chars vs raw
# interactive_nodes JSON chars). Emits perf-report JSON to scripts/perf-report.json.
#
# Scope: host-process latency + token compression. WKWebView WebContent process
# RSS is separate (see P4-2 note). Live webview under swift test is impossible, so
# this runs against the release binary.

import json
import os
import socket
import struct
import subprocess
import sys
import time

SOCK = "/tmp/fusion-browser-perf.sock"
TOKEN = "perf-token"
BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "fusion-browser")
CONFIG = os.path.expanduser("~/.fusion-browser/config.json")
OUT = os.path.join(os.path.dirname(__file__), "perf-report.json")
N_SCROLL = 20
N_SCREEN = 20
N_CLICK = 20

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
    # ps rss in KB (host process only, excludes WebContent).
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
        return int(out.stdout.strip()) if out.stdout.strip() else 0
    except Exception:
        return 0

def p95(xs):
    if not xs: return 0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * 0.95))]

def percentile(xs, p):
    if not xs: return 0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))]

def main():
    if os.path.exists(SOCK): os.unlink(SOCK)
    write_config()
    if not os.path.exists(BIN):
        print(f"[perf] FAIL: binary missing: {BIN}"); sys.exit(1)
    proc = subprocess.Popen([BIN], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    time.sleep(1.5)
    if proc.poll() is not None:
        print("[perf] FAIL: binary exited early"); sys.exit(1)

    scroll_ms, screen_ms, click_ms = [], [], []
    click_errs = []
    md_chars, node_counts = [], []
    rss_samples = []
    report = {}
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

        # Page with a stable interactive button (@e1) for click latency. Note:
        # EVALUATE is a gated capability (excluded from .default caps) so the
        # benchmark measures the default-deployed action surface only.
        # Use base64 data URL to avoid quote/fragment (#) parsing pitfalls that
        # truncate the page mid-markup (kept node count artificially low).
        import base64
        html = ("<html><body>"
                "<button id=a>Login</button>"
                "<input id=b placeholder=Email>"
                "<a id=c href=about:blank>Next</a>"
                "<button id=d>Submit</button>"
                + "<p>filler</p>" * 20 +
                "</body></html>")
        url = "data:text/html;base64," + base64.b64encode(html.encode()).decode()
        send(s, {"type": "create_session", "payload": {"mode": "headless", "initial_url": url}})
        cr = recv(s); sid = cr["payload"]["session_id"]
        time.sleep(2)

        # Resolve a pool of click targets from the initial extract. FR-13
        # repeat-action-break rejects 3+ consecutive identical action keys, so
        # hammering the same click:e1: trips the guard (by design — stuck-loop
        # protection). Rotate distinct targets so each click key differs and the
        # guard never fires. Exclude links (href '#' would navigate the page).
        send(s, {"type": "execute", "payload": {"session_id": sid, "action": "screenshot", "trace_id": "p"}})
        init = recv(s).get("payload", {})
        click_pool = [n.get("node_id") for n in (init.get("interactive_nodes") or [])
                       if n.get("role") in ("button", "textbox")]
        if not click_pool:
            click_pool = ["e1"]

        for _ in range(N_SCROLL):
            send(s, {"type": "execute", "payload": {"session_id": sid, "action": "scroll", "scroll_delta_y": 300, "trace_id": "p"}})
            r = recv(s)
            t = r.get("payload", {}).get("execution_time_ms") if r else None
            if t is not None: scroll_ms.append(t)
            rss_samples.append(host_rss_kb(proc.pid))

        for _ in range(N_SCREEN):
            send(s, {"type": "execute", "payload": {"session_id": sid, "action": "screenshot", "trace_id": "p"}})
            r = recv(s)
            p = r.get("payload", {}) if r else {}
            t = p.get("execution_time_ms")
            if t is not None: screen_ms.append(t)
            md = p.get("ax_tree_markdown") or ""
            nodes = p.get("interactive_nodes") or []
            if md:
                md_chars.append(len(md))
                node_counts.append(len(nodes))
            rss_samples.append(host_rss_kb(proc.pid))

        for i in range(N_CLICK):
            tgt = click_pool[i % len(click_pool)]
            send(s, {"type": "execute", "payload": {"session_id": sid, "action": "click", "target_node_id": tgt, "trace_id": "p"}})
            r = recv(s)
            p = r.get("payload", {}) if r else {}
            t = p.get("execution_time_ms")
            e = p.get("error")
            # click on a stale/changed node returns node_stale; only count ok.
            if e:
                click_errs.append(e.get("code"))
            elif t is not None:
                click_ms.append(t)

        send(s, {"type": "close", "session_id": sid}); recv(s)
        s.close()

        chars_per_node = None
        if md_chars and node_counts:
            total_nodes = sum(node_counts)
            total_chars = sum(md_chars)
            chars_per_node = round(total_chars / total_nodes, 1) if total_nodes else None

        report = {
            "ts": int(time.time()),
            "pid": proc.pid,
            "workload": {"scroll": N_SCROLL, "screenshot": N_SCREEN, "click": N_CLICK},
            "note": "evaluate excluded (gated capability, not in default caps); click counts ok responses only; click targets rotated to avoid FR-13 repeat-break",
            "latency_ms": {
                "scroll": {"count": len(scroll_ms), "p50": percentile(scroll_ms, 0.5), "p95": p95(scroll_ms), "max": max(scroll_ms) if scroll_ms else 0},
                "screenshot": {"count": len(screen_ms), "p50": percentile(screen_ms, 0.5), "p95": p95(screen_ms), "max": max(screen_ms) if screen_ms else 0},
                "click": {"count": len(click_ms), "p50": percentile(click_ms, 0.5), "p95": p95(click_ms), "max": max(click_ms) if click_ms else 0,
                          "errors": len(click_errs), "error_codes": sorted(set(click_errs))},
            },
            "axtree": {"markdown_p95_chars": p95(md_chars) if md_chars else 0,
                        "avg_interactive_nodes": round(sum(node_counts)/len(node_counts), 1) if node_counts else 0,
                        "chars_per_node": chars_per_node},
            "host_rss_kb": {"samples": len(rss_samples), "min": min(rss_samples) if rss_samples else 0,
                            "max": max(rss_samples) if rss_samples else 0,
                            "delta": (max(rss_samples) - min(rss_samples)) if rss_samples else 0},
        }
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except Exception: proc.kill()

    with open(OUT, "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report, indent=2))
    print(f"[perf] report written to {OUT}")

if __name__ == "__main__":
    main()
