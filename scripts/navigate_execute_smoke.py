#!/usr/bin/env python3
# Verify the navigate-via-execute SIGTRAP fix (task #34). ActionDriver.dispatch
# runs on DispatchQueue.global(); wv.load off-main used to trap exit 133. The fix
# main-hops wv.load when off-main. This smoke drives the execute navigate path
# (NOT the create-with-initial_url path, which was already main-wrapped) and
# asserts the engine stays alive + the URL actually loads.
#
# Usage: python3 scripts/navigate_execute_smoke.py <release-binary-path>
# Default binary: .build/release/fusion-browser
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

SOCK = "/tmp/fusion-browser-navexec.sock"
TOKEN = "navexec-token"

PAGE = (
    "data:text/html,"
    + "<html><head><title>NavExec</title></head><body>"
    + "<form><input id=u type=text value=alice>"
    + "<button id=b>Go</button></form></body></html>"
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

def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else ".build/release/fusion-browser"
    if os.path.exists(SOCK):
        os.remove(SOCK)
    cfg = {"socketPath": SOCK, "authToken": TOKEN, "logLevel": "info"}
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
    log_fd, log_path = tempfile.mkstemp(prefix="fb_navexec_", suffix=".log")
    os.close(log_fd)
    log_file = open(log_path, "wb")
    proc = subprocess.Popen([binary], env=env, stdout=log_file, stderr=subprocess.STDOUT)
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
        # create WITHOUT initial_url -> about:blank. Load must come via execute
        # navigate (the off-main path the fix guards).
        send(s, {"type": "create_session", "payload": {"mode": "headless"}})
        cr = recv_one(s)
        crp = cr.get("payload") or {}
        sid = crp.get("sessionId") or crp.get("session_id")
        if not sid:
            raise RuntimeError(f"no session id: {cr}")
        # execute navigate — this is the previously-trapping path.
        send(s, {"type": "execute",
                 "payload": {"sessionId": sid, "action": "navigate", "payloadText": PAGE}})
        st = recv_one(s)
        rc = proc.poll()
        if st is None or rc is not None:
            log_file.close()
            with open(log_path, "r", errors="replace") as lf:
                tail = lf.read()[-2000:]
            raise RuntimeError(
                f"engine died on navigate-via-execute (exit={rc}). SIGTRAP regressed?\nlog tail:\n{tail}")
        if st.get("type") == "error":
            raise RuntimeError(f"navigate returned error frame: {json.dumps(st)}")
        # The navigate state response may still show about:blank (load async on
        # main); re-extract via a no-op scroll until the URL flips to the data: page.
        url = (st.get("payload") or {}).get("url", "")
        for attempt in range(10):
            if url and url.startswith("data:"):
                break
            send(s, {"type": "execute",
                     "payload": {"sessionId": sid, "action": "scroll", "scrollDeltaY": 0}})
            st = recv_one(s)
            if st is None:
                raise RuntimeError("scroll extract returned no frame (socket closed)")
            url = (st.get("payload") or {}).get("url", "")
            time.sleep(0.3)
        if not url or not url.startswith("data:"):
            raise RuntimeError(f"navigate-via-execute never loaded the data: page (url={url[:60]})")
        md = (st.get("payload") or {}).get("ax_tree_markdown") or (st.get("payload") or {}).get("axTreeMarkdown")
        if md is None or "NavExec" not in md:
            raise RuntimeError(f"page loaded but ax_tree_markdown missing/wrong: {md}")
        send(s, {"type": "close", "session_id": sid})
        recv_one(s)
        s.close()
        print(f"[navexec] PASS — navigate-via-execute loaded url={url[:50]} title-in-md={'NavExec' in (md or '')}")
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        log_file.close()
        os.unlink(log_path)
        if os.path.exists(cfg_path):
            os.remove(cfg_path)
        if backup and os.path.exists(backup):
            os.rename(backup, cfg_path)
        if os.path.exists(SOCK):
            os.remove(SOCK)

if __name__ == "__main__":
    main()
