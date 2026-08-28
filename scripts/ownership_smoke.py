#!/usr/bin/env python3
# B-5/E-34 live smoke: session ownership is enforced over UDS. Before R-5 any authed
# client could operate any session by id (E-34). Now each UDS connection mints a stable
# owner id (UUID); create records it, execute/close verify it. A second connection
# operating the first's session must get `not_owner` (NOT session_not_found).
#
# Also covers the system-bypass: a single connection can always operate its OWN session.
#
# Usage: python3 scripts/ownership_smoke.py <release-binary-path>
# Default binary: .build/release/fusion-browser
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

SOCK = "/tmp/fusion-browser-owner.sock"
TOKEN = "owner-token"


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


def auth(sock, token):
    send(sock, {"type": "auth", "token": token})
    return recv_one(sock)


def error_code(resp):
    # error frame shape: {"type":"error","payload":{code,message,retryable}}
    if not isinstance(resp, dict):
        return None
    if resp.get("type") == "error":
        return (resp.get("payload") or {}).get("code")
    err = resp.get("error")
    if isinstance(err, dict):
        return err.get("code")
    return err


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else ".build/release/fusion-browser"
    if os.path.exists(SOCK):
        os.remove(SOCK)
    cfg = {
        "socketPath": SOCK,
        "authToken": TOKEN,
        "tokenCapabilities": ["all"],
        "logLevel": "info",
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
    env = dict(os.environ)
    log_fd, log_path = tempfile.mkstemp(prefix="fb_owner_", suffix=".log")
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

        # Client A: create a session.
        a = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        a.connect(SOCK)
        assert auth(a, TOKEN).get("type") == "auth_ack"
        send(a, {"type": "create_session", "payload": {"mode": "headless"}})
        cr = recv_one(a)
        sid = (cr.get("payload") or {}).get("sessionId") or (cr.get("payload") or {}).get("session_id")
        if not sid:
            raise RuntimeError(f"client A create failed: {cr}")

        # Client B: a SEPARATE connection (different owner id) operates A's session.
        b = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        b.connect(SOCK)
        assert auth(b, TOKEN).get("type") == "auth_ack"
        send(b, {"type": "execute",
                 "payload": {"sessionId": sid, "action": "screenshot"}})
        code = error_code(recv_one(b))
        if code != "not_owner":
            raise RuntimeError(f"B execute on A's session must be not_owner, got code={code}")
        # B closing A's session also denied.
        send(b, {"type": "close", "session_id": sid})
        code2 = error_code(recv_one(b))
        if code2 != "not_owner":
            raise RuntimeError(f"B close on A's session must be not_owner, got code={code2}")

        # A can still operate + close its own session (ownership did not lock A out).
        send(a, {"type": "close", "session_id": sid})
        resp3 = recv_one(a)
        if (resp3 or {}).get("type") == "error":
            raise RuntimeError(f"A close on own session failed: {resp3}")
        a.close()
        b.close()
        print(f"[ownership] PASS — B denied not_owner on execute+close of A's session; "
              f"A retains full control of its own session")
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
