"""A paste is followed by the Enters its runtime declares (fork-only, #78).

Every paste the Host submits (an agent's `send_text`, the Inbox's batch,
typed Host actions) ends with Enter twice, because some full-screen agent
TUIs swallow the first. Codewhale submits on the first, and its second lands
on the empty composer, where it opens the sent message's pager. So
Codewhale's runtime package declares one Enter (`[input]
enters_after_paste = 1`), and the recipe reads it from the target Session's
recognized runtime.

Fakes named `codewhale`, `codex` and `claude`, launched by absolute path so
the Host recognizes them as those runtimes, speak OSC 7501 and log their
stdin. `send_text` from another Session and a `report` the Inbox drains
both end in one Enter for Codewhale and two for Codex and Claude Code. Set
UNPEEL_CODEWHALE_TEST_BINARY to an installed `codewhale` to also run the
real TUI against a local stub model: neither paste opens its pager.
"""

import json
import os
import shlex
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402

HEADER = "[unpeel inbox for id:"
PASTE_END = "\x1b[201~"
PAGER = "q/Esc close"
# Past the recipe's 80 ms between Enters, with room for a slow machine.
AFTER_PASTE = 1.5

FIXTURE = '''
import os, select, time, tty
tty.setraw(0)
log = os.path.join(os.getcwd(), "stdin.log")
def report(state):
    os.write(1, b"\\x1b]7501;state=" + state.encode() + b":app=fake\\x1b\\\\")
os.write(1, b"\\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\\r\\n> ")
report("idle")
pasted = False
busy_until = None
while True:
    wait = None if busy_until is None else max(0.0, busy_until - time.time())
    ready, _, _ = select.select([0], [], [], wait)
    if not ready:
        report("idle")
        busy_until = None
        continue
    data = os.read(0, 65536)
    if not data or data == b"q":
        break
    with open(log, "ab") as out:
        out.write(data)
    pasted = pasted or b"\\x1b[200~" in data
    if pasted and b"\\r" in data:
        pasted = False
        report("working")
        busy_until = time.time() + 1.5
'''


def write_fake(path):
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FIXTURE)
    os.chmod(path, 0o755)


def enters_after(text, start):
    """The Enters that follow the first paste written at or after `start`."""
    end = text.find(PASTE_END, start)
    return -1 if end < 0 else text[end + len(PASTE_END):].count("\r")


class StubModel(BaseHTTPRequestHandler):
    """OpenAI-compatible chat stub for the real Codewhale: every request gets
    a short streamed (or plain) reply."""

    prompts = []

    def log_message(self, *args):
        pass

    def _send(self, body, content_type="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(json.dumps({"object": "list", "data": [{"id": "stub", "object": "model"}]})
                   .encode())

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        StubModel.prompts.append(json.dumps(request.get("messages") or []))
        reply = "STUB-REPLY done"
        if not request.get("stream"):
            message = {"role": "assistant", "content": reply}
            self._send(json.dumps({"id": "c", "object": "chat.completion", "model": "stub",
                                   "choices": [{"index": 0, "message": message,
                                                "finish_reason": "stop"}]}).encode())
            return
        chunk = {"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
                 "model": "stub"}
        choices = [{"index": 0, "delta": {"role": "assistant", "content": reply},
                    "finish_reason": None}, {"index": 0, "delta": {}, "finish_reason": "stop"}]
        body = "".join(f"data: {json.dumps(dict(chunk, choices=[choice]))}\n\n"
                       for choice in choices)
        try:
            self._send((body + "data: [DONE]\n\n").encode(), "text/event-stream")
        except OSError:
            pass


def body(case):
    real_codewhale = os.environ.get("UNPEEL_CODEWHALE_TEST_BINARY")
    home = case.home
    home.project("p", "paste enters", home.root)
    state = home.state()
    # No Controller answers approval prompts here.
    state["mcp_nonchild_write_access"] = "allow"
    home.write_state(state)
    environment = {"HOME": home.root, "SHELL": "/bin/bash", "CODEWHALE_TELEMETRY": "0"}
    # Each fake is named for its runtime and works in a folder of its own.
    fakes = {"codewhale": [], "codex": ["--no-daemon"], "claude": []}
    folders = {}
    for runtime, args in fakes.items():
        folders[runtime] = home.path(runtime)
        os.makedirs(home.path(runtime, "bin"))
        program = home.path(runtime, "bin", runtime)
        write_fake(program)
        home.preset(label=runtime, command=" ".join([shlex.quote(program), *args]),
                    preset_id=runtime)
    home.preset(label="cat", command="cat", preset_id="cat")
    stub = None
    if real_codewhale:
        folders["real"] = home.path("real")
        os.makedirs(home.path("real", "bin"))
        os.makedirs(home.path(".codewhale"), exist_ok=True)
        stub = ThreadingHTTPServer(("127.0.0.1", 0), StubModel)
        threading.Thread(target=stub.serve_forever, daemon=True).start()
        with open(home.path(".codewhale", "config.toml"), "w") as config:
            config.write(f'[providers.deepseek]\napi_key = "sk-stub"\n'
                         f'base_url = "http://127.0.0.1:{stub.server_port}"\n')
        program = home.path("real", "bin", "codewhale")
        os.symlink(os.path.realpath(real_codewhale), program)
        home.preset(label="real-codewhale", command=shlex.quote(program) + " --skip-onboarding",
                    preset_id="real")

    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=25)), service.log()):
        return

    launched = []

    def launch(preset, cwd=None):
        args = ["new", "--preset", preset, "--project", "p"] + (["--cwd", cwd] if cwd else [])
        started = run_cli(home, args, env=environment)
        launched.append(started.stdout + started.stderr)
        ids = [w for w in started.stdout.split() if len(w) == 36 and w.count("-") == 4]
        return ids[0] if ids else ""

    sessions = {runtime: launch(runtime, folders[runtime]) for runtime in fakes}
    caller = launch("cat")
    ids = [*sessions.values(), caller]
    if not case.check("the fakes and the caller start",
                      all(ids) and all(wait_running(home, i) for i in ids), str(ids)):
        return

    def mcp(action, *words):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=caller)
        done = subprocess.run([BINARY, "mcp", "sessions", action, *words],
                              capture_output=True, text=True, timeout=60, env=env, cwd=CRATES)
        try:
            return json.loads(done.stdout), done
        except ValueError:
            return {}, done

    def manifest(session_id):
        return read_json(home.path("app-sessions", session_id, "manifest.json"))

    def observed(session_id):
        runtime = (manifest(session_id).get("runtime") or {}).get("currentObservation") or {}
        return runtime.get("id")

    def logged(runtime):
        try:
            with open(os.path.join(folders[runtime], "stdin.log"), "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def activity(session_id):
        sessions_state = read_json(home.path("activity-state.json")).get("sessions", {})
        return sessions_state.get(session_id, {})

    def idle(session_id):
        return lambda: activity(session_id).get("raw_status") == "idle" \
            and activity(session_id).get("activity_source") == "program"

    def screen(session_id):
        return run_cli(home, ["screen", session_id], env=environment).stdout

    wanted = {"codewhale": 1, "codex": 2, "claude": 2}
    real = ""
    try:
        for runtime, session_id in sessions.items():
            if not fixture_started(case, service, home.path("app-sessions", session_id)):
                return
            case.check(f"the Host recognizes the fake {runtime}",
                       bool(service.wait_for(lambda: observed(session_id) == runtime,
                                             timeout=20)),
                       str(manifest(session_id).get("runtime")))
            case.check(f"the fake {runtime} is idle from its own report",
                       bool(service.wait_for(idle(session_id), timeout=15)),
                       str(activity(session_id)))

        # 1. send_text from another Session.
        for runtime, session_id in sessions.items():
            start = len(logged(runtime))
            sent, done = mcp("send_text", f"session_id={session_id}",
                             f"text=send_text for {runtime}")
            service.read_for(AFTER_PASTE)
            case.check(f"send_text to {runtime} is followed by {wanted[runtime]} Enter(s)",
                       done.returncode == 0
                       and enters_after(logged(runtime), start) == wanted[runtime],
                       repr(logged(runtime)[start:]) + (done.stdout + done.stderr)[:300])
            service.wait_for(idle(session_id), timeout=15)

        # 2. A report the Inbox drains once the target is idle and quiet.
        for runtime, session_id in sessions.items():
            start = len(logged(runtime))
            queued, done = mcp("report", f"session_id={session_id}",
                               f"summary=report for {runtime}", "status=done")
            if not case.check(f"a report to {runtime} is queued", queued.get("queued") is True,
                              (done.stdout + done.stderr)[:300]):
                continue
            pasted = service.wait_for(lambda: HEADER in logged(runtime)[start:], timeout=30)
            service.read_for(AFTER_PASTE)
            case.check(f"the Inbox's paste into {runtime} is followed by "
                       f"{wanted[runtime]} Enter(s)",
                       bool(pasted) and enters_after(logged(runtime), start) == wanted[runtime],
                       repr(logged(runtime)[start:][-300:]))

        # 3. The real Codewhale, against the stub model.
        if not real_codewhale:
            return
        real = launch("real-codewhale", folders["real"])
        if not case.check("the real Codewhale starts", bool(real) and wait_running(home, real),
                          launched[-1][:400]):
            return
        case.check("the real Codewhale draws its composer",
                   bool(service.wait_for(lambda: "Type a" in screen(real), timeout=60)),
                   screen(real))
        case.check("the Host recognizes the real Codewhale",
                   bool(service.wait_for(lambda: observed(real) == "codewhale", timeout=20)),
                   str(manifest(real).get("runtime")))
        for step, send in (
            ("send_text", lambda: mcp("send_text", f"session_id={real}",
                                      "text=REAL-SEND please reply")),
            ("the Inbox", lambda: mcp("report", f"session_id={real}",
                                      "summary=REAL-REPORT please reply", "status=done")),
        ):
            asked, replies = len(StubModel.prompts), screen(real).count("STUB-REPLY")
            send()
            case.check(f"the real Codewhale submits the paste from {step}",
                       bool(service.wait_for(lambda: len(StubModel.prompts) > asked,
                                             timeout=60)), screen(real))
            pager = service.wait_for(lambda: PAGER in screen(real), timeout=5)
            case.check(f"the paste from {step} opens no pager", not pager, screen(real))
            if pager:
                run_cli(home, ["keys", real, "escape"], env=environment)
            case.check(f"the real Codewhale answers the paste from {step}",
                       bool(service.wait_for(lambda: screen(real).count("STUB-REPLY") > replies,
                                             timeout=60)), screen(real))
    finally:
        for runtime, session_id in sessions.items():
            if session_id:
                try:
                    control(home, session_id, "q", origin="program")
                except OSError:
                    pass
        for session_id in [*ids, real]:
            if session_id:
                run_cli(home, ["rm", session_id], env=environment, timeout=45)
        if stub:
            stub.shutdown()


run("paste_enters", body)
