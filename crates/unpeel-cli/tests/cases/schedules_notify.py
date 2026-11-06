"""Notifications for Scheduled Task Runs, end to end through `unpeel serve`.

The Host decides when a Run is worth a notification; the Mac app's platform
adapter (`notification.deliver`) only delivers it. A stand-in adapter
registers over the worker's owner socket exactly as the app's bridge does
and records every callback. Covered:

* a Run Session's finished turn (an OSC 7501 agent) carries its task's
  "Notify when done" (`runNotifyWhenDone`) and the reply snippet, once: the
  Run's own `done` adds no second notice;
* its question is the Session's own needs-input notice, once;
* an agent that shows no working signal after its instructions needs you:
  a Run notice, and the Run Session is unread;
* an agent only its screen follows (no integration, no OSC 7501) is done
  with the reply its screen shows, and since the screen tier sends no
  Finished edge, the Run's done notice comes once, by the task's setting;
* a script Run that finished (no Finished edge exists for it) notifies with
  the task's setting either way, and is unread; a bare Agent Preset Run
  likewise;
* a failed Run and one that could not launch at all (no Session) notify
  with the task's name and the reason, and leave nothing unread;
* with no adapter (the app quit) a finished script Run is still unread.
"""

import base64
import datetime
import fcntl
import json
import os
import socket
import sys
import threading
import time
import zoneinfo
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402
from hook_cancellation import control, read_json  # noqa: E402

ZONE = "America/New_York"
QUIT = "QUIT-FAKE-AGENT"
WORKING_TIMEOUT_MS = 3_000
CALLBACK_TOKEN = "fake-adapter-token-0123456789abcdef"

FAKE_AGENT = r'''
import base64, os, termios, time, tty
KIND = %(kind)r
QUIT = %(quit)r
tty.setraw(0, termios.TCSANOW)
def report(state, msg=None):
    pairs = "state=" + state + ":app=fake"
    if msg:
        pairs += ":msg=" + base64.b64encode(msg.encode()).decode()
    os.write(1, ("\x1b]7501;" + pairs + "\x1b\\").encode())
def screen(text):
    os.write(1, ("\x1b[2J\x1b[H" + text.replace("\n", "\r\n")).encode())
os.write(1, b"\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\r\n")
time.sleep(1.5)
if KIND == "screen":
    screen("Claude Code\n\n✻ Welcome back\n────\n❯\n────\n  ? for shortcuts")
else:
    report("idle")
def submit(text):
    if KIND == "screen":
        asked = text.decode("utf-8", "replace")
        screen("Claude Code\n\n❯ " + asked + "\n\n✻ Filing… (3s · esc to interrupt)\n────\n❯\n────")
        time.sleep(2)
        screen("Claude Code\n\n❯ " + asked + "\n\n⏺ Notes filed.\n\n────\n❯\n────\n  ? for shortcuts")
    elif KIND == "program":
        report("working", "Reading the calendar")
        time.sleep(2)
        report("done", "Briefing sent to the team")
    elif KIND == "question":
        report("working", "Reading the calendar")
        time.sleep(1)
        report("blocked", "Send it to the whole team?")
pending, composer, pasting = b"", b"", False
while True:
    data = os.read(0, 4096)
    if not data or data == QUIT.encode():
        break
    pending += data
    while pending:
        if pasting:
            end = pending.find(b"\x1b[201~")
            if end < 0:
                composer, pending = composer + pending, b""
                break
            composer, pending, pasting = composer + pending[:end], pending[end + 6:], False
            continue
        start, enter = pending.find(b"\x1b[200~"), pending.find(b"\r")
        if start >= 0 and (enter < 0 or start < enter):
            composer, pending, pasting = composer + pending[:start], pending[start + 6:], True
            continue
        if enter < 0:
            composer, pending = composer + pending, b""
            break
        text, composer, pending = composer + pending[:enter], b"", pending[enter + 1:]
        # A second Enter on an empty composer submits nothing, as in a real agent.
        if text.strip():
            submit(text)
'''


class FakeAdapter:
    """Stands in for the Mac app's platform adapter: registers
    `notification.deliver` over the worker's owner socket (`host.sock`,
    `UPL1` frames carrying tunnel requests), keeps the registration alive
    with the bridge's status ping, and records every callback."""

    def __init__(self, socket_path):
        self.calls = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._next_id = 1
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length) if length else b"{}"
                if self.headers.get("Authorization") != f"Bearer {CALLBACK_TOKEN}":
                    self.send_response(401)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                try:
                    outer.calls.append(json.loads(raw))
                except ValueError:
                    outer.calls.append({"invalid": raw.decode("utf-8", "replace")})
                payload = b'{"ok":true,"macObserved":false,"eligible":true}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(socket_path)
        self.registered = self._control({
            "action": "register",
            "registration": {
                "version": 1,
                "instanceID": "fake-app",
                "callbackPort": self.server.server_port,
                "callbackToken": CALLBACK_TOKEN,
                "capabilities": ["notification.deliver"],
            },
        })
        threading.Thread(target=self._keep_alive, daemon=True).start()

    def _recv(self, count):
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise OSError("the worker closed the adapter socket")
            data += chunk
        return data

    def _control(self, body):
        with self._lock:
            request = json.dumps({
                "id": self._next_id,
                "method": "POST",
                "path": "/_unpeel/platform-adapter",
                "query": {},
                "auth": None,
                "contentType": "application/json",
                "bodyB64": base64.b64encode(json.dumps(body).encode()).decode(),
            }).encode()
            self._next_id += 1
            self.sock.sendall(b"UPL1\x01\x00\x00\x00" + len(request).to_bytes(4, "big") + request)
            header = self._recv(12)
            response = json.loads(self._recv(int.from_bytes(header[8:12], "big")))
            answer = base64.b64decode(response.get("bodyB64") or "") or b"{}"
            return response.get("status"), json.loads(answer)

    def _keep_alive(self):
        while not self._stop.wait(2):
            try:
                self._control({"action": "status"})
            except (OSError, ValueError):
                return

    def deliveries(self, **match):
        return [
            call["request"] for call in list(self.calls)
            if call.get("operation") == "notification.deliver"
            and all(call["request"].get(key) == value for key, value in match.items())
        ]

    def close(self):
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        self.server.shutdown()
        self.server.server_close()


def cli(home, *args):
    return run_cli(home, list(args), env={"TZ": ZONE}, timeout=45)


def tomorrow():
    later = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) + datetime.timedelta(days=1)
    return later.strftime("%Y-%m-%dT%H:%M")


def write_fake(home, kind):
    folder = home.path("agents", kind)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "claude")
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_AGENT % {"kind": kind, "quit": QUIT})
    os.chmod(path, 0o755)
    return path


def add(case, home, name, preset, *extra):
    added = cli(home, "schedules", "add", name, "--project", "p", "--preset", preset,
                "--once", tomorrow(), *extra)
    task_id = added.stdout.strip()
    case.check(f"{name}: add accepts the task", added.returncode == 0 and task_id.startswith("sch_"),
               added.stderr)
    return task_id


def run_entry(home, task_id, run_id):
    try:
        runs = json.loads(cli(home, "schedules", "history", task_id, "--json").stdout)
    except ValueError:
        return {}
    return next((entry for entry in runs if entry.get("run_id") == run_id), {})


def run_now(case, service, home, name, task_id, statuses):
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    case.check(f"{name}: Run now answers with a Run id",
               started.returncode == 0 and run_id.startswith("run_"), started.stderr)
    found = service.wait_for(
        lambda: run_entry(home, task_id, run_id).get("status") in statuses
        and run_entry(home, task_id, run_id),
        timeout=60,
    )
    return found or run_entry(home, task_id, run_id)


def unread(home, session_id):
    sessions = read_json(home.path("activity-state.json")).get("sessions", {})
    return sessions.get(session_id, {}).get("unread") is True


def finished_entries(home, session_id):
    try:
        with open(home.path("activity-log.jsonl")) as handle:
            entries = [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        return []
    return [entry for entry in entries
            if entry.get("session_id") == session_id and entry.get("kind") == "finished"]


def disable_preset(home, preset_id):
    with open(home.path("app-state.json.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = home.state()
        for preset in state.get("presets", []):
            if preset.get("id") == preset_id:
                preset["enabled"] = False
        with open(home.path("app-state.json"), "w") as handle:
            json.dump(state, handle, indent=2)


def check_quit_app(case, service, home):
    task_id = add(case, home, "Unseen", "ok")
    done = run_now(case, service, home, "Unseen", task_id, ("done", "failed"))
    session_id = done.get("session_id") or ""
    case.check("app quit: a finished script Run is unread",
               done.get("status") == "done"
               and bool(service.wait_for(lambda: unread(home, session_id), timeout=15)),
               json.dumps(done))


def check_script_runs(case, service, home, adapter):
    for name, extra, notify in (("Clean", (), True), ("Quiet", ("--no-notify",), False)):
        task_id = add(case, home, name, "ok", *extra)
        done = run_now(case, service, home, name, task_id, ("done", "failed"))
        session_id = done.get("session_id") or ""
        sent = service.wait_for(lambda: adapter.deliveries(sessionID=session_id), timeout=15) or []
        case.check(f"{name}: a finished script Run notifies once, with its task's setting",
                   [(n.get("kind"), n.get("scheduleID"), n.get("runNotifyWhenDone"),
                     n.get("requiresNotifyWhenDone"), n.get("title"), n.get("body")) for n in sent]
                   == [("done", task_id, notify, True, name, "Finished")], json.dumps(sent))
        case.check(f"{name}: the Run Session is unread",
                   bool(service.wait_for(lambda: unread(home, session_id), timeout=15)))
        case.check(f"{name}: its Session reported no finished turn of its own",
                   not finished_entries(home, session_id),
                   json.dumps(finished_entries(home, session_id)))

    task_id = add(case, home, "Three", "three")
    failed = run_now(case, service, home, "Three", task_id, ("done", "failed"))
    session_id = failed.get("session_id") or ""
    sent = service.wait_for(lambda: adapter.deliveries(sessionID=session_id), timeout=15) or []
    case.check("a failed Run notifies with its task's name and the reason",
               [(n.get("kind"), n.get("scheduleID"), n.get("requiresNotifyWhenDone"),
                 n.get("title"), n.get("body"), "runNotifyWhenDone" in n) for n in sent]
               == [("alert", task_id, False, "Three",
                    "Failed: the command exited with status 3", False)], json.dumps(sent))
    service.read_for(1.5)
    case.check("a failed Run leaves its Session read", not unread(home, session_id))

    task_id = add(case, home, "Doomed", "doomed")
    disable_preset(home, "doomed")
    failed = run_now(case, service, home, "Doomed", task_id, ("done", "failed"))
    sent = service.wait_for(lambda: adapter.deliveries(scheduleID=task_id), timeout=15) or []
    case.check("a Run that could not launch notifies with no Session",
               failed.get("session_id") is None
               and [(n.get("kind"), n.get("sessionID"), n.get("title"), n.get("body"))
                    for n in sent]
               == [("alert", "", "Doomed",
                    "Failed: the preset doomed no longer exists or is disabled")],
               json.dumps(sent))


def check_agent_runs(case, service, home, adapter):
    program = add(case, home, "Briefing", "program", "--instructions", "brief me", "--no-notify")
    done = run_now(case, service, home, "Briefing", program, ("done", "failed", "failed_to_start",
                                                               "needs_you"))
    session_id = done.get("session_id") or ""
    case.check("agent: the Run is done with the agent's reply", done.get("status") == "done"
               and done.get("snippet") == "Briefing sent to the team", json.dumps(done))
    service.read_for(2)
    sent = adapter.deliveries(sessionID=session_id)
    case.check("agent: its finished turn notifies once, with the task's setting and the reply",
               [(n.get("kind"), n.get("scheduleID"), n.get("runNotifyWhenDone"),
                 n.get("requiresNotifyWhenDone"), n.get("body")) for n in sent]
               == [("done", program, False, True, "Briefing sent to the team")], json.dumps(sent))

    question = add(case, home, "Asks", "question", "--instructions", "brief me")
    asked = run_now(case, service, home, "Asks", question, ("needs_you", "done", "failed",
                                                             "failed_to_start"))
    session_id = asked.get("session_id") or ""
    service.read_for(2)
    sent = adapter.deliveries(sessionID=session_id)
    case.check("agent question: the Session's own needs-input notice, once",
               asked.get("status") == "needs_you"
               and [(n.get("kind"), n.get("scheduleID")) for n in sent]
               == [("needs_input", question)], json.dumps(sent))

    silent = add(case, home, "Silent", "silent", "--instructions", "brief me")
    waiting = run_now(case, service, home, "Silent", silent, ("needs_you", "done", "failed",
                                                               "failed_to_start"))
    session_id = waiting.get("session_id") or ""
    sent = service.wait_for(lambda: adapter.deliveries(sessionID=session_id), timeout=15) or []
    case.check("no working signal: the Run needs you, as a Run notice",
               waiting.get("status") == "needs_you"
               and [(n.get("kind"), n.get("scheduleID"), n.get("title"), n.get("body"))
                    for n in sent]
               == [("needs_input", silent, "Silent", "Needs you: the agent showed no working "
                    f"signal within {WORKING_TIMEOUT_MS // 1000} s of its instructions")],
               json.dumps(sent))
    case.check("no working signal: the Run Session is unread",
               bool(service.wait_for(lambda: unread(home, session_id), timeout=15)))

    filed = add(case, home, "Filed", "screen", "--instructions", "file the notes")
    seen = run_now(case, service, home, "Filed", filed, ("done", "failed", "failed_to_start",
                                                          "needs_you"))
    session_id = seen.get("session_id") or ""
    case.check("screen-only agent: the Run is done with the reply its screen shows",
               seen.get("status") == "done" and seen.get("snippet") == "Notes filed.",
               json.dumps(seen))
    sent = service.wait_for(lambda: adapter.deliveries(sessionID=session_id), timeout=15) or []
    service.read_for(2)
    sent = adapter.deliveries(sessionID=session_id)
    case.check("screen-only agent: no Finished edge, so one Run notice with the task's setting",
               [(n.get("kind"), n.get("scheduleID"), n.get("runNotifyWhenDone"),
                 n.get("requiresNotifyWhenDone"), n.get("title"), n.get("body")) for n in sent]
               == [("done", filed, True, True, "Filed", "Notes filed.")], json.dumps(sent))

    bare = add(case, home, "Bare", "program")
    ready = run_now(case, service, home, "Bare", bare, ("done", "failed", "failed_to_start"))
    session_id = ready.get("session_id") or ""
    sent = service.wait_for(lambda: adapter.deliveries(sessionID=session_id), timeout=15) or []
    case.check("bare Agent Preset: done once its agent is ready, as a Run notice",
               [(n.get("kind"), n.get("scheduleID"), n.get("runNotifyWhenDone")) for n in sent]
               == [("done", bare, True)], json.dumps(sent))


def body(case):
    home = case.home
    home.project("p", "notify", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="three", command="/bin/sh -c 'exit 3'", preset_id="three")
    home.preset(label="doomed", command="true", preset_id="doomed")
    for kind in ("program", "question", "silent", "screen"):
        home.preset(label=kind, command=write_fake(home, kind), preset_id=kind)
    service = case.serve(env={
        "HOME": home.root,
        "SHELL": "/bin/bash",
        "TZ": ZONE,
        "UNPEEL_AGENT_WORKING_TIMEOUT_MS": str(WORKING_TIMEOUT_MS),
    })
    status = service.ready(timeout=25)
    if not case.check("the Host starts with no app", bool(status), service.log()):
        return
    adapter = None
    try:
        check_quit_app(case, service, home)
        adapter = FakeAdapter(status["localSocket"])
        if not case.check("a stand-in app adapter registers notification delivery",
                          adapter.registered[0] == 200, json.dumps(adapter.registered)):
            return
        check_script_runs(case, service, home, adapter)
        check_agent_runs(case, service, home, adapter)
        invalid = [call for call in adapter.calls if "invalid" in call]
        case.check("every callback was a well-formed envelope", not invalid, json.dumps(invalid))
    finally:
        if adapter is not None:
            adapter.close()
        for session_id in list(home.manifests()):
            try:
                control(home, session_id, QUIT)
            except OSError:
                pass
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_notify", body)
