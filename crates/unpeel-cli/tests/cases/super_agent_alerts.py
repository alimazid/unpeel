"""Super Agent Worker alerts and watchdog (fork-only).

A fake platform adapter registers `notification.deliver` over the Host's
local socket, so every notification the Host sends is observed. The Router
(marked directly in this private home's app-state) starts a Worker with a
task. When the Worker finishes, its reply reaches the Router as a pasted
`finished` notice and the adapter hears nothing about the Worker, while the
Router's own finished turn still notifies the user. With
`UNPEEL_SUPERVISOR_SECONDS=1` and a 5-"minute" stall time, a Worker that goes
busy and silent is reported `stalled`; killing it while it is busy reports
`exited_unexpectedly`.
"""

import http.server
import json
import os
import shlex
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402
from host_launch_conformance import LocalHostClient  # noqa: E402

HEADER = "[unpeel inbox for id:"
TOKEN = "pty-fake-adapter-token-0123456789abcdef"
WORKER_REPLY = "WORKER-REPLY login form fixed"

FIXTURE = '''
import base64, os, select, time, tty
tty.setraw(0)
log = os.path.join(os.getcwd(), "stdin.log")
open(os.path.join(os.getcwd(), "agent.pid"), "w").write(str(os.getpid()))
def report(pairs):
    os.write(1, b"\\x1b]7501;" + pairs.encode() + b":app=alerts\\x1b\\\\")
def msg(text):
    return base64.b64encode(text.encode()).decode()
os.write(1, b"\\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\\r\\n> ")
report("state=idle")
pasted = False
phase = None
while True:
    wait = None if phase is None else max(0.0, phase[1] - time.time())
    ready, _, _ = select.select([0], [], [], wait)
    if not ready:
        if phase[0] == "working":
            report("state=done:msg=" + msg(REPLY))
            phase = ("done", time.time() + 1.5)
        else:
            report("state=idle")
            phase = None
        continue
    data = os.read(0, 65536)
    if not data or data == b"q":
        break
    with open(log, "ab") as out:
        out.write(data)
    if data == b"w":
        report("state=working")
        phase = None
        continue
    pasted = pasted or b"\\x1b[200~" in data
    if pasted and b"\\r" in data:
        pasted = False
        report("state=working")
        phase = ("working", time.time() + WORK_SECONDS)
'''


def write_fixture(path, reply, work_seconds):
    """A 7501 program with bracketed paste, logging stdin to `stdin.log` in
    its working directory: a submitted paste is a turn (working, then done
    with `reply`, then idle); `w` goes working and silent; `q` quits."""
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\nREPLY = {reply!r}\nWORK_SECONDS = {work_seconds!r}\n"
                     + FIXTURE)
    os.chmod(path, 0o755)


class FakeAdapter:
    """A platform adapter that records every `notification.deliver` and
    answers as a Mac that is not showing the Session."""

    def __init__(self):
        self.calls = []
        adapter = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length)
                authorized = self.headers.get("Authorization") == f"Bearer {TOKEN}"
                if authorized:
                    try:
                        adapter.calls.append(json.loads(body))
                    except ValueError:
                        pass
                reply = json.dumps({"macObserved": False}).encode()
                self.send_response(200 if authorized else 401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(reply)))
                self.end_headers()
                self.wfile.write(reply)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.client = None

    def register(self, socket_path):
        self.client = LocalHostClient(socket_path)
        return self.client.call(1, "POST", "/_unpeel/platform-adapter", body={
            "action": "register",
            "registration": {
                "version": 1,
                "instanceID": "pty-fake-adapter",
                "callbackPort": self.server.server_address[1],
                "callbackToken": TOKEN,
                "capabilities": ["notification.deliver"],
            },
        })

    def notified(self, session_id):
        return [call["request"] for call in self.calls
                if call.get("operation") == "notification.deliver"
                and call.get("request", {}).get("sessionID") == session_id]

    def close(self):
        if self.client:
            self.client.close()
        self.server.shutdown()
        self.server.server_close()


def body(case):
    home = case.home
    folders = {name: home.path(name) for name in ("p", "q")}
    for folder in folders.values():
        os.makedirs(folder)
    home.project("p", "Router's", folders["p"])
    home.project("q", "Work", folders["q"])
    environment = {"HOME": home.root, "SHELL": "/bin/bash", "UNPEEL_SUPERVISOR_SECONDS": "1"}
    os.makedirs(home.path("bin"), exist_ok=True)
    write_fixture(home.path("bin", "router-agent"), "Router turn done", 1.5)
    write_fixture(home.path("bin", "worker-agent"), WORKER_REPLY, 2.5)
    home.preset(label="router", command=shlex.quote(home.path("bin", "router-agent")),
                preset_id="router")
    home.preset(label="worker", command=shlex.quote(home.path("bin", "worker-agent")),
                preset_id="worker")
    state = home.state()
    state["supervisor_stall_minutes"] = 5  # seconds, under UNPEEL_SUPERVISOR_SECONDS
    home.write_state(state)

    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=25)), service.log()):
        return
    adapter = case.track(FakeAdapter())
    status, registered = adapter.register(read_json(home.path("serve.json")).get("localSocket", ""))
    if not case.check("the fake adapter registers notification.deliver",
                      status == 200 and registered.get("ok") is True, f"{status} {registered}"):
        return

    started = run_cli(home, ["new", "--preset", "router", "--project", "p", "--cwd", folders["p"]],
                      env=environment)
    ids = [w for w in started.stdout.split() if len(w) == 36 and w.count("-") == 4]
    router = ids[0] if ids else ""
    if not case.check("the Router starts", bool(router) and wait_running(home, router),
                      started.stdout + started.stderr):
        return
    state = home.state()
    state["super_agent"] = {"session_id": router, "since": int(time.time() * 1000)}
    home.write_state(state)

    def mcp(session_id, action, args):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id)
        done = subprocess.run([BINARY, "mcp", "sessions", action, "--json", json.dumps(args)],
                              capture_output=True, text=True, timeout=60, env=env, cwd=CRATES)
        try:
            return json.loads(done.stdout), done
        except ValueError:
            return {}, done

    def log_of(project):
        try:
            with open(os.path.join(folders[project], "stdin.log"), "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def notice_pasted(worker, event):
        text = log_of("p")
        return f"kind: {'lifecycle' if event == 'finished' else 'watchdog'}" in text \
            and f"about: id:{worker}, event: {event}" in text

    workers = []
    try:
        if not fixture_started(case, service, home.path("app-sessions", router)):
            return
        created, done = mcp(router, "create", {
            "preset": "worker", "project_id": "q", "label": "fix login",
            "text": "Please fix the login form."})
        worker = created.get("session_id", "")
        workers.append(worker)
        if not case.check("the Router starts a Worker with its task",
                          bool(worker) and created.get("worker") is True,
                          (done.stdout + done.stderr)[:400]):
            return
        if not fixture_started(case, service, home.path("app-sessions", worker)):
            return

        # 1. The Worker finishes: its reply is pasted into the Router, and the
        # adapter never hears about the Worker.
        case.check("the task is pasted into the Worker",
                   bool(service.wait_for(lambda: "Please fix the login form." in log_of("q"),
                                         timeout=30)), log_of("q")[-300:])
        case.check("the Worker's finish reaches the Router as a pasted notice with its reply",
                   bool(service.wait_for(lambda: notice_pasted(worker, "finished")
                                         and WORKER_REPLY in log_of("p"), timeout=40)),
                   log_of("p")[-800:])
        text = log_of("p")
        case.check("the notice is the Host's, inside an Inbox batch",
                   f"{HEADER}{router}" in text and "[notice from id:host" in text
                   and "\"fix login\" finished." in text, text[-600:])
        case.check("the Router's own finished turn still notifies the user",
                   bool(service.wait_for(lambda: any(call.get("kind") == "done"
                                                     for call in adapter.notified(router)),
                                         timeout=30)), json.dumps(adapter.calls)[-600:])
        case.check("no notification was requested for the Worker",
                   adapter.notified(worker) == [], json.dumps(adapter.notified(worker)))
        activity = read_json(home.path("activity-state.json")).get("sessions", {})
        case.check("the finished Worker is not left unread",
                   activity.get(worker, {}).get("unread") is not True, str(activity.get(worker)))

        # 2. Busy and silent past the stall time: a `stalled` notice.
        control(home, worker, "w")
        case.check("a silent busy Worker is reported stalled",
                   bool(service.wait_for(lambda: notice_pasted(worker, "stalled"), timeout=45)),
                   log_of("p")[-800:])

        # 3. Killed while busy: an `exited_unexpectedly` notice.
        manifest = read_json(home.path("app-sessions", worker, "manifest.json"))
        with open(os.path.join(folders["q"], "agent.pid")) as handle:
            agent_pid = int(handle.read().strip())
        for pid in (manifest.get("pid"), agent_pid):
            if pid:
                try:
                    os.kill(int(pid), signal.SIGKILL)
                except OSError:
                    pass
        case.check("the killed Worker's session exits",
                   bool(service.wait_for(lambda: read_json(home.path(
                       "app-sessions", worker, "manifest.json")).get("state") == "exited",
                       timeout=20)))
        case.check("killing a busy Worker is reported to the Router",
                   bool(service.wait_for(lambda: notice_pasted(worker, "exited_unexpectedly"),
                                         timeout=45)), log_of("p")[-800:])
        case.check("still no notification was requested for the Worker",
                   adapter.notified(worker) == [], json.dumps(adapter.notified(worker)))
    finally:
        for session_id in [router, *workers]:
            if session_id and os.path.isdir(home.path("app-sessions", session_id)):
                try:
                    control(home, session_id, "q")
                except OSError:
                    pass
                run_cli(home, ["rm", session_id], env=environment, timeout=45)


if __name__ == "__main__":
    run("super_agent_alerts", body)
