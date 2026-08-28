#!/usr/bin/env python3
# E-11 (#67) live smoke: CDP event emission must be honest — real HTTP status in
# Network.responseReceived, real-Chrome event order, per-nav loaderId/requestId,
# and Runtime.consoleAPICalled actually wired (the __fbConsole shim was dead code).
# Drives the CDP-over-WS surface (:9222) against a real WKWebView:
#
#   Flow 1 (real status + order): serve a 403 page that console.log("hello-e11").
#     Enable Network + Runtime, navigate, drain events, assert:
#       - a Network.responseReceived event with response.status==403 (Finding 26),
#       - a Runtime.consoleAPICalled event with type=="log" + args has "hello-e11" (Finding 9),
#       - event ORDER (Finding 10): requestWillBeSent precedes responseReceived precedes
#         loadingFinished; frameNavigated precedes DOMContentLoaded precedes load.
#   Flow 2 (per-nav loaderId): navigate a 200 page, record loaderId; navigate again,
#     assert the new loaderId differs and frameId stayed the same (Finding 25).
#
# H-5: CDP is Bearer-gated. E-15: WS upgrade is origin-gated fail-closed — send an
# allowlisted Origin header.
#
# Usage: python3 scripts/cdp_event_smoke.py <release-binary-path>
# Default binary: .build/release/fusion-browser
import http.server
import json
import os
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

try:
    import websocket  # websocket-client
except ImportError:
    print("FATAL: pip install websocket-client", file=sys.stderr)
    sys.exit(2)

SOCK = "/tmp/fusion-browser-cdpevent.sock"
TOKEN = "cdp-event-token"
CDP_PORT = 9222
ORIGIN = "http://127.0.0.1:1"


# A page that logs on load so the console drain (after navigate) sees it.
PAGE_OK = (
    "<html><head><title>CDPEventOK</title></head><body>"
    "<script>console.log('hello-e11')</script>"
    "<p>ok</p>"
    "</body></html>"
)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # /denied -> 403, anything else -> 200. Both serve the logging page so
        # the console drain fires regardless of status (proves status + console
        # are independent fixes).
        status = 403 if self.path.startswith("/denied") else 200
        body = PAGE_OK.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def http_get_json(host, port, path, token):
    import urllib.request
    req = urllib.request.Request(f"http://{host}:{port}{path}")
    req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read().decode())


def cdp_send(ws, method, params=None, msg_id=1, events=None):
    # events: a list to append buffered server-push events (no "id") into while
    # we wait for the matching response (with "id").
    msg = {"id": msg_id, "method": method}
    if params is not None:
        msg["params"] = params
    ws.send(json.dumps(msg))
    while True:
        raw = ws.recv()
        obj = json.loads(raw)
        if obj.get("id") == msg_id:
            return obj
        if events is not None and "method" in obj:
            events.append(obj)


def drain_events(ws, events, timeout=0.6):
    # The server emits nav/console events synchronously inside handleCDPMessage,
    # which can arrive AFTER the matching response frame. cdp_send returns on the
    # response id, leaving trailing push events in the socket buffer. Drain them
    # into `events` for a short window so per-flow capture is complete.
    ws.settimeout(timeout)
    try:
        while True:
            raw = ws.recv()
            obj = json.loads(raw)
            if "method" in obj:
                events.append(obj)
    except Exception:
        pass
    ws.settimeout(None)


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else ".build/release/fusion-browser"
    httpd = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    page_origin = f"http://127.0.0.1:{port}"
    denied_url = page_origin + "/denied"
    ok_url = page_origin + "/"
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    if os.path.exists(SOCK):
        os.remove(SOCK)
    # allowedOrigins: page origin (navigate + evaluate) AND the CDP client's own
    # Origin header (E-15 WS-upgrade gate). tokenCapabilities=all opens evaluate (H-5).
    cfg = {
        "socketPath": SOCK, "authToken": TOKEN, "logLevel": "info",
        "cdpEnabled": True, "cdpPort": CDP_PORT,
        "allowedOrigins": [page_origin, ORIGIN],
        "tokenCapabilities": ["all"],
    }
    cfg_dir = os.path.expanduser("~/.fusion-browser")
    os.makedirs(cfg_dir, exist_ok=True)
    cfg_path = os.path.join(cfg_dir, "config.json")
    backup = None
    if os.path.exists(cfg_path):
        backup = cfg_path + ".bak"
        os.rename(cfg_path, backup)
    with open(cfg_path, "w") as f:
        json.dump(cfg, f)
    log_fd, log_path = tempfile.mkstemp(prefix="fb_cdpevent_", suffix=".log")
    os.close(log_fd)
    log_file = open(log_path, "wb")
    proc = subprocess.Popen([binary], env=dict(os.environ),
                            stdout=log_file, stderr=subprocess.STDOUT)
    failures = []
    ws = None
    try:
        for _ in range(100):
            if os.path.exists(SOCK):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("UDS socket never appeared")
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", CDP_PORT), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("CDP port never opened")
        time.sleep(0.3)

        targets = http_get_json("127.0.0.1", CDP_PORT, "/json", TOKEN)
        ws_url = targets[0]["webSocketDebuggerUrl"]
        ws = websocket.create_connection(ws_url, origin=ORIGIN,
                                         header={"Authorization": f"Bearer {TOKEN}"})

        # Enable both domains (cowork does this on connect).
        cdp_send(ws, "Network.enable", {}, msg_id=1)
        cdp_send(ws, "Runtime.enable", {}, msg_id=2)
        cdp_send(ws, "Page.enable", {}, msg_id=3)

        # ---- Flow 1: 403 navigate + console.log, assert real status + console + order ----
        ev1 = []
        cdp_send(ws, "Page.navigate", {"url": denied_url}, msg_id=10, events=ev1)
        drain_events(ws, ev1)

        methods1 = [e["method"] for e in ev1]
        # Finding 26: real status. A responseReceived with status==403 must exist.
        resp_ev = next((e for e in ev1 if e["method"] == "Network.responseReceived"), None)
        if resp_ev is None:
            failures.append("Flow 1: no Network.responseReceived event (events=%s)" % methods1)
        else:
            rstatus = (resp_ev.get("params") or {}).get("response", {}).get("status")
            if rstatus != 403:
                failures.append(f"Flow 1: responseReceived status={rstatus} want 403 (Finding 26)")
            else:
                print("[event] Flow 1 responseReceived status=403 OK (Finding 26)")

        # Finding 9: console wired. A consoleAPICalled with type log + "hello-e11".
        con_ev = next((e for e in ev1 if e["method"] == "Runtime.consoleAPICalled"), None)
        if con_ev is None:
            failures.append("Flow 1: no Runtime.consoleAPICalled event (Finding 9)")
        else:
            ctype = (con_ev.get("params") or {}).get("type")
            cargs = (con_ev.get("params") or {}).get("args")
            # Args may be bare strings ("hello-e11") or {value:...} dicts depending
            # on the CDP remote-object mapping; accept either.
            def _arg_str(a):
                if isinstance(a, dict):
                    return str(a.get("value", "")) + str(a.get("description", ""))
                return str(a)
            found = any("hello-e11" in _arg_str(a) for a in (cargs or []))
            if ctype != "log" or not found:
                failures.append(f"Flow 1: consoleAPICalled type={ctype} args={cargs} want log + hello-e11 (Finding 9)")
            else:
                print("[event] Flow 1 consoleAPICalled log 'hello-e11' OK (Finding 9)")

        # Finding 10: event order. requestWillBeSent < responseReceived < loadingFinished;
        # frameNavigated < DOMContentLoaded < load (by index in arrival order).
        def idx(name):
            for i, m in enumerate(methods1):
                if m == name:
                    return i
            return -1
        def lifecycle_idx(name):
            for i, e in enumerate(ev1):
                if e["method"] == "Page.lifecycleEvent" and (e.get("params") or {}).get("name") == name:
                    return i
            return -1
        if not (0 <= idx("Network.requestWillBeSent") < idx("Network.responseReceived") < idx("Network.loadingFinished")):
            failures.append(f"Flow 1: Network trio order wrong: {methods1} (Finding 10)")
        elif not (0 <= idx("Page.frameNavigated") < lifecycle_idx("DOMContentLoaded") < lifecycle_idx("load")):
            failures.append(f"Flow 1: Page lifecycle order wrong: {methods1} (Finding 10)")
        else:
            print("[event] Flow 1 event order OK (Finding 10)")

        # ---- Flow 2: per-nav loaderId (Finding 25) ----
        ev2a = []
        cdp_send(ws, "Page.navigate", {"url": ok_url}, msg_id=20, events=ev2a)
        drain_events(ws, ev2a)
        loader_a = None
        frame_a = None
        for e in ev2a:
            if e["method"] == "Page.frameNavigated":
                frame = (e.get("params") or {}).get("frame", {})
                loader_a = frame.get("loaderId")
                frame_a = frame.get("id")
                break
        if not loader_a:
            # Fall back to requestWillBeSent loaderId if frameNavigated absent.
            for e in ev2a:
                if e["method"] == "Network.requestWillBeSent":
                    loader_a = (e.get("params") or {}).get("loaderId")
                    frame_a = (e.get("params") or {}).get("frameId")
                    break
        ev2b = []
        cdp_send(ws, "Page.navigate", {"url": ok_url}, msg_id=21, events=ev2b)
        drain_events(ws, ev2b)
        loader_b = None
        frame_b = None
        for e in ev2b:
            if e["method"] == "Page.frameNavigated":
                frame = (e.get("params") or {}).get("frame", {})
                loader_b = frame.get("loaderId")
                frame_b = frame.get("id")
                break
        if not loader_b:
            for e in ev2b:
                if e["method"] == "Network.requestWillBeSent":
                    loader_b = (e.get("params") or {}).get("loaderId")
                    frame_b = (e.get("params") or {}).get("frameId")
                    break
        if not loader_a or not loader_b:
            failures.append(f"Flow 2: missing loaderId a={loader_a} b={loader_b} (Finding 25)")
        elif loader_a == loader_b:
            failures.append(f"Flow 2: loaderId reused across navs a={loader_a} b={loader_b} (Finding 25)")
        else:
            print(f"[event] Flow 2 per-nav loaderId {loader_a} -> {loader_b} OK (Finding 25)")
        if frame_a and frame_b and frame_a != frame_b:
            failures.append(f"Flow 2: frameId changed across navs a={frame_a} b={frame_b} (should stay constant)")

        if ws:
            ws.close()
        if failures:
            raise RuntimeError("E-11 CDP event smoke FAILED:\n  " + "\n  ".join(failures))
        print("[event] PASS — CDP events honest (E-11 live): real status, console wired, order, per-nav loaderId")
    finally:
        if ws:
            try:
                ws.close()
            except Exception:
                pass
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        log_file.close()
        os.unlink(log_path)
        httpd.shutdown()
        if os.path.exists(cfg_path):
            os.remove(cfg_path)
        if backup and os.path.exists(backup):
            os.rename(backup, cfg_path)
        if os.path.exists(SOCK):
            os.remove(SOCK)


if __name__ == "__main__":
    main()
