#!/usr/bin/env python3
"""Issue #25: end-to-end managed-backend harness for fusion-cowork.

Proves the whole fusion-browser side of the cowork integration against the RELEASE
binary, over the real UDS wire:

  1. create a session with a persistent profileId (per-workflow-run login state)
  2. import cookies from a browser profile (temp Firefox fixture, real reader)
  3. navigate to a local server and assert the imported login state is live
  4. subscribe a screenshot stream on a SECOND connection and assert a frame arrives
  5. close, restart the engine, re-create the same profileId, assert the login
     survived the restart (persistent WKWebsiteDataStore)
  6. delete_profile and assert the registry entry + WebKit store are gone

Writes scripts/cowork-smoke-report.json ({"ok": bool, "phases": {...}}) and exits
non-zero on failure. Process data: temp dir removed, profile deleted, engine stopped.
"""

import base64
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.path.join(ROOT, ".build", "release", "fusion-browser")
REPORT = os.path.join(HERE, "cowork-smoke-report.json")
sys.path.insert(0, os.path.join(ROOT, "client", "python"))

from fusion_browser_client import FusionBrowserClient, FusionBrowserStream, FBError  # noqa: E402

TOKEN = "cowork-smoke-token"


class LocalSite(BaseHTTPRequestHandler):
    """Local site: '/' has a button, '/check' reports whether the session cookie arrived."""

    def do_GET(self):
        cookie = self.headers.get("Cookie", "")
        if self.path.startswith("/check"):
            body = "logged_in" if "session=ok" in cookie else "anonymous"
            html = "<html><title>check</title><body><div id=r>%s</div></body></html>" % body
        else:
            html = ("<html><title>Home</title><body><h1>Home</h1>"
                    "<a href='/check'>check</a><button>Go</button></body></html>")
        data = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        pass


def make_firefox_profile(profiles_dir):
    """A real Firefox-profile layout holding one persistent cookie for localhost."""
    profile = os.path.join(profiles_dir, "cowork.default-release")
    os.makedirs(profile, exist_ok=True)
    db = os.path.join(profile, "cookies.sqlite")
    con = sqlite3.connect(db)
    con.execute("""CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT,
                   host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER,
                   sameSite INTEGER)""")
    expiry = int(time.time()) + 86400
    con.execute("INSERT INTO moz_cookies (name,value,host,path,expiry,isSecure,isHttpOnly,sameSite)"
                " VALUES ('session','ok','localhost','/',?,0,0,1)", (expiry,))
    con.commit()
    con.close()
    return profile


def write_config(path, socket_path, origin, firefox_dir, tmp):
    cfg = {
        "socketPath": socket_path,
        "authToken": TOKEN,
        # 'all' grants persistentProfiles + importCookies + evaluate + screenshot.
        "tokenCapabilities": ["all"],
        "tokenSystemCaller": False,
        "allowedOrigins": [origin],
        "logLevel": "info",
        "cookieImport": {
            "chromeUserDataDir": os.path.join(tmp, "no-chrome"),
            "edgeUserDataDir": os.path.join(tmp, "no-edge"),
            "firefoxProfilesDir": firefox_dir,
        },
    }
    with open(path, "w") as f:
        json.dump(cfg, f)


def start_engine(config_path, socket_path, log_path):
    env = dict(os.environ, FUSION_BROWSER_CONFIG=config_path)
    logf = open(log_path, "ab")
    proc = subprocess.Popen([BIN], env=env, stdout=logf, stderr=logf)
    proc.logf = logf
    for _ in range(100):
        if proc.poll() is not None:
            raise RuntimeError("engine exited early rc=%s" % proc.returncode)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(socket_path)
            s.close()
            return proc
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("engine socket never came up: %s" % socket_path)


def stop_engine(proc):
    if proc is None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
    logf = getattr(proc, "logf", None)
    if logf is not None:
        logf.close()


def body_text(c, sid):
    st = c.evaluate(sid, "document.body ? document.body.innerText : ''")
    raw = st.evaluateResult
    if raw is None:
        return ""
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return str(raw)


def main():
    report = {"ok": False, "phases": {}}
    tmp = tempfile.mkdtemp(prefix="fb-cowork-")
    socket_path = os.path.join(tmp, "engine.sock")
    config_path = os.path.join(tmp, "config.json")
    log_path = os.path.join(tmp, "engine.log")
    firefox_dir = os.path.join(tmp, "firefox")
    profile_id = "cowork-" + uuid.uuid4().hex[:12]
    proc = None
    site = None
    try:
        if not os.path.exists(BIN):
            raise RuntimeError("release binary missing: %s (run swift build -c release)" % BIN)

        make_firefox_profile(firefox_dir)

        site = ThreadingHTTPServer(("localhost", 0), LocalSite)
        port = site.server_address[1]
        origin = "http://localhost:%d" % port
        threading.Thread(target=site.serve_forever, daemon=True).start()
        report["phases"]["site"] = {"origin": origin}

        write_config(config_path, socket_path, origin, firefox_dir, tmp)
        proc = start_engine(config_path, socket_path, log_path)

        c = FusionBrowserClient(socket_path=socket_path, token=TOKEN, timeout=30)
        sid = c.create_session(profile_id=profile_id)
        report["phases"]["create"] = {"session_id": sid, "profile_id": profile_id}

        imported = c.import_cookies(sid, "firefox")
        report["phases"]["import_cookies"] = imported
        if imported.get("imported", 0) < 1:
            raise RuntimeError("no cookies imported: %s" % imported)

        c.navigate(sid, origin + "/check")
        time.sleep(0.5)
        state = body_text(c, sid)
        jar = c.evaluate(sid, "document.cookie").evaluateResult
        report["phases"]["login_after_import"] = {"body": state, "document_cookie": jar}
        if state != "logged_in":
            raise RuntimeError("imported cookie did not reach the site: body=%r" % state)

        # Screenshot stream on its OWN connection (the command connection stays usable).
        frames = []
        stream = FusionBrowserStream(sid, socket_path=socket_path, token=TOKEN)
        done = threading.Event()

        def consume():
            try:
                for frame in stream.frames():
                    frames.append(frame)
                    done.set()
            except FBError as e:
                report["phases"].setdefault("stream_error", str(e))
            finally:
                done.set()

        threading.Thread(target=consume, daemon=True).start()
        c.navigate(sid, origin + "/")
        time.sleep(0.5)
        st = c.navigate(sid, origin + "/")
        node_ids = [n.nodeId for n in st.interactiveNodes if n.role.lower() == "button"]
        if node_ids:
            time.sleep(0.3)  # outside the hub's 200ms throttle window
            c.click(sid, node_ids[0])
        if not done.wait(timeout=10):
            raise RuntimeError("no screenshot_frame within 10s")
        frame = frames[0]
        png = base64.b64decode(frame.get("png", ""))
        report["phases"]["stream"] = {"frames": len(frames), "seq": frame.get("seq"),
                                      "png_bytes": len(png), "url": frame.get("url")}
        if len(png) < 100:
            raise RuntimeError("stream frame png too small: %d bytes" % len(png))

        c.close_session(sid)
        time.sleep(2.0)  # let WebKit flush the persistent store before the restart
        stream.close()
        stop_engine(proc)
        proc = None

        # Persistence: same profileId -> same WKWebsiteDataStore -> login still there.
        proc = start_engine(config_path, socket_path, log_path)
        c2 = FusionBrowserClient(socket_path=socket_path, token=TOKEN, timeout=30)
        sid2 = c2.create_session(profile_id=profile_id)
        c2.navigate(sid2, origin + "/check")
        time.sleep(0.5)
        persisted = body_text(c2, sid2)
        report["phases"]["login_after_restart"] = {"body": persisted}
        if persisted != "logged_in":
            raise RuntimeError("login state did not survive the engine restart: %r" % persisted)

        deleted = c2.delete_profile(profile_id)
        report["phases"]["delete_profile"] = {"deleted": deleted}
        if deleted is not True:
            raise RuntimeError("delete_profile reported no profile")
        c2.close_session(sid2)
        report["ok"] = True
    except Exception as e:  # noqa: BLE001 - harness reports, never hides
        report["error"] = "%s: %s" % (type(e).__name__, e)
        try:
            with open(log_path) as f:
                report["engine_log_tail"] = f.read().splitlines()[-40:]
        except OSError:
            pass
        # Best-effort registry cleanup so a failed run does not leave a profile entry.
        try:
            if proc is None:
                proc = start_engine(config_path, socket_path, log_path)
            FusionBrowserClient(socket_path=socket_path, token=TOKEN, timeout=15).delete_profile(profile_id)
        except Exception:
            pass
    finally:
        stop_engine(proc)
        if site is not None:
            site.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)
        with open(REPORT, "w") as f:
            json.dump(report, f, indent=2, sort_keys=True)

    if report["ok"]:
        print("[cowork-smoke] PASS: profile + cookie import + login + stream + restart persistence")
        print("[cowork-smoke] report: %s" % REPORT)
        sys.exit(0)
    print("[cowork-smoke] FAIL: %s" % report.get("error", "unknown"))
    print("[cowork-smoke] report: %s" % REPORT)
    sys.exit(1)


if __name__ == "__main__":
    main()
