#!/usr/bin/env python3
# R-10 verification: fusion-gateway cross-node browser-session scheduling consumes
# the fusion-browser {type:"capacity"} UDS plane. Live proof:
#   1. Start 2 fusion-browser release binaries, distinct sockets + tokens + node ids.
#   2. Start fusion-gateway, browser.enabled, static-seed the 2 nodes.
#   3. Poll GET /v1/browser/nodes (admin) — gateway capacity-poll worker has
#      queried each node's {type:"capacity} and reports 2 live nodes w/ distinct
#      node_id + free_memory_mb.
#   4. POST /v1/browser/sessions x3 — scheduler pins each to a node (round-robin
#      by headroom); responses carry distinct node pins.
#   5. Execute a screenshot on one session → forwards to the pinned node, returns
#      PNG data (proves create+execute proxy, not just capacity query).
#   6. Close sessions + tear down.
# Verifies dahai80/fusion-gateway PR #131 (issue #130, R-10) against fusion-browser
# main 1ccc31b. Process data cleaned in finally. Final output = this stdout PASS/FAIL
# + scripts/gateway-r10-report.json.
import base64
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time

GATEWAY_DIR = os.path.expanduser("~/fusion/fusion-gateway")
GATEWAY_BIN = os.path.join(GATEWAY_DIR, "gateway")
BROWSER_BIN = os.path.expanduser("~/fusion/fusion-browser/.build/release/fusion-browser")
OUT_REPORT = os.path.expanduser("~/fusion/fusion-browser/scripts/gateway-r10-report.json")
GATEWAY_PORT = 11499  # avoid clashing with live :11432
GATEWAY_ADMIN_USER = "admin"
GATEWAY_ADMIN_PASS = "verify-r10-smoke-pass-unique-9k2"

procs = []
tmpdir = tempfile.mkdtemp(prefix="fb-gw-r10-")
report = {"phase": "init", "ok": False}


def log(msg):
    print(f"[r10] {msg}", flush=True)


def cleanup():
    global procs
    for p in procs:
        if p.poll() is None:
            try:
                p.send_signal(signal.SIGTERM)
                p.wait(timeout=5)
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass
    procs = []
    import shutil
    try:
        shutil.rmtree(tmpdir, ignore_errors=True)
    except Exception:
        pass


def start_browser_node(idx, sock, tok):
    cfgdir = os.path.join(tmpdir, f"node{idx}")
    os.makedirs(cfgdir, exist_ok=True)
    cfg = {
        "socketPath": sock,
        "authToken": tok,
        "cdpEnabled": False,
        "logLevel": "info",
        "tokenCapabilities": ["all", "metrics"],
    }
    cfgpath = os.path.join(cfgdir, "config.json")
    with open(cfgpath, "w") as f:
        json.dump(cfg, f)
    env = dict(os.environ)
    # FUSION_BROWSER_CONFIG env override — NSHomeDirectory() ignores HOME on macOS.
    env["FUSION_BROWSER_CONFIG"] = cfgpath
    p = subprocess.Popen(
        [BROWSER_BIN], env=env,
        stdout=open(os.path.join(cfgdir, "engine.log"), "w"),
        stderr=subprocess.STDOUT,
    )
    procs.append(p)
    # wait for socket
    for _ in range(100):
        if os.path.exists(sock):
            return p
        if p.poll() is not None:
            log(f"node{idx} engine died early; tail log:")
            try:
                with open(os.path.join(cfgdir, "engine.log")) as f:
                    print(f.read()[-2000:])
            except Exception:
                pass
            return None
        time.sleep(0.1)
    log(f"node{idx} socket never appeared: {sock}")
    return None


def uds_query(sock, tok, req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock)
    # auth frame
    auth = json.dumps({"type": "auth", "token": tok}).encode()
    s.sendall(len(auth).to_bytes(4, "big") + auth)
    rlen = int.from_bytes(s.recv(4), "big")
    _ack = s.recv(rlen)
    # request
    b = json.dumps(req).encode()
    s.sendall(len(b).to_bytes(4, "big") + b)
    rlen = int.from_bytes(s.recv(4), "big")
    resp = b""
    while len(resp) < rlen:
        chunk = s.recv(rlen - len(resp))
        if not chunk:
            break
        resp += chunk
    s.close()
    return json.loads(resp)


def uds_query_noauth(sock, req):
    # Gateway-style dial: send the request frame with NO auth handshake.
    # A real fusion-browser node returns {type:error, code:auth_denied}. This
    # is the defect probe — proves the gateway's no-auth poll path is rejected
    # by a real node (the fakenode test does not model auth, so it missed this).
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock)
    b = json.dumps(req).encode()
    s.sendall(len(b).to_bytes(4, "big") + b)
    rlen = int.from_bytes(s.recv(4), "big")
    resp = b""
    while len(resp) < rlen:
        chunk = s.recv(rlen - len(resp))
        if not chunk:
            break
        resp += chunk
    s.close()
    return json.loads(resp)


def start_gateway(nodes):
    import bcrypt
    pw_hash = bcrypt.hashpw(GATEWAY_ADMIN_PASS.encode(), bcrypt.gensalt()).decode()
    cfg = {
        "server": {"port": GATEWAY_PORT},
        "auth": {"enabled": False},
        "admin": {"enabled": True, "jwt_secret": "r10-verify-jwt-secret-32chars-min-9k2a", "users": {GATEWAY_ADMIN_USER: pw_hash}},
        "browser": {
            "enabled": True,
            "poll_interval": "1s",
            "failure_threshold": 2,
            "recovery_interval": "2s",
            "global_max_sessions": 0,
            "min_free_mb_per_session": 0,
            "frame_max_bytes": 8388608,
            "dial_timeout": "2s",
            "frame_timeout": "10s",
            "nodes": [{"id": f"node-{i}", "socket_path": sp} for i, sp in enumerate(nodes, 1)],
        },
    }
    cfgpath = os.path.join(tmpdir, "gateway.yaml")
    with open(cfgpath, "w") as f:
        json.dump(cfg, f)  # gateway config loader takes JSON too? yaml expected — use yaml
    # gateway uses yaml; write yaml
    try:
        import yaml
        with open(cfgpath, "w") as f:
            yaml.dump(cfg, f)
    except ImportError:
        # fallback: minimal yaml by hand for the keys we use
        with open(cfgpath, "w") as f:
            f.write(json.dumps(cfg))  # last resort
    p = subprocess.Popen(
        [GATEWAY_BIN, "-config", cfgpath],
        cwd=GATEWAY_DIR,
        stdout=open(os.path.join(tmpdir, "gateway.log"), "w"),
        stderr=subprocess.STDOUT,
    )
    procs.append(p)
    # wait for port
    for _ in range(100):
        if p.poll() is not None:
            log("gateway died early; tail log:")
            try:
                with open(os.path.join(tmpdir, "gateway.log")) as f:
                    print(f.read()[-3000:])
            except Exception:
                pass
            return None
        try:
            with socket.create_connection(("127.0.0.1", GATEWAY_PORT), timeout=0.5):
                return p
        except Exception:
            time.sleep(0.2)
    log("gateway port never opened")
    return None


def gw_login():
    import urllib.request
    body = json.dumps({"username": GATEWAY_ADMIN_USER, "password": GATEWAY_ADMIN_PASS}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{GATEWAY_PORT}/admin/api/login", data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            d = json.loads(r.read())
            return d.get("token")
    except Exception as e:
        log(f"admin login failed: {e}")
        return None


def gw_get(path, token=None):
    import urllib.request
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"http://127.0.0.1:{GATEWAY_PORT}{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status, json.loads(r.read())


def gw_post(path, body, token=None):
    import urllib.request, urllib.error
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"http://127.0.0.1:{GATEWAY_PORT}{path}", data=json.dumps(body).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            errbody = e.read().decode()
        except Exception:
            errbody = ""
        raise RuntimeError(f"POST {path} -> {e.code}: {errbody}") from e


def main():
    try:
        # 1. two browser nodes
        socks = [os.path.join(tmpdir, f"node{i}.sock") for i in (1, 2)]
        toks = ["tok-node-1", "tok-node-2"]
        cap1 = cap2 = None
        for i, (sp, tk) in enumerate(zip(socks, toks), 1):
            p = start_browser_node(i, sp, tk)
            if p is None:
                log(f"FAIL: browser node{i} did not start")
                report["phase"] = f"node{i}_start"
                return False
        log("2 browser nodes up; querying each {type:capacity} directly to record node_id")
        cap1 = uds_query(socks[0], toks[0], {"type": "capacity"})
        cap2 = uds_query(socks[1], toks[1], {"type": "capacity"})
        report["direct_capacity"] = [cap1, cap2]
        if cap1.get("type") != "capacity" or cap2.get("type") != "capacity":
            log(f"FAIL: direct capacity query wrong shape: {cap1} {cap2}")
            report["phase"] = "direct_capacity"
            return False
        # defect probe: no-auth poll (exactly what the gateway does) must be
        # auth_denied on a real node. Records the defect signature up-front so a
        # 503 later is attributable, not a mystery.
        noauth = uds_query_noauth(socks[0], {"type": "capacity"})
        noauth_code = (noauth.get("payload") or noauth).get("code", "")
        report["noauth_probe"] = {"type": noauth.get("type"), "code": noauth_code}
        log(f"no-auth probe -> type={noauth.get('type')} code={noauth_code}")
        if noauth.get("type") == "error" and noauth_code == "auth_denied":
            report["noauth_rejected"] = True
            log("no-auth probe rejected with auth_denied (expected for a real node)")
        else:
            report["noauth_rejected"] = False
            log(f"WARN: no-auth probe NOT rejected ({noauth}) — node auth may be off")
        nid1 = (cap1.get("payload") or {}).get("node_id") or cap1.get("node_id")
        nid2 = (cap2.get("payload") or {}).get("node_id") or cap2.get("node_id")
        if not nid1 or not nid2 or nid1 == nid2:
            log(f"FAIL: node ids missing or collide: {nid1} {nid2}")
            report["phase"] = "node_id"
            return False
        log(f"node ids distinct: {nid1[:8]}.. {nid2[:8]}..")

        # 2. gateway
        g = start_gateway(socks)
        if g is None:
            report["phase"] = "gateway_start"
            return False
        log("gateway up; waiting for capacity-poll worker to register both nodes")
        time.sleep(3)  # poll_interval=1s + jitter

        # 3. (admin /v1/browser/nodes is admin-gated even with auth.enabled=false;
        #    the scheduler node-pin in each create response is the live proof of
        #    registration + placement, so skip the admin map and read node_id from
        #    creates.)
        token = gw_login()
        report["admin_login"] = bool(token)

        # 4. create sessions through gateway — scheduler picks a node, returns node_id
        created = []
        pins = []
        for i in range(3):
            try:
                st, resp = gw_post("/v1/browser/sessions", {"mode": "headless"})
            except Exception as e:
                log(f"FAIL: create#{i} -> {e}")
                glog = ""
                try:
                    with open(os.path.join(tmpdir, "gateway.log")) as f:
                        glog = f.read()
                    log("gateway log tail:\n" + glog[-4000:])
                except Exception:
                    pass
                # Classify: if the no-auth probe was rejected (real node) AND the
                # create failed, the root cause is the gateway's missing auth
                # handshake — a known defect (fusion-gateway#132), NOT a
                # fusion-browser regression. Record the specific verdict.
                if report.get("noauth_rejected") and ("auth_denied" in glog or "auth_denied" in str(e)):
                    report["verdict"] = ("gateway_auth_handshake_defect",
                                         "gateway NodeClient sends no UDS auth frame; "
                                         "real node returns auth_denied -> poll marks node "
                                         "dead -> 503. fusion-gateway#132.")
                    report["phase"] = "gateway_auth_handshake_defect"
                    report["ok"] = False
                    log("VERDICT: gateway_auth_handshake_defect (fusion-gateway#132) — "
                        "gateway cannot poll a real fusion-browser node. "
                        "fusion-browser side (capacity contract) is correct; the fix is "
                        "gateway-side.")
                    return False
                report["phase"] = f"create_{i}"
                return False
            report[f"create_{i}"] = {"status": st, "resp": resp}
            sid = resp.get("session_id") or (resp.get("data", {}) or {}).get("session_id") or resp.get("id")
            nid = resp.get("node_id") or (resp.get("data", {}) or {}).get("node_id")
            if not sid:
                log(f"FAIL: create#{i} no session id: {resp}")
                report["phase"] = f"create_{i}"
                return False
            if not nid:
                log(f"FAIL: create#{i} no node_id pin in response: {resp}")
                report["phase"] = f"create_{i}_no_pin"
                return False
            created.append(sid)
            pins.append(nid)
            log(f"create#{i} -> session {sid[:8]}.. pinned to node {nid[:8]}..")
        report["created_sessions"] = created
        report["node_pins"] = pins
        distinct_pins = set(pins)
        if len(distinct_pins) < 2:
            log(f"FAIL: scheduler pinned all 3 sessions to ONE node ({pins}); capacity-based distribution not working")
            report["phase"] = "pin_distribution"
            return False
        log(f"scheduler distributed 3 sessions across {len(distinct_pins)} nodes: {[p[:8] for p in distinct_pins]}")
        # verify the pinned node ids match the 2 browser nodes we started
        for p in pins:
            if p not in (nid1, nid2):
                log(f"FAIL: pinned node_id {p[:8]}.. not one of the 2 live browser nodes ({nid1[:8]},{nid2[:8]})")
                report["phase"] = "pin_node_mismatch"
                return False
        log("all pins match a live browser node_id — scheduler consumed the real capacity plane")

        # 5. execute a screenshot on session 0 — proves proxy forwards to pinned node
        st, act = gw_post(f"/v1/browser/sessions/{created[0]}/actions", {"action": "screenshot"})
        report["execute_screenshot"] = {"status": st, "keys": list(act.keys()) if isinstance(act, dict) else type(act).__name__}
        has_png = False
        if isinstance(act, dict):
            sd = act.get("screenshot_data") or act.get("data") or (act.get("payload", {}) or {}).get("screenshot_data")
            if sd:
                try:
                    raw = base64.b64decode(sd)
                    has_png = raw[:8] == b"\x89PNG\r\n\x1a\n"
                except Exception:
                    pass
        if not has_png:
            log(f"FAIL: screenshot execute did not return PNG: {str(act)[:300]}")
            report["phase"] = "execute_screenshot"
            return False
        log("screenshot via gateway proxy -> valid PNG")

        # 6. close
        for sid in created:
            try:
                import urllib.request
                req = urllib.request.Request(f"http://127.0.0.1:{GATEWAY_PORT}/v1/browser/sessions/{sid}", method="DELETE")
                urllib.request.urlopen(req, timeout=10)
            except Exception:
                pass
        log("sessions closed")

        report["ok"] = True
        report["phase"] = "done"
        log("PASS: gateway consumed fusion-browser capacity plane, scheduled 3 sessions, proxied execute")
        return True
    except Exception as e:
        import traceback
        log(f"EXCEPTION: {e}")
        traceback.print_exc()
        report["phase"] = "exception"
        report["error"] = str(e)
        return False
    finally:
        cleanup()
        try:
            with open(OUT_REPORT, "w") as f:
                json.dump(report, f, indent=2, default=str)
        except Exception:
            pass


if __name__ == "__main__":
    ok = main()
    sys.exit(0 if ok else 1)
