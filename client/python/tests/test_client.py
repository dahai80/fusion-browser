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

from fusion_browser_client import (FusionBrowserClient, FusionBrowserStream, FBError, BBox,
                                   AXTreeNode, CapacityInfo)


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
                for frame in (resp if isinstance(resp, list) else [resp]):
                    _send(conn, frame)
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
        if t == "import_cookies":
            p = msg.get("payload", {})
            return {"type": "import_cookies", "payload": {
                "session_id": p.get("session_id"), "browser": p.get("browser"),
                "imported": 3, "skipped_app_bound": 1, "skipped_other": 0}}
        if t == "delete_profile":
            return {"type": "profile_deleted", "payload": {
                "profile_id": msg.get("payload", {}).get("profile_id"), "deleted": True}}
        if t == "stream_screenshots":
            if not msg.get("payload", {}).get("enabled"):
                return {"type": "stream_ack", "payload": {"session_id": "s1", "active": False}}
            # Issue #25: ack first, then one frame + the terminal stream_end event.
            return [
                {"type": "stream_ack", "payload": {"session_id": "s1", "active": True}},
                {"type": "screenshot_frame", "session_id": "s1", "seq": 1,
                 "png": base64.b64encode(b"PNGDATA").decode(),
                 "url": "https://x", "title": "T", "ts_ms": 1700000000000},
                {"type": "stream_end", "session_id": "s1", "reason": "session_closed"},
            ]
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


# -- Issue #25: profiles, cookie import, screenshot stream -------------------


def test_create_session_passes_profile_id(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        c.create_session(profile_id="workflow-run-42")
    create = [r for r in srv.requests if r["type"] == "create_session"][0]
    assert create["payload"]["profile_id"] == "workflow-run-42"


def test_create_session_without_profile_omits_key(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        c.create_session()
    create = [r for r in srv.requests if r["type"] == "create_session"][0]
    assert "profile_id" not in create["payload"]


def test_import_cookies_returns_payload(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        res = c.import_cookies("s1", "chrome", profile="Default")
    assert res["imported"] == 3
    assert res["skipped_app_bound"] == 1
    req = [r for r in srv.requests if r["type"] == "import_cookies"][0]
    assert req["payload"] == {"session_id": "s1", "browser": "chrome", "profile": "Default"}


def test_delete_profile_returns_bool(fake_server):
    srv, path = fake_server
    with FusionBrowserClient(socket_path=path, token="test-token") as c:
        assert c.delete_profile("workflow-run-42") is True
    req = [r for r in srv.requests if r["type"] == "delete_profile"][0]
    assert req["payload"]["profile_id"] == "workflow-run-42"


def test_stream_yields_frame_then_stops_on_stream_end(fake_server):
    srv, path = fake_server
    stream = FusionBrowserStream("s1", socket_path=path, token="test-token")
    try:
        frames = list(stream.frames())
    finally:
        stream.close()
    assert len(frames) == 1
    assert frames[0]["type"] == "screenshot_frame"
    assert frames[0]["seq"] == 1
    assert frames[0]["url"] == "https://x"
    assert base64.b64decode(frames[0]["png"]) == b"PNGDATA"
    types = [r["type"] for r in srv.requests]
    assert types[0] == "auth"
    assert "stream_screenshots" in types


# -- Issue #19: connection desync after mid-frame transport faults ------------


class FaultServer(FakeServer):
    """Issue #19: the FIRST connection is sabotaged mid-response; later
    connections behave like a healthy FakeServer (used to prove the client
    closed the dead connection and auto-reconnected).

    mode:
      - "stall":    header claims 1000 bytes, only 10 sent, then holds the
                    socket open past the client timeout (socket.timeout path)
      - "truncated": header + partial body, then closes mid-frame (EOF path)
      - "huge_len": header claims 5GB — over the 64MB frame cap
    """

    def __init__(self, path, mode, token="test-token"):
        super().__init__(path, token)
        self.mode = mode
        self._fault_injected = False

    def _handle(self, conn):
        if self._fault_injected:
            super()._handle(conn)
            return
        self._fault_injected = True
        try:
            msg = _recv_one(conn)
            if msg is None or msg.get("type") == "auth":
                if msg is not None:
                    _send(conn, {"type": "auth_ack"})
                    msg = _recv_one(conn)
                if msg is None:
                    return
                self.requests.append(msg)
            if self.mode == "stall":
                conn.sendall(struct.pack(">I", 1000) + b"x" * 10)
                while not self._stop:
                    time.sleep(0.05)
            elif self.mode == "truncated":
                conn.sendall(struct.pack(">I", 1000) + b"x" * 10)
            elif self.mode == "huge_len":
                # u32 max is 4GB-1 — 3GB still dwarfs the 64MB cap.
                conn.sendall(struct.pack(">I", 3 * 1024 * 1024 * 1024))
                while not self._stop:
                    time.sleep(0.05)
        except OSError:
            pass
        finally:
            conn.close()


@pytest.fixture
def fault_server(tmp_path):
    def make(mode):
        fd, path = tempfile.mkstemp(suffix=".sock", dir="/tmp", prefix="fbc-fault-")
        os.close(fd)
        os.unlink(path)
        srv = FaultServer(path, mode=mode, token="test-token")
        srv.start()
        return srv, path

    yield make


def _drain_fault_server(srv):
    srv.stop()


def test_mid_frame_timeout_closes_connection_and_reconnects(fault_server):
    srv, path = fault_server("stall")
    try:
        c = FusionBrowserClient(socket_path=path, token="test-token", timeout=0.5)
        with pytest.raises(FBError) as exc:
            c.metrics()
        assert exc.value.code == "connection_closed"
        assert "transport fault" in exc.value.message
        # Issue #19 core assertion: the desynced connection must be gone, not kept.
        assert c._sock is None
        assert c._authed is False
        # Next op auto-reconnects on a fresh, healthy connection.
        m = c.metrics()
        assert m == {"counters": [["sessions", 1]]}
        c.close()
    finally:
        _drain_fault_server(srv)


def test_truncated_body_closes_connection_and_reconnects(fault_server):
    srv, path = fault_server("truncated")
    try:
        c = FusionBrowserClient(socket_path=path, token="test-token", timeout=5.0)
        with pytest.raises(FBError) as exc:
            c.metrics()
        assert exc.value.code == "connection_closed"
        assert "server closed mid-frame" in exc.value.message
        assert c._sock is None
        assert c._authed is False
        m = c.metrics()
        assert m == {"counters": [["sessions", 1]]}
        c.close()
    finally:
        _drain_fault_server(srv)


def test_over_cap_frame_length_fails_fast_and_closes(fault_server):
    srv, path = fault_server("huge_len")
    try:
        c = FusionBrowserClient(socket_path=path, token="test-token", timeout=30.0)
        t0 = time.monotonic()
        with pytest.raises(FBError) as exc:
            c.metrics()
        elapsed = time.monotonic() - t0
        # Fails from the decoded length field, NOT by reading 3GB.
        assert elapsed < 5.0
        assert exc.value.code == "connection_closed"
        assert "exceeds cap" in exc.value.message
        # Issue #19 residual hole: the cap FBError must also kill the connection.
        assert c._sock is None
        assert c._authed is False
        m = c.metrics()
        assert m == {"counters": [["sessions", 1]]}
        c.close()
    finally:
        _drain_fault_server(srv)
