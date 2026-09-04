"""fusion-browser UDS JSON-RPC client implementation.

Length-prefixed JSON framing ([u32 BE len][JSON], snake_case keys). One frame per
request-response; the server closes after an error. Auth handshake is the first
frame on every fresh connection (the engine closes after one op when driven by a
per-call-dial proxy, so re-auth each connect).

Logging: module-level `logging.getLogger("fusion_browser_client")` — callers
configure handlers/level. Default no handler = silent under library use.
"""

import json
import logging
import socket
import struct
from dataclasses import dataclass, field
from typing import Any, Optional

log = logging.getLogger("fusion_browser_client")

_DEFAULT_SOCKET = "/tmp/fusion-browser.sock"
_HEADER = struct.Struct(">I")


class FBError(Exception):
    """Structured engine error: {code, message, retryable}."""

    def __init__(self, code: str, message: str, retryable: bool = False):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.retryable = retryable

    @classmethod
    def from_payload(cls, payload: dict) -> "FBError":
        return cls(
            code=payload.get("code", "unknown"),
            message=payload.get("message", ""),
            retryable=bool(payload.get("retryable", False)),
        )


@dataclass
class BBox:
    x: float
    y: float
    width: float
    height: float

    @classmethod
    def from_dict(cls, d: Optional[dict]) -> Optional["BBox"]:
        if not d:
            return None
        return cls(
            x=float(d.get("x", 0)),
            y=float(d.get("y", 0)),
            width=float(d.get("width", 0)),
            height=float(d.get("height", 0)),
        )


@dataclass
class AXTreeNode:
    nodeId: str
    role: str
    name: str
    isDisabled: bool = False
    currentValue: str = ""
    bbox: Optional[BBox] = None

    @classmethod
    def from_dict(cls, d: dict) -> "AXTreeNode":
        return cls(
            nodeId=d.get("node_id", "") or d.get("nodeId", ""),
            role=d.get("role", ""),
            name=d.get("name", ""),
            isDisabled=bool(d.get("is_disabled", d.get("isDisabled", False))),
            currentValue=d.get("current_value", d.get("currentValue", "")),
            bbox=BBox.from_dict(d.get("bbox")),
        )


@dataclass
class SessionInfo:
    """Result of create_session + a subsequent state extract."""

    sessionId: str
    url: str = ""
    title: str = ""
    axTreeMarkdown: str = ""
    interactiveNodes: list = field(default_factory=list)
    screenshotPng: Optional[bytes] = None
    hasSecurityInjectionBlocked: bool = False
    executionTimeMs: int = 0
    sessionRecovered: bool = False
    evaluateResult: Optional[str] = None

    @classmethod
    def from_state(cls, d: dict) -> "SessionInfo":
        png = d.get("screenshot_png", d.get("screenshotPng"))
        png_bytes = None
        if png:
            import base64
            try:
                png_bytes = base64.b64decode(png)
            except Exception:
                png_bytes = None
        nodes = [AXTreeNode.from_dict(n) for n in d.get("interactive_nodes", d.get("interactiveNodes", []))]
        return cls(
            sessionId=d.get("session_id", d.get("sessionId", "")),
            url=d.get("url", ""),
            title=d.get("title", ""),
            axTreeMarkdown=d.get("ax_tree_markdown", d.get("axTreeMarkdown", "")),
            interactiveNodes=nodes,
            screenshotPng=png_bytes,
            hasSecurityInjectionBlocked=bool(d.get("has_security_injection_blocked", d.get("hasSecurityInjectionBlocked", False))),
            executionTimeMs=int(d.get("execution_time_ms", d.get("executionTimeMs", 0))),
            sessionRecovered=bool(d.get("session_recovered", d.get("sessionRecovered", False))),
            evaluateResult=d.get("evaluate_result", d.get("evaluateResult")),
        )


@dataclass
class CapacityInfo:
    nodeId: str
    maxSessions: int
    liveSessions: int
    maxTotalMemoryMb: int
    freeMemoryMb: int
    ramGb: int

    @classmethod
    def from_dict(cls, d: dict) -> "CapacityInfo":
        return cls(
            nodeId=d.get("node_id", ""),
            maxSessions=int(d.get("max_sessions", 0)),
            liveSessions=int(d.get("live_sessions", 0)),
            maxTotalMemoryMb=int(d.get("max_total_memory_mb", 0)),
            freeMemoryMb=int(d.get("free_memory_mb", 0)),
            ramGb=int(d.get("ram_gb", 0)),
        )


class FusionBrowserClient:
    """Synchronous UDS client. One connection per instance; reconnects on demand.

    The engine is per-call-dial friendly (a proxy may dial fresh per op), but this
    client keeps ONE persistent connection for its lifetime — the auth handshake
    runs once on connect. For proxy/per-call use, create a client per op or call
    `close()` + the next method (auto-reconnect).
    """

    def __init__(self, socket_path: str = _DEFAULT_SOCKET, token: Optional[str] = None, timeout: float = 30.0):
        self.socket_path = socket_path
        self.token = token
        self.timeout = timeout
        self._sock: Optional[socket.socket] = None
        self._authed = False

    # -- framing -----------------------------------------------------------

    @staticmethod
    def _send(sock: socket.socket, obj: dict) -> None:
        data = json.dumps(obj).encode()
        sock.sendall(_HEADER.pack(len(data)) + data)

    @staticmethod
    def _recv_one(sock: socket.socket) -> Optional[dict]:
        hdr = b""
        while len(hdr) < 4:
            chunk = sock.recv(4 - len(hdr))
            if not chunk:
                return None
            hdr += chunk
        (length,) = _HEADER.unpack(hdr)
        body = b""
        while len(body) < length:
            chunk = sock.recv(length - len(body))
            if not chunk:
                return None
            body += chunk
        return json.loads(body)

    # -- connection / auth -------------------------------------------------

    def _connect(self) -> None:
        if self._sock is not None:
            return
        log.debug("connect socket=%s", self.socket_path)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.socket_path)
        self._sock = s
        self._auth()

    def _auth(self) -> None:
        if self._authed or self._sock is None:
            return
        self._send(self._sock, {"type": "auth", "token": self.token})
        ack = self._recv_one(self._sock)
        if not ack or ack.get("type") != "auth_ack":
            self.close()
            payload = (ack or {}).get("payload", {})
            raise FBError.from_payload(payload) if payload else FBError("auth_denied", "no auth_ack")
        self._authed = True
        log.debug("auth_ack received")

    def _request(self, frame: dict) -> dict:
        self._connect()
        assert self._sock is not None
        self._send(self._sock, frame)
        resp = self._recv_one(self._sock)
        if resp is None:
            self.close()
            raise FBError("connection_closed", "server closed mid-frame")
        if resp.get("type") == "error":
            self.close()
            raise FBError.from_payload(resp.get("payload", {}))
        return resp

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        self._authed = False

    # -- ops ---------------------------------------------------------------

    def create_session(self, mode: str = "headless", initial_url: Optional[str] = None,
                       credentials: Optional[list] = None) -> str:
        payload: dict = {"mode": mode}
        if initial_url is not None:
            payload["initial_url"] = initial_url
        if credentials is not None:
            payload["credentials"] = credentials
        resp = self._request({"type": "create_session", "payload": payload})
        cr = resp.get("payload", {})
        sid = cr.get("session_id")
        if not sid:
            raise FBError("internal_error", "create_session returned no session_id")
        log.info("create_session id=%s credentialInjected=%s", sid, cr.get("credentialInjected"))
        return sid

    def execute(self, session_id: str, action: str, target_node_id: Optional[str] = None,
                payload_text: Optional[str] = None, trace_id: Optional[str] = None) -> SessionInfo:
        p: dict = {"session_id": session_id, "action": action}
        if target_node_id is not None:
            p["target_node_id"] = target_node_id
        if payload_text is not None:
            p["payload_text"] = payload_text
        if trace_id is not None:
            p["trace_id"] = trace_id
        resp = self._request({"type": "execute", "payload": p})
        return SessionInfo.from_state(resp.get("payload", {}))

    def navigate(self, session_id: str, url: str) -> SessionInfo:
        return self.execute(session_id, action="navigate", payload_text=url)

    def click(self, session_id: str, node_id: str) -> SessionInfo:
        return self.execute(session_id, action="click", target_node_id=node_id)

    def type_text(self, session_id: str, node_id: str, text: str) -> SessionInfo:
        return self.execute(session_id, action="type_text", target_node_id=node_id, payload_text=text)

    def scroll(self, session_id: str, payload_text: Optional[str] = None) -> SessionInfo:
        return self.execute(session_id, action="scroll", payload_text=payload_text)

    def screenshot(self, session_id: str) -> SessionInfo:
        return self.execute(session_id, action="screenshot")

    def evaluate(self, session_id: str, script: str) -> SessionInfo:
        return self.execute(session_id, action="evaluate", payload_text=script)

    def close_session(self, session_id: str) -> None:
        self._request({"type": "close", "session_id": session_id})
        log.info("close_session id=%s", session_id)

    def metrics(self) -> dict:
        resp = self._request({"type": "metrics"})
        return resp.get("payload", {})

    def capacity(self) -> CapacityInfo:
        resp = self._request({"type": "capacity"})
        return CapacityInfo.from_dict(resp.get("payload", {}))

    # -- context manager ---------------------------------------------------

    def __enter__(self) -> "FusionBrowserClient":
        self._connect()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()
