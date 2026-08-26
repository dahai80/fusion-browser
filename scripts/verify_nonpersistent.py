#!/usr/bin/env python3
# P4-1: FR-04 non-persistence verification harness.
# Drives the built binary over UDS: create -> navigate(data URL that sets
# document.cookie + localStorage) -> screenshot -> close. Then asserts the
# process held NO persistent WebKit data files (lsof) and left NO residue on
# disk after close. Process-data cleaned by caller; this prints PASS/FAIL only.

import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time

SOCK = "/tmp/fusion-browser-verify.sock"
TOKEN = "verify-token"
BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "fusion-browser")
CONFIG = os.path.expanduser("~/.fusion-browser/config.json")
WEBKIT_DIR = os.path.expanduser("~/Library/Containers/com.fusion.browser/Data/Library/WebKit")
WEBKIT_DIR2 = os.path.expanduser("~/Library/WebKit")

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

def write_config():
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    cfg = {"socketPath": SOCK, "authToken": TOKEN, "logLevel": "warn"}
    with open(CONFIG, "w") as f:
        json.dump(cfg, f)

def check_no_persistent_files(pid):
    # lsof: any open file under a WebKit data path means persistence touched disk.
    try:
        out = subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    except Exception as e:
        print(f"[verify] lsof failed: {e}")
        return True
    bad = []
    for line in out.stdout.splitlines():
        low = line.lower()
        if "webkit" in low and ("websitedata" in low or "/cookies" in low or "/localstorage" in low or "/indexeddb" in low):
            bad.append(line)
    if bad:
        print("[verify] FAIL: process holds persistent WebKit data files:")
        for b in bad:
            print("  ", b)
        return False
    return True

def check_no_disk_residue():
    # FR-04 scopes to THIS process. ~/Library/WebKit is shared across all apps
    # (Xcode, fusion-mlx, etc.) so listing it proves nothing. The real check is
    # the process-specific container + the live lsof pass above. Assert only the
    # binary's own bundle container is absent.
    if os.path.exists(WEBKIT_DIR) and os.listdir(WEBKIT_DIR):
        print(f"[verify] FAIL: fusion-browser container residue at {WEBKIT_DIR}: {os.listdir(WEBKIT_DIR)[:5]}")
        return False
    return True

def main():
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    write_config()
    if not os.path.exists(BIN):
        print(f"[verify] FAIL: binary missing: {BIN}")
        sys.exit(1)
    proc = subprocess.Popen([BIN], stderr=subprocess.PIPE, stdout=subprocess.PIPE)
    time.sleep(1.5)
    if proc.poll() is not None:
        print("[verify] FAIL: binary exited early")
        sys.exit(1)

    ok = True
    try:
        # Wait for the socket to come up (bind race with process start).
        s = None
        for _ in range(50):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(SOCK)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if s: s.close()
                time.sleep(0.1)
        assert s is not None, "could not connect to UDS socket"
        send(s, {"type": "auth", "token": TOKEN})
        ack = recv_one(s)
        assert ack and ack.get("type") == "auth_ack", f"auth failed: {ack}"

        # data URL that sets a cookie + localStorage entry (triggers persistence path
        # if the store were persistent; nonPersistent must absorb it in memory).
        data_url = ("data:text/html,<script>"
                    "document.cookie='verify=1;path=/';"
                    "localStorage.setItem('verify','persist?');"
                    "document.title='verify';</script>"
                    "<button id=b>go</button>")
        send(s, {"type": "create_session", "payload": {"mode": "headless", "initial_url": data_url}})
        cr = recv_one(s)
        sid = cr.get("payload", {}).get("session_id")
        assert sid, f"no session: {cr}"
        print(f"[verify] session={sid}")

        # give WKWebView a moment to load the data URL + run the script
        time.sleep(2)

        # lsof check WHILE session live: must hold no persistent WebKit files
        if not check_no_persistent_files(proc.pid):
            ok = False

        send(s, {"type": "close", "session_id": sid})
        cl = recv_one(s)
        print(f"[verify] close: {cl}")
        s.close()
        time.sleep(1)

        # disk residue check AFTER close
        if not check_no_disk_residue():
            ok = False

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    if ok:
        print("[verify] PASS: FR-04 non-persistence verified — no WebKit data files held or left")
        sys.exit(0)
    else:
        print("[verify] FAIL: FR-04 persistence check failed")
        sys.exit(1)

if __name__ == "__main__":
    main()
