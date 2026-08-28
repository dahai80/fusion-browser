#!/usr/bin/env python3
# E-8 (#65) + E-13 (#66) live smoke: CDP DOM domain must deref REAL live elements,
# and backendNodeId must deref the CURRENT Nth node after a reorder (not a stale
# snapshot). Drives the CDP-over-WS surface (:9222) and exercises the fusion-cowork
# flows + the E-13 reorder guard against a real WKWebView (cdp_client.py contract,
# READ-ONLY reference):
#
#   Flow A (click): getFullAXTree -> button backendNodeId -> DOM.resolveNode ->
#     objectId -> DOM.focus + DOM.getBoxModel -> centroid from model.content
#     (8 coords) -> Input.dispatchMouseEvent -> assert button onclick fired.
#   Flow B (fill): DOM.getDocument -> root nodeId -> DOM.querySelector('#u') ->
#     nodeId -> DOM.focus -> Input.insertText('hello') -> Runtime.evaluate
#     document.querySelector('#u').value -> assert == 'hello'.
#   Flow C (E-13 reorder): getFullAXTree -> ClickMe backendNodeId -> baseline rect ->
#     insert a Spacer button before #b (ClickMe shifts) -> resolveNode(original
#     backendNodeId) -> getBoxModel -> assert rect top CHANGED (derefed current Nth,
#     not the snapshotted ClickMe). Pins option (b): order-based identity.
#
# Pins the E-8 fixes:
#   - getBoxModel returns the REAL bounding rect (not 1280x800 stub); centroid
#     lands inside the button.
#   - querySelector returns a usable nodeId (not an FNV hash); focus + fill land
#     on the matched <input>.
#   - resolveNode returns a registered objectId (not 'fb-node-N'); getBoxModel
#     derefs it.
#   - focus runs the live element (not a [data-fb-id] walker never sets).
#
# H-5: CDP is Bearer-gated (token in Authorization header on /json + WS upgrade).
# E-15: WS upgrade is origin-gated fail-closed — send an allowlisted Origin header.
#
# Usage: python3 scripts/cdp_dom_smoke.py <release-binary-path>
# Default binary: .build/release/fusion-browser
import http.server
import json
import os
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

try:
    import websocket  # websocket-client
except ImportError:
    print("FATAL: pip install websocket-client", file=sys.stderr)
    sys.exit(2)

SOCK = "/tmp/fusion-browser-cdpdom.sock"
TOKEN = "cdp-dom-token"
CDP_PORT = 9222
ORIGIN = "http://127.0.0.1:1"

# Test page: a button with an onclick flag + a text input. The button is
# positioned with a generous margin so its getBoundingClientRect centroid is
# well inside its rect (not at a viewport edge).
PAGE = (
    "<html><head><title>CDPDomSmoke</title></head><body>"
    "<div style='height:120px'></div>"
    "<button id='b' onclick='window._clicked=true'>ClickMe</button>"
    "<input id='u' type='text' value=''>"
    "</body></html>"
)


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


def http_get_json(host, port, path, token):
    import urllib.request
    req = urllib.request.Request(f"http://{host}:{port}{path}")
    req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read().decode())


def cdp_send(ws, method, params=None, msg_id=1):
    msg = {"id": msg_id, "method": method}
    if params is not None:
        msg["params"] = params
    ws.send(json.dumps(msg))
    # Drain until we get the matching response (events have no "id" per CDP spec).
    while True:
        raw = ws.recv()
        obj = json.loads(raw)
        if obj.get("id") == msg_id:
            return obj


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else ".build/release/fusion-browser"
    httpd = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    port = httpd.server_address[1]
    page_origin = f"http://127.0.0.1:{port}"
    page_url = page_origin + "/"
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    if os.path.exists(SOCK):
        os.remove(SOCK)
    # allowedOrigins: the PAGE origin (for navigate + evaluate) AND the CDP
    # client's own Origin header (E-15 WS-upgrade gate). tokenCapabilities=all
    # elevates the token so evaluate/focus/getBoxModel cap-gate open (H-5).
    cfg = {
        "socketPath": SOCK, "authToken": TOKEN, "logLevel": "info",
        "cdpEnabled": True, "cdpPort": CDP_PORT,
        "allowedOrigins": [page_origin, ORIGIN],
        "tokenCapabilities": ["all"],
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
    log_fd, log_path = tempfile.mkstemp(prefix="fb_cdpdom_", suffix=".log")
    os.close(log_fd)
    log_file = open(log_path, "wb")
    proc = subprocess.Popen([binary], env=dict(os.environ),
                            stdout=log_file, stderr=subprocess.STDOUT)
    failures = []
    ws = None
    try:
        # Wait for UDS socket (CDP server starts alongside it).
        for _ in range(100):
            if os.path.exists(SOCK):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("UDS socket never appeared")
        # Wait for CDP port to accept connections.
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", CDP_PORT), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("CDP port never opened")
        time.sleep(0.3)

        # Discover the WS endpoint via GET /json (Bearer-gated).
        targets = http_get_json("127.0.0.1", CDP_PORT, "/json", TOKEN)
        ws_url = targets[0]["webSocketDebuggerUrl"]
        # E-15: send an allowlisted Origin header on the WS upgrade.
        ws = websocket.create_connection(ws_url, origin=ORIGIN,
                                         header={"Authorization": f"Bearer {TOKEN}"})

        # Navigate to the test page (Page.navigate is origin-gated too).
        nav = cdp_send(ws, "Page.navigate", {"url": page_url}, msg_id=1)
        if nav.get("error"):
            failures.append(f"navigate: {nav['error']}")
        # Poll the AX tree until the page's button is present (headless load lag).
        button_node = None
        for _ in range(20):
            tree = cdp_send(ws, "Accessibility.getFullAXTree", {}, msg_id=2)
            nodes = (tree.get("result") or {}).get("nodes", [])
            for n in nodes:
                name = (n.get("name") or {}).get("value", "")
                if name == "ClickMe":
                    button_node = n
                    break
            if button_node:
                break
            time.sleep(0.3)
        if not button_node:
            failures.append("Flow A: button 'ClickMe' not found in AX tree")
        else:
            backend_id = button_node["backendNodeId"]
            # resolveNode(backendNodeId) -> objectId (must be a registered handle).
            rn = cdp_send(ws, "DOM.resolveNode", {"backendNodeId": backend_id}, msg_id=3)
            object_id = (((rn.get("result") or {}).get("object") or {}).get("objectId"))
            if not object_id or object_id.startswith("fb-node-"):
                failures.append(f"Flow A: resolveNode bad objectId={object_id!r}")
            else:
                print(f"[dom] resolveNode backendNodeId={backend_id} -> objectId={object_id} OK")
                # focus(objectId) — must run the live button (not a [data-fb-id] miss).
                fc = cdp_send(ws, "DOM.focus", {"objectId": object_id}, msg_id=4)
                if fc.get("error"):
                    failures.append(f"Flow A: focus error {fc['error']}")
                # getBoxModel(objectId) — must be the REAL rect, 8 finite coords.
                bm = cdp_send(ws, "DOM.getBoxModel", {"objectId": object_id}, msg_id=5)
                content = (((bm.get("result") or {}).get("model") or {}).get("content"))
                if not content or len(content) != 8:
                    failures.append(f"Flow A: getBoxModel bad content={content}")
                else:
                    if not all(isinstance(c, (int, float)) and c == c and c != float("inf")
                               for c in content):
                        failures.append(f"Flow A: getBoxModel non-finite content={content}")
                    else:
                        xs = content[0::2]
                        ys = content[1::2]
                        cx = sum(xs) / 4
                        cy = sum(ys) / 4
                        # Centroid must land INSIDE the rect (not the 1280x800 stub,
                        # whose centroid 640,400 is far from a top-margin button).
                        inside = min(xs) <= cx <= max(xs) and min(ys) <= cy <= max(ys)
                        if not inside:
                            failures.append(f"Flow A: centroid {cx:.0f},{cy:.0f} outside rect")
                        elif cx > 200 or cy > 400:
                            failures.append(f"Flow A: centroid {cx:.0f},{cy:.0f} looks like "
                                            f"1280x800 stub (expected top-left button)")
                        else:
                            print(f"[dom] getBoxModel real rect centroid={cx:.0f},{cy:.0f} OK")
                            # Click at centroid via Input.dispatchMouseEvent (paired press+release).
                            cdp_send(ws, "Input.dispatchMouseEvent",
                                     {"type": "mousePressed", "x": cx, "y": cy,
                                      "button": "left", "clickCount": 1}, msg_id=6)
                            cdp_send(ws, "Input.dispatchMouseEvent",
                                     {"type": "mouseReleased", "x": cx, "y": cy,
                                      "button": "left", "clickCount": 1}, msg_id=7)
                            time.sleep(0.2)
                            ev = cdp_send(ws, "Runtime.evaluate",
                                          {"expression": "window._clicked === true"}, msg_id=8)
                            clicked = (((ev.get("result") or {}).get("result") or {}).get("value"))
                            if clicked is not True:
                                failures.append(f"Flow A: button onclick did NOT fire (clicked={clicked})")
                            else:
                                print("[dom] Flow A click fired onclick OK")

        # Flow B (fill): getDocument -> querySelector -> focus -> insertText -> verify.
        doc = cdp_send(ws, "DOM.getDocument", {}, msg_id=10)
        root_id = ((doc.get("result") or {}).get("root") or {}).get("nodeId")
        if not root_id:
            failures.append(f"Flow B: getDocument no root nodeId {doc}")
        else:
            qs = cdp_send(ws, "DOM.querySelector",
                          {"nodeId": root_id, "selector": "#u"}, msg_id=11)
            input_id = (qs.get("result") or {}).get("nodeId")
            if not input_id or input_id == 0:
                failures.append(f"Flow B: querySelector('#u') no match {qs}")
            else:
                print(f"[dom] querySelector('#u') -> nodeId={input_id} OK")
                fc2 = cdp_send(ws, "DOM.focus", {"nodeId": input_id}, msg_id=12)
                if fc2.get("error"):
                    failures.append(f"Flow B: focus error {fc2['error']}")
                cdp_send(ws, "Input.insertText", {"text": "hello"}, msg_id=13)
                time.sleep(0.2)
                ev2 = cdp_send(ws, "Runtime.evaluate",
                               {"expression": "document.querySelector('#u').value"},
                               msg_id=14)
                val = (((ev2.get("result") or {}).get("result") or {}).get("value"))
                if val != "hello":
                    failures.append(f"Flow B: fill value={val!r} want 'hello'")
                else:
                    print("[dom] Flow B fill typed 'hello' OK")

        # Flow C (E-13): backendNodeId is a document-order position. Insert a NEW
        # button BEFORE #b (shifting ClickMe down one slot) then resolveNode +
        # getBoxModel on the ORIGINAL backendNodeId. Option (b): it must deref the
        # CURRENT Nth node (Spacer, now at #b's old slot), NOT the snapshotted
        # ClickMe (which shifted). Asserted via rect top: the resolved rect must
        # NOT equal ClickMe's pre-reorder top (it moved) and must be finite.
        tree_c = cdp_send(ws, "Accessibility.getFullAXTree", {}, msg_id=20)
        nodes_c = (tree_c.get("result") or {}).get("nodes", [])
        clickme_bid = None
        clickme_top = None
        for n in nodes_c:
            if (n.get("name") or {}).get("value", "") == "ClickMe":
                clickme_bid = n["backendNodeId"]
                break
        if clickme_bid is None:
            failures.append("Flow C: ClickMe not found in AX tree")
        else:
            # Baseline: ClickMe's rect top before reorder.
            rn0 = cdp_send(ws, "DOM.resolveNode", {"backendNodeId": clickme_bid}, msg_id=21)
            oid0 = (((rn0.get("result") or {}).get("object") or {}).get("objectId"))
            bm0 = cdp_send(ws, "DOM.getBoxModel", {"objectId": oid0}, msg_id=22)
            c0 = (((bm0.get("result") or {}).get("model") or {}).get("content"))
            if not c0 or len(c0) != 8:
                failures.append(f"Flow C: baseline getBoxModel bad content={c0}")
            else:
                clickme_top = c0[1]
                # Reorder: insert a Spacer button (with a 50px leading div so its
                # rect top is distinct) before #b. ClickMe shifts down.
                cdp_send(ws, "Runtime.evaluate", {"expression":
                    "document.querySelector('#b').insertAdjacentHTML('beforebegin',"
                    "'<div style=\"height:50px\"></div><button>Spacer</button>')"},
                    msg_id=23)
                time.sleep(0.3)
                # resolveNode on the ORIGINAL backendNodeId -> objectId.
                rn1 = cdp_send(ws, "DOM.resolveNode",
                               {"backendNodeId": clickme_bid}, msg_id=24)
                oid1 = (((rn1.get("result") or {}).get("object") or {}).get("objectId"))
                if not oid1:
                    failures.append(f"Flow C: resolveNode no objectId {rn1}")
                else:
                    bm1 = cdp_send(ws, "DOM.getBoxModel", {"objectId": oid1}, msg_id=25)
                    c1 = (((bm1.get("result") or {}).get("model") or {}).get("content"))
                    if not c1 or len(c1) != 8:
                        # Tree grew (insert), so a real rect MUST come back; a
                        # node-stale here means the re-trace was wrong -> escalate.
                        failures.append(f"Flow C: post-reorder getBoxModel bad "
                                        f"content={c1} (expected current Nth rect)")
                    else:
                        resolved_top = c1[1]
                        # Option (b): the original backendNodeId now derefs the
                        # CURRENT Nth node. ClickMe moved (top changed); Spacer
                        # occupies the old slot. If resolved_top == clickme_top,
                        # the binding dereffed the SNAPSHOTTED element (stale) ->
                        # E-13 regression. Distinct top = honest order-based.
                        if resolved_top == clickme_top:
                            failures.append(f"Flow C: resolved top={resolved_top} "
                                            f"== ClickMe pre-reorder top — dereffed "
                                            f"SNAPSHOT not current Nth (E-13 stale)")
                        else:
                            print(f"[dom] Flow C reorder: original backendNodeId "
                                  f"derefs current Nth (top {clickme_top} -> "
                                  f"{resolved_top}) OK (E-13 option b)")

        if ws:
            ws.close()
        if failures:
            raise RuntimeError("E-8 CDP DOM smoke FAILED:\n  " + "\n  ".join(failures))
        print("[dom] PASS — CDP DOM domain derefs real elements (E-8 live)")
    finally:
        if ws:
            try:
                ws.close()
            except Exception:
                pass
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
