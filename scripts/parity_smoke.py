#!/usr/bin/env python3
# PRD §4.3 module 5 live parity smoke: start the release binary under two
# configs (useRustCore=false vs true), drive the same page through the UDS
# protocol, capture ax_tree_markdown from the navigate state response, and
# assert byte-identical output. The Rust core path must match the Swift path
# on a live WKWebView, not just on fixtures.
#
# Usage: python3 scripts/parity_smoke.py <release-binary-path>
# Default binary: .build/release/fusion-browser
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

SOCK = "/tmp/fusion-browser-parity.sock"
TOKEN = "parity-token"

# A page with mixed interactive nodes: textbox (name), password (masked val),
# button, disabled control, and a hidden (display:none) link — exercises every
# markdown suffix branch the parity fixture covers.
PAGE = (
    "data:text/html,"
    + "<html><head><title>Parity</title></head><body>"
    + "<form>"
    + "<input id=u type=text value=alice placeholder=Username>"
    + "<input id=p type=password value=secret>"
    + "<button id=b>Login</button>"
    + "<button id=d disabled>Disabled</button>"
    + "<a id=h href=/x style='display:none'>Hidden</a>"
    + "</form></body></html>"
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
        chunk = sock.recv(length - body.__len__())
        if not chunk:
            return None
        body += chunk
    return json.loads(body)

def write_config(use_rust):
    cfg = {
        "socketPath": SOCK,
        "cdpEnabled": False,
        "authToken": TOKEN,
        "logLevel": "info",
        "useRustCore": use_rust,
    }
    # The engine only reads ~/.fusion-browser/config.json (no path override).
    # Back up any existing config, write ours, restore in finally.
    cfg_dir = os.path.expanduser("~/.fusion-browser")
    os.makedirs(cfg_dir, exist_ok=True)
    cfg_path = os.path.join(cfg_dir, "config.json")
    backup = None
    if os.path.exists(cfg_path):
        backup = cfg_path + ".parity_bak"
        os.replace(cfg_path, backup)
    with open(cfg_path, "w") as f:
        json.dump(cfg, f)
    return cfg_path, backup

def run_smoke(use_rust, binary):
    if os.path.exists(SOCK):
        os.remove(SOCK)
    cfg_path, backup = write_config(use_rust)
    env = dict(os.environ)
    env["HOME"] = os.path.expanduser("~")
    # Redirect binary stdout/stderr to a temp log, NOT a pipe — a PIPE with no
    # reader fills the OS buffer and blocks the engine's logging, deadlocking
    # startup before the UDS socket appears.
    log_fd, log_path = tempfile.mkstemp(prefix="fb_parity_engine_", suffix=".log")
    os.close(log_fd)
    log_file = open(log_path, "wb")
    proc = subprocess.Popen([binary], env=env, stdout=log_file, stderr=subprocess.STDOUT)
    try:
        # Wait for the UDS socket to appear (engine ready).
        for _ in range(100):
            if os.path.exists(SOCK):
                break
            time.sleep(0.1)
        else:
            log_file.close()
            with open(log_path, "r", errors="replace") as lf:
                out = lf.read()
            raise RuntimeError(f"socket never appeared; engine log:\n{out}")
        time.sleep(0.3)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(SOCK)
        send(s, {"type": "auth", "token": TOKEN})
        ack = recv_one(s)
        if not ack or ack.get("type") != "auth_ack":
            raise RuntimeError(f"auth failed: {ack}")
        # create with initial_url: the page loads on the main thread (WKWebView.load
        # is main-wrapped on the create path). navigate-via-execute is ALSO main-wrapped
        # now (WebView.navigate hops wv.load to main when off-main, fix for task #34),
        # but this smoke loads via create + triggers extract with a scroll action
        # (JS-only, off-main safe) to keep the parity comparison on a stable load.
        send(s, {"type": "create_session", "payload": {"mode": "headless", "initialUrl": PAGE}})
        cr = recv_one(s)
        print(f"[parity] create resp: {json.dumps(cr)[:300]}", file=sys.stderr)
        # CreateSessionResponse carries sessionId (camelCase); accept both.
        crp = cr.get("payload") or {}
        sid = crp.get("sessionId") or crp.get("session_id")
        if not sid:
            raise RuntimeError(f"no session id: {cr}")
        # Give the page a moment to finish loading before extract.
        time.sleep(0.6)
        # scroll triggers extract() -> state response carries ax_tree_markdown.
        # scrollDeltaY=0 makes it a no-op scroll (no layout change), extract still runs.
        # Retry: a cold WKWebView may not finish the data: URL load in one wait, so
        # keep extracting until the url is no longer about:blank (page loaded) or we
        # exhaust attempts. Both configs must observe the SAME loaded page for parity.
        st = None
        for attempt in range(8):
            send(s, {"type": "execute",
                     "payload": {"sessionId": sid, "action": "scroll", "scrollDeltaY": 0}})
            st = recv_one(s)
            if st is None:
                rc = proc.poll()
                print(f"[parity] exec resp None; engine proc.poll()={rc} (None=still alive)", file=sys.stderr)
                raise RuntimeError("execute/scroll returned no frame (socket closed)")
            url = (st.get("payload") or {}).get("url", "")
            if url and url != "about:blank":
                print(f"[parity] page loaded after {attempt+1} extract(s) url={url[:60]}", file=sys.stderr)
                break
            time.sleep(0.4)
        else:
            print(f"[parity] page never left about:blank after 8 extracts", file=sys.stderr)
        print(f"[parity] exec resp: {json.dumps(st)[:200]}", file=sys.stderr)
        if st.get("type") == "error":
            raise RuntimeError(f"execute/navigate error frame: {json.dumps(st)}")
        md = (st.get("payload") or {}).get("ax_tree_markdown") or (st.get("payload") or {}).get("axTreeMarkdown")
        send(s, {"type": "close", "session_id": sid})
        recv_one(s)
        s.close()
        if md is None:
            raise RuntimeError(f"no ax_tree_markdown in state: {json.dumps(st)[:400]}")
        return md
    except RuntimeError:
        # Dump the engine log tail so the crash cause is visible, then re-raise.
        # finally still tears down the process + config + log file.
        try:
            log_file.flush()
        except Exception:
            pass
        with open(log_path, "r", errors="replace") as lf:
            tail = lf.read()[-4000:]
        print(f"[parity] ENGINE LOG TAIL:\n{tail}", file=sys.stderr)
        raise
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        log_file.close()
        os.remove(cfg_path)
        # Restore the user's original config.
        if backup and os.path.exists(backup):
            os.replace(backup, cfg_path)
        if os.path.exists(SOCK):
            os.remove(SOCK)
        if os.path.exists(log_path):
            os.remove(log_path)

def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else ".build/release/fusion-browser"
    if not os.path.exists(binary):
        print(f"[parity] binary not found: {binary}", file=sys.stderr)
        sys.exit(2)
    print(f"[parity] binary={binary}")
    md_swift = run_smoke(False, binary)
    print(f"[parity] swift markdown:\n{md_swift}\n---")
    md_rust = run_smoke(True, binary)
    print(f"[parity] rust markdown:\n{md_rust}\n---")
    if md_swift == md_rust:
        print(f"[parity] PASS: byte-identical (len={len(md_swift)})")
    else:
        print(f"[parity] FAIL: mismatch (swift len={len(md_swift)} rust len={len(md_rust)})", file=sys.stderr)
        # show first diff
        for i, (a, b) in enumerate(zip(md_swift, md_rust)):
            if a != b:
                print(f"[parity] first diff at char {i}: swift={a!r} rust={b!r}", file=sys.stderr)
                break
        sys.exit(1)

if __name__ == "__main__":
    main()
