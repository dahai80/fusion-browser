#!/usr/bin/env python3
# E-9 (#64) live smoke: Runtime.evaluate must return the REAL JS result, not a
# synthetic "ok". Drives the UDS `.evaluate` action and asserts the new
# `evaluate_result` field carries the JSON-encoded return value of the
# expression. The CDP handleEvaluate -> cdpRemoteObject mapping is pinned by
# unit tests; this pins the ActionDriver -> BrowserStateResponse plumbing.
#
# EVALUATE origin gate (FR-10/E-15) rejects opaque origins (data:/about:/blob:)
# fail-closed, so the test page is served over real HTTP from a throwaway
# localhost server with allowedOrigins=["http://127.0.0.1:PORT"].
#
# Usage: python3 scripts/evaluate_smoke.py <release-binary-path>
# Default binary: .build/release/fusion-browser
import http.server
import json
import os
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time

SOCK = "/tmp/fusion-browser-eval.sock"
TOKEN = "eval-token"

PAGE = (
    "<html><head><title>EvalSmoke</title></head><body>"
    "<input id=u type=text value=alice>"
    "<script>window._pairs=[[1,2],[3,4]];</script>"
    "</body></html>"
)

def send(sock, obj):
    data = json.dumps(obj).encode()
    sock.sendall(struct.pack(">I", len(data)) + data)

def recv_one(sock):
    hdr = b""
    while len(hdr) < 4:
        chunk = sock.recv(4 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    (length,) = struct.unpack(">I", hdr)
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)

def evaluate(s, sid, expr):
    send(s, {"type": "execute",
             "payload": {"sessionId": sid, "action": "evaluate",
                         "payloadText": expr}})
    return recv_one(s)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        body = PAGE.encode()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else ".build/release/fusion-browser"
    # Bind a throwaway HTTP server on an ephemeral port, keep its origin.
    httpd = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    origin = f"http://127.0.0.1:{port}"
    page_url = origin + "/"
    srv_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    srv_thread.start()

    if os.path.exists(SOCK):
        os.remove(SOCK)
    # allowedOrigins = the live HTTP origin so EVALUATE passes the origin gate.
    # tokenCapabilities=["all"] elevates the token so the UDS cap gate admits
    # evaluate (H-5: default token lacks evaluate; E-9 needs it reachable).
    cfg = {"socketPath": SOCK, "authToken": TOKEN, "logLevel": "info",
           "allowedOrigins": [origin], "tokenCapabilities": ["all"]}
    cfg_dir = os.path.expanduser("~/.fusion-browser")
    os.makedirs(cfg_dir, exist_ok=True)
    cfg_path = os.path.join(cfg_dir, "config.json")
    backup = None
    if os.path.exists(cfg_path):
        backup = cfg_path + ".bak"
        os.rename(cfg_path, backup)
    with open(cfg_path, "w") as f:
        json.dump(cfg, f)
    env = dict(os.environ)
    log_fd, log_path = tempfile.mkstemp(prefix="fb_eval_", suffix=".log")
    os.close(log_fd)
    log_file = open(log_path, "wb")
    proc = subprocess.Popen([binary], env=env, stdout=log_file, stderr=subprocess.STDOUT)
    failures = []
    try:
        for _ in range(100):
            if os.path.exists(SOCK):
                break
            time.sleep(0.1)
        else:
            log_file.close()
            with open(log_path, "r", errors="replace") as lf:
                raise RuntimeError(f"socket never appeared; log:\n{lf.read()}")
        time.sleep(0.3)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(SOCK)
        send(s, {"type": "auth", "token": TOKEN})
        ack = recv_one(s)
        if not ack or ack.get("type") != "auth_ack":
            raise RuntimeError(f"auth failed: {ack}")
        # Create about:blank, then navigate to the HTTP page (the create-with-
        # initial_url path is not exercised here; navigate-after-create mirrors
        # the proven navigate_execute_smoke pattern and avoids headless init lag).
        send(s, {"type": "create_session", "payload": {"mode": "headless"}})
        cr = recv_one(s)
        sid = (cr.get("payload") or {}).get("sessionId") or (cr.get("payload") or {}).get("session_id")
        if not sid:
            raise RuntimeError(f"no session id: {cr}")
        send(s, {"type": "execute",
                 "payload": {"sessionId": sid, "action": "navigate", "payloadText": page_url}})
        recv_one(s)
        # Re-extract via a no-op scroll until the URL flips to the HTTP page.
        url = ""
        for _ in range(10):
            send(s, {"type": "execute",
                     "payload": {"sessionId": sid, "action": "scroll", "scrollDeltaY": 0}})
            st = recv_one(s)
            if st is None:
                raise RuntimeError("scroll extract returned no frame (socket closed)")
            url = (st.get("payload") or {}).get("url", "")
            if url.startswith("http://127.0.0.1"):
                break
            time.sleep(0.3)
        if not url.startswith("http://127.0.0.1"):
            raise RuntimeError(f"page never loaded (url={url[:60]})")

        def check(label, expr, expect_json):
            resp = evaluate(s, sid, expr)
            p = resp.get("payload") or {}
            if resp.get("type") == "error" or p.get("error"):
                failures.append(f"{label}: error frame {json.dumps(resp)[:200]}")
                return
            got = p.get("evaluate_result") or p.get("evaluateResult")
            if got is None:
                failures.append(f"{label}: evaluate_result absent (E-9 regressed to nil)")
                return
            if got != expect_json:
                failures.append(f"{label}: got {got!r} want {expect_json!r}")
                return
            print(f"[eval] {label}: {got!r} OK")

        # E-9 core: each JS type round-trips as a JSON-encoded fragment.
        check("string", "document.title", '"EvalSmoke"')
        check("number", "1 + 41", "42")
        check("boolean", "document.querySelector('#u') !== null", "true")
        check("string-field", "document.querySelector('#u').value", '"alice"')
        check("array", "window._pairs", "[[1,2],[3,4]]")
        check("object", "({title: document.title})", '{"title":"EvalSmoke"}')
        # void expression -> no evaluate_result (undefined). The driver JSON-
        # encodes the deserialized return value; WKWebView evaluates `void 0`
        # to undefined -> evaluateJSSync returns nil -> evaluateResult stays nil.
        check_void = evaluate(s, sid, "void 0")
        vp = (check_void.get("payload") or {})
        if (vp.get("evaluate_result") or vp.get("evaluateResult")) is not None:
            failures.append(f"void: expected nil evaluate_result, got {vp}")

        send(s, {"type": "close", "session_id": sid})
        recv_one(s)
        s.close()
        if failures:
            raise RuntimeError("E-9 smoke FAILED:\n  " + "\n  ".join(failures))
        print("[eval] PASS — Runtime.evaluate returns real JS result (E-9 live)")
    finally:
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
