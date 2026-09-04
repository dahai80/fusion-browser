"""Unit tests for fusion_browser_client against a fake UDS server.

Deterministic: spawns a thread running a loopback AF_UNIX echo-server that
speaks the length-prefixed JSON protocol + auth handshake. No live engine.
"""

import base64
import json
import os
import socket
import struct
import tempfile
import threading
import time

import pytest

from fusion_browser_client import FusionBrowserClient, FBError, BBox, AXTreeNode, CapacityInfo


def _send(sock, obj):
    data = json.dumps(obj).encode()
    sock.sendall(struct.pack(">I", len(data)) + data)


def _recv_one(sock):
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


class FakeServer:
    """Loopback AF_UNIX server speaking the fusion-browser wire protocol."""

    def __init__(self, path, token="test-token"):
        self.path = path
        self.token = token
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(8)
        self.server.settimeout(10)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.requests = []
        self._stop = False

    def start(self):
        self.thread.start()

    def stop(self):
        self._stop = True
        try:
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.connect(self.path)
            c.close()
        except OSError:
            pass
        self.server.close()

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self.server.accept()
            except OSError:
                break
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        try:
            while True:
                msg = _recv_one(conn)
                if msg is None:
                    break
                self.requests.append(msg)
                resp = self._respond(msg)
                if resp is None:
                    break
                _send(conn, resp)
        except OSError:
            pass
        finally:
            conn.close()

    def _respond(self, msg):
        t = msg.get("type")
        if t == "auth":
            if msg.get("token") == self.token:
                return {"type": "auth_ack"}
            return {"type": "error", "payload": {"code": "auth_denied", "message": "bad", "retryable": False}}
        if t == "create_session":
            return {"type": "create_session", "payload": {"session_id": "s1", "credentialInjected": False}}
        if t == "execute":
            return {"type": "state", "payload": {
                "session_id": "s1", "url": "https://x", "title": "T",
                "ax_tree_markdown": "# Page", "interactive_nodes": [
                    {"node_id": "e1", "role": "button", "name": "Go", "is_disabled": False,
                     "current_value": "", "bbox": {"x": 1, "y": 2, "width": 3, "height": 4}},
                    {"node_id": "e2", "role": "link", "name": "y", "is_disabled": False, "current_value": ""},
                ],
                "screenshot_png": base64.b64encode(b"PNGDATA").decode(),
                "has_security_injection_blocked": False, "execution_time_ms": 5,
                "session_recovered": False, "evaluate_result": None}}
        if t == "close":
            return {"type": "closed", "sessionId": msg.get("session_id")}
        if t == "metrics":
            return {"type": "metrics", "payload": {"counters": [["sessions", 1]]}}
        if t == "capacity":
            return {"type": "capacity", "payload": {
                "node_id": "UUID", "max_sessions": 16, "live_sessions": 1,
                "max_total_memory_mb": 2400, "free_memory_mb": 90000, "ram_gb": 128}}
        return {"type": "error", "payload": {"code": "unknown", "message": "unhandled", "retryable": False}}


@pytest.fixture
def fake_server():
    # macOS AF_UNIX path limit ~104 chars; pytest tmp_path is too deep. Use /tmp.
    fd, path = tempfile.mkstemp(suffix=".sock", dir="/tmp", prefix="fbc-")
    os.close(fd)
    os.unlink(path)  # mkstemp creates the file; bind needs a free path
    srv = FakeServer(path, token="test-token")
    srv.start()
    yield srv, path
    srv.stop()
    if os.path.exists(path):
        os.unlink(path)


def test_auth_handshake_and_create(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        sid = c.create_session(mode="headless", initial_url="data:text/html,<html></html>")
    assert sid == "s1"
    assert srv.requests[0]["type"] == "auth"
    assert srv.requests[1]["type"] == "create_session"


def test_auth_denied_raises(fake_server):
    srv, path = fake_server
    c = FusionBrowserClient(socket_path=path, token="wrong")
    with pytest.raises(FBError) as exc:
        c.create_session()
    assert exc.value.code == "auth_denied"


def test_execute_returns_nodes_with_bbox(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        sid = c.create_session()
        st = c.execute(sid, action="screenshot")
    assert st.sessionId == "s1"
    assert len(st.interactiveNodes) == 2
    n0 = st.interactiveNodes[0]
    assert n0.nodeId == "e1"
    assert n0.bbox is not None
    assert (n0.bbox.x, n0.bbox.y, n0.bbox.width, n0.bbox.height) == (1.0, 2.0, 3.0, 4.0)
    assert st.interactiveNodes[1].bbox is None
    assert st.screenshotPng == b"PNGDATA"


def test_convenience_methods(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        sid = c.create_session()
        c.navigate(sid, "https://x")
        c.click(sid, "e1")
        c.type_text(sid, "e1", "hi")
        c.screenshot(sid)
        c.evaluate(sid, "1+1")
        c.close_session(sid)
    types = [r["type"] for r in srv.requests]
    assert types == ["auth", "create_session", "execute", "execute", "execute",
                     "execute", "execute", "close"]


def test_capacity(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        cap = c.capacity()
    assert cap.nodeId == "UUID"
    assert cap.maxSessions == 16
    assert cap.liveSessions == 1
    assert cap.ramGb == 128


def test_metrics(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        m = c.metrics()
    assert m == {"counters": [["sessions", 1]]}


def test_error_response_raises(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        with pytest.raises(FBError) as exc:
            c._request({"type": "bogus_type"})
    assert exc.value.code == "unknown"


def test_bbox_from_dict_none():
    assert BBox.from_dict(None) is None
    assert BBox.from_dict({}) is None  # empty dict treated as absent


def test_axtreenode_from_dict_minimal():
    n = AXTreeNode.from_dict({"nodeId": "e9", "role": "button"})
    assert n.nodeId == "e9"
    assert n.bbox is None
