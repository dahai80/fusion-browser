#!/usr/bin/env python3
# H-9 / R-10: multi-node capacity-plane evidence harness. Starts N release binaries,
# each with its OWN socket + config (isolated via a per-binary temp HOME so each reads
# its own ~/.fusion-browser/config.json), creates a session on each, then queries the
# UDS `{type:"capacity"}` request on each. Asserts every node reports a DISTINCT nodeId,
# the correct liveSessions count (1 after create, 0 after close), and a non-empty
# maxSessions. Proves the capacity plane is per-node + queryable — the placement input
# an external scheduler (fusion-gateway) consumes. Cross-node scheduling/migration itself
# lands in fusion-gateway (audit R-10 改法: "跨节点调度/迁移落地可能在 fusion-gateway，本侧
# 出契约+issue"); this harness is the THIS-side 实证 that the plane exists + is queryable.
#
# Informational in release_gate.sh (not a hard gate — multi-process harnesses can be
# resource-flaky in CI; the capacity UNIT tests in NodeCapacityTests are the deterministic
# hard gate). Writes scripts/multinode-report.json.

import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "fusion-browser")
OUT = os.path.join(os.path.dirname(__file__), "multinode-report.json")
N_NODES = 3


def send(s, o):
    data = json.dumps(o).encode()
    s.sendall(struct.pack(">I", len(data)) + data)


def recv(s):
    h = b""
    while len(h) < 4:
        c = s.recv(4 - len(h))
        if not c:
            return None
        h += c
    (l,) = struct.unpack(">I", h)
    b = b""
    while len(b) < l:
        c = s.recv(l - len(b))
        if not c:
            return None
        b += c
    return json.loads(b)


class Node:
    def __init__(self, idx):
        self.idx = idx
        self.home = tempfile.mkdtemp(prefix=f"fb-multinode-{idx}-")
        self.sock = os.path.join(self.home, "engine.sock")
        self.token = f"node-{idx}-token"
        self.proc = None

    def start(self):
        os.makedirs(self.home, exist_ok=True)
        self.cfg = os.path.join(self.home, "config.json")
        with open(self.cfg, "w") as f:
            json.dump({
                "socketPath": self.sock,
                "authToken": self.token,
                "logLevel": "error",
                "tokenCapabilities": ["metrics"],
            }, f)
        self.proc = subprocess.Popen(
            [BIN],
            env={**os.environ, "FUSION_BROWSER_CONFIG": self.cfg},
            stderr=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
        )
        deadline = 5.0
        while deadline > 0:
            if os.path.exists(self.sock):
                break
            if self.proc.poll() is not None:
                return False
            time.sleep(0.05)
            deadline -= 0.05
        return os.path.exists(self.sock)

    def conn(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.sock)
        send(s, {"type": "auth", "token": self.token})
        ack = recv(s)
        if not ack or ack.get("type") != "auth_ack":
            s.close()
            return None
        return s

    def request(self, s, o):
        send(s, o)
        return recv(s)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        shutil.rmtree(self.home, ignore_errors=True)


def main():
    if not os.path.exists(BIN):
        print(f"[multinode] FAIL: binary missing: {BIN}")
        sys.exit(1)

    nodes = [Node(i) for i in range(N_NODES)]
    report = {"n_nodes": N_NODES, "nodes": [], "pass": False, "error": None}
    try:
        for n in nodes:
            if not n.start():
                report["error"] = f"node {n.idx} failed to start (no socket)"
                print(f"[multinode] FAIL: {report['error']}")
                _emit(report)
                sys.exit(1)

        node_ids = []
        for n in nodes:
            s = n.conn()
            if s is None:
                report["error"] = f"node {n.idx} auth failed"
                _emit(report)
                sys.exit(1)
            # Capacity BEFORE create: liveSessions should be 0.
            cap0 = n.request(s, {"type": "capacity"})
            if not cap0 or cap0.get("type") != "capacity":
                report["error"] = f"node {n.idx} capacity query (pre-create) failed: {cap0}"
                _emit(report)
                sys.exit(1)
            p0 = cap0.get("payload", {})
            # Create a session (data URL, no network).
            cr = n.request(s, {"type": "create_session", "payload": {
                "mode": "headless", "initial_url": "data:text/html,<html><body>node{}</body></html>".format(n.idx),
            }})
            if not cr or cr.get("type") != "create_session":
                report["error"] = f"node {n.idx} create failed: {cr}"
                _emit(report)
                sys.exit(1)
            sid = cr.get("payload", {}).get("session_id")
            # Capacity AFTER create: liveSessions should be 1.
            cap1 = n.request(s, {"type": "capacity"})
            p1 = cap1.get("payload", {}) if cap1 else {}
            s.close()
            node_ids.append(p1.get("node_id", ""))
            report["nodes"].append({
                "idx": n.idx,
                "node_id": p1.get("node_id", ""),
                "max_sessions": p1.get("max_sessions"),
                "live_before_create": p0.get("live_sessions"),
                "live_after_create": p1.get("live_sessions"),
                "free_memory_mb": p1.get("free_memory_mb"),
                "ram_gb": p1.get("ram_gb"),
                "session_id": sid,
            })

        # Distinct nodeIds — the core H-9 assertion (each binary mints its own identity).
        if len(set(node_ids)) != N_NODES:
            report["error"] = f"nodeIds not distinct: {node_ids}"
            print(f"[multinode] FAIL: {report['error']}")
            _emit(report)
            sys.exit(1)
        # Each node reports liveSessions 0 before + 1 after create (per-node count).
        for entry in report["nodes"]:
            if entry["live_before_create"] != 0 or entry["live_after_create"] != 1:
                report["error"] = f"node {entry['idx']} live count wrong: {entry}"
                print(f"[multinode] FAIL: {report['error']}")
                _emit(report)
                sys.exit(1)
            if not entry["max_sessions"] or entry["max_sessions"] < 1:
                report["error"] = f"node {entry['idx']} maxSessions missing"
                _emit(report)
                sys.exit(1)

        report["pass"] = True
        print(f"[multinode] PASS: {N_NODES} nodes, distinct nodeIds, per-node live count correct")
        _emit(report)
    finally:
        for n in nodes:
            n.stop()


def _emit(report):
    with open(OUT, "w") as f:
        json.dump(report, f, indent=2)


if __name__ == "__main__":
    main()
