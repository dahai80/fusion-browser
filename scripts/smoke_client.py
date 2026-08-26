#!/usr/bin/env python3
import json
import socket
import struct
import sys
import time

SOCK = "/tmp/fusion-browser-smoke.sock"

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
    token = sys.argv[1] if len(sys.argv) > 1 else "smoke-token"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    print("[client] connected")
    send(s, {"type": "auth", "token": token})
    ack = recv_one(s)
    print(f"[client] auth ack: {ack}")
    if not ack or ack.get("type") != "auth_ack":
        print("[client] AUTH FAILED", file=sys.stderr)
        sys.exit(1)
    send(s, {"type": "create_session", "payload": {"mode": "headless"}})
    cr = recv_one(s)
    print(f"[client] create_session: {cr}")
    sid = cr.get("payload", {}).get("session_id")
    if not sid:
        print("[client] NO SESSION ID", file=sys.stderr)
        sys.exit(1)
    send(s, {"type": "close", "session_id": sid})
    cl = recv_one(s)
    print(f"[client] close: {cl}")
    s.close()
    print("[client] OK")

if __name__ == "__main__":
    main()
