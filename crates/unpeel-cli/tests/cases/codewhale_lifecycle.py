"""Codewhale's installed observer hooks drive busy, attention, and outcomes.

By default a fake Codewhale runs in a real PTY and dispatches the
`[[hooks.hooks]]` entries the runtime installer wrote, through `sh -c` with
Codewhale's stdin payloads, including the out-of-order delivery its two hook
workers allow. Set UNPEEL_CODEWHALE_TEST_BINARY to an installed `codewhale`
to drive the real TUI against a local OpenAI-compatible stub instead. All
provider configuration stays in the test HOME.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402

UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"

FAKE_CODEWHALE = '''
import json, os, subprocess, sys, time, tty

def registrations():
    config = os.path.join(os.environ["CODEWHALE_HOME"], "config.toml")
    hooks, current = [], None
    for line in open(config).read().splitlines():
        line = line.strip()
        if line == "[[hooks.hooks]]":
            current = {}
            hooks.append(current)
        elif line.startswith("["):
            current = None
        elif current is not None and " = " in line:
            key, value = line.split(" = ", 1)
            if value.startswith('"'):
                current[key] = json.loads(value)
    return hooks

def fire(event, payload=None):
    for hook in registrations():
        if hook.get("event") == event:
            subprocess.run(["sh", "-c", hook["command"]], check=True, timeout=5,
                           input=json.dumps(payload) if payload is not None else "", text=True)

def turn_end(status, model_backed=True):
    fire("turn_end", {"event": "turn_end", "session_id": "sess_0badc0de", "model_backed": model_backed,
                      "turn_id": "t", "status": status, "error": None})

tty.setraw(0)
print("HOOK_FIXTURE_PROCESS_STARTED", flush=True)
fire("session_start")
print("FAKE_CODEWHALE_READY", flush=True)
typed = b""
while True:
    data = os.read(0, 4096)
    if not data or data == b"\\x04":
        fire("session_end")
        break
    if data == b"\\x1b":
        turn_end("interrupted")
        fire("session_idle", {"from": "in_progress", "to": "idle"})
        print("INTERRUPTED", flush=True)
        continue
    typed += data
    if b"\\r" not in typed:
        continue
    prompt, typed = typed.split(b"\\r", 1)[0].decode(), b""
    if prompt == "y":
        fire("session_busy", {"from": "waiting", "to": "in_progress"})
        turn_end("completed")
        fire("session_idle", {"from": "in_progress", "to": "idle", "last_turn_status": "completed"})
        continue
    if prompt.startswith("!"):
        fire("session_busy", {"from": "idle", "to": "in_progress"})
        turn_end("completed", model_backed=False)
        fire("session_idle", {"from": "in_progress", "to": "idle", "last_turn_status": "completed"})
        continue
    if prompt == "racy":
        # Two hook workers: the opener can land after the closer it precedes.
        turn_end("completed")
        fire("session_busy", {"from": "idle", "to": "in_progress"})
        fire("session_idle", {"from": "in_progress", "to": "idle", "last_turn_status": "completed"})
        continue
    fire("session_busy", {"from": "idle", "to": "in_progress"})
    print("BUSY " + prompt, flush=True)
    if prompt == "approve":
        fire("waiting_for_user", {"from": "in_progress", "to": "waiting", "reason": "approval"})
    elif prompt == "fail":
        turn_end("failed")
        fire("session_idle", {"from": "in_progress", "to": "idle", "last_turn_status": "failed"})
    elif prompt != "slow":
        time.sleep(0.3)
        turn_end("completed")
        fire("session_idle", {"from": "in_progress", "to": "idle", "last_turn_status": "completed"})
'''


def launch(case, environment, command):
    home = case.home
    home.preset(label="codewhale", preset_id="codewhale", command=command)
    service = case.serve(env=environment)
    ready = service.ready(timeout=20)
    if not case.check("isolated Host starts", bool(ready), service.log()):
        return None, None
    installed = run_cli(home, ["integrations", "install", "codewhale"], env=environment)
    case.check("the Codewhale integration installs into the private HOME",
               installed.returncode == 0, installed.stderr)
    config = open(home.path(".codewhale", "config.toml")).read()
    case.check("managed observer hooks land in Codewhale's config.toml",
               config.count("[[hooks.hooks]]") >= 6 and "codewhale-hook.sh" in config, config)
    mcp = read_json(home.path(".codewhale", "mcp.json"))
    case.check("the unpeel MCP shim is registered in Codewhale's mcp.json",
               "unpeel-mcp" in mcp.get("servers", {}).get("unpeel", {}).get("command", ""), str(mcp))
    launched = run_cli(home, ["new", "--preset", "codewhale", "--project", "p", "--cwd", home.root],
                       env=environment)
    ids = re.findall(UUID, launched.stdout)
    if not case.check("Codewhale launches from its preset", launched.returncode == 0 and bool(ids), launched.stderr):
        return service, None
    return service, ids[0]


def watchers(home, session_id):
    def activity():
        return read_json(home.path("activity-state.json")).get("sessions", {}).get(session_id, {})

    def status(expected):
        return lambda: activity().get("raw_status") == expected

    def completed():
        state = activity()
        return state.get("raw_status") == "idle" and state.get("completed") is True

    def settled_without_completion():
        state = activity()
        return state.get("raw_status") == "idle" and state.get("completed") is False

    return activity, status, completed, settled_without_completion


def output_has(session_dir, needle):
    try:
        with open(os.path.join(session_dir, "output.bin"), "rb") as output:
            return needle in output.read()
    except OSError:
        return False


def substitute(case):
    home = case.home
    home.project("p", "Codewhale", home.root)
    os.makedirs(home.path("bin"), exist_ok=True)
    fake = home.path("bin", "codewhale")
    with open(fake, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_CODEWHALE)
    os.chmod(fake, 0o755)
    environment = {"SHELL": "/bin/bash", "PATH": home.path("bin") + os.pathsep + os.environ["PATH"]}
    service, session_id = launch(case, environment, shlex.quote(fake))
    if not session_id:
        return
    session_dir = home.path("app-sessions", session_id)
    activity, status, completed, settled = watchers(home, session_id)
    seed = lambda: read_json(os.path.join(session_dir, "last-hook-event.json")).get("hook_event_name")  # noqa: E731

    def prompt(text):
        control(home, session_id, text)
        service.read_for(0.2)
        control(home, session_id, "\r")

    try:
        if not fixture_started(case, service, session_dir):
            return
        case.check("session_start latches without opening a turn",
                   bool(service.wait_for(lambda: output_has(session_dir, b"FAKE_CODEWHALE_READY"))) and
                   activity().get("raw_status") != "busy", str(activity()))
        prompt("slow")
        case.check("session_busy opens the turn", bool(service.wait_for(status("busy"))), str(activity()))
        control(home, session_id, "\x1b")
        case.check("turn_end interrupted settles without completion",
                   bool(service.wait_for(settled)) and seed() == "StopCancelled", str(activity()))
        prompt("hello")
        case.check("a completed turn reports success",
                   bool(service.wait_for(completed)) and seed() == "Stop", str(activity()))
        prompt("approve")
        case.check("waiting_for_user raises attention", bool(service.wait_for(status("attention"))), str(activity()))
        prompt("y")
        case.check("the approved turn resumes and completes", bool(service.wait_for(completed)), str(activity()))
        prompt("fail")
        case.check("turn_end failed settles without completion",
                   bool(service.wait_for(settled)) and seed() == "StopFailure", str(activity()))
        prompt("!ls")
        case.check("a user shell turn settles without claiming agent completion",
                   bool(service.wait_for(lambda: settled() and seed() == "Idle")), str(activity()))
        prompt("racy")
        case.check("an opener delivered after its closer is repaired by the idle backstop",
                   bool(service.wait_for(lambda: activity().get("raw_status") == "idle" and seed() == "Idle",
                                         timeout=10)), str(activity()))
        prompt("hello again")
        case.check("the next turn still completes normally", bool(service.wait_for(completed)), str(activity()))
    finally:
        run_cli(home, ["rm", session_id], env=environment, timeout=45)


class StubModel(BaseHTTPRequestHandler):
    """OpenAI-compatible chat stub: `RUN <cmd>` asks for the bash tool once,
    `slow` takes long enough to interrupt, anything else answers after 2 s."""

    def log_message(self, *args):
        pass

    def _send(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, json.dumps({"object": "list", "data": [{"id": "stub", "object": "model"}]}).encode())

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        messages = request.get("messages") or []
        last = messages[-1] if messages else {}
        text = last.get("content") if isinstance(last.get("content"), str) else json.dumps(last.get("content"))
        chunk = {"id": "c", "object": "chat.completion.chunk", "created": int(time.time()), "model": "stub"}
        if last.get("role") == "user" and "RUN " in (text or ""):
            command = re.split(r'\\n|\n|"', text.split("RUN ", 1)[1])[0].strip()
            delta = {"role": "assistant", "content": None, "tool_calls": [{
                "index": 0, "id": "call_1", "type": "function",
                "function": {"name": "bash", "arguments": json.dumps({"command": command})}}]}
            choices = [{"index": 0, "delta": delta, "finish_reason": None},
                       {"index": 0, "delta": {}, "finish_reason": "tool_calls"}]
        else:
            # Long enough for the Host's 1 s rescan to see the turn running.
            time.sleep(15 if "slow" in (text or "") else 2)
            choices = [{"index": 0, "delta": {"role": "assistant", "content": "stub reply"}, "finish_reason": None},
                       {"index": 0, "delta": {}, "finish_reason": "stop"}]
        body = "".join(f"data: {json.dumps(dict(chunk, choices=[choice]))}\n\n" for choice in choices)
        try:
            self._send(200, (body + "data: [DONE]\n\n").encode(), "text/event-stream")
        except OSError:
            pass


def real_codewhale(case, binary):
    home = case.home
    home.project("p", "Codewhale", home.root)
    stub = ThreadingHTTPServer(("127.0.0.1", 0), StubModel)
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    os.makedirs(home.path(".codewhale"), exist_ok=True)
    with open(home.path(".codewhale", "config.toml"), "w") as config:
        config.write(f'[providers.deepseek]\napi_key = "sk-stub"\nbase_url = "http://127.0.0.1:{stub.server_port}"\n')
    # Codewhale strips its MCP children's environment down to HOME and PATH,
    # so the gate finds the Unpeel home at ~/.unpeel, as in a real install.
    os.symlink(home.root, home.path(".unpeel"))
    os.makedirs(home.path("bin"), exist_ok=True)
    launcher = home.path("bin", "codewhale")
    os.symlink(os.path.realpath(binary), launcher)
    environment = {"SHELL": "/bin/bash", "CODEWHALE_TELEMETRY": "0",
                   "PATH": home.path("bin") + os.pathsep + os.environ["PATH"]}
    service, session_id = launch(case, environment, "codewhale --skip-onboarding")
    if not session_id:
        stub.shutdown()
        return
    session_dir = home.path("app-sessions", session_id)
    activity, status, completed, settled = watchers(home, session_id)

    def prompt(text):
        control(home, session_id, text)
        service.read_for(0.4)
        control(home, session_id, "\r")

    try:
        case.check("the real TUI draws its composer",
                   bool(service.wait_for(lambda: output_has(session_dir, b"Type a message"), timeout=60)))
        service.read_for(1)
        prompt("say hello")
        if not case.check("a real turn goes busy", bool(service.wait_for(status("busy"), timeout=20)),
                          str(activity())):
            case.note("screen: " + run_cli(home, ["screen", session_id], env=environment).stdout)
        case.check("a real turn completes", bool(service.wait_for(completed, timeout=30)), str(activity()))
        prompt("RUN touch made-by-stub")
        case.check("a shell approval raises attention",
                   bool(service.wait_for(status("attention"), timeout=30)), str(activity()))
        control(home, session_id, "y")
        if not case.check("the approved command runs in the Session's folder and the turn completes",
                          bool(service.wait_for(completed, timeout=30)) and
                          bool(service.wait_for(lambda: os.path.exists(home.path("made-by-stub")), timeout=5)),
                          str(activity())):
            case.note("screen: " + run_cli(home, ["screen", session_id], env=environment).stdout)
        prompt("slow")
        case.check("a slow turn goes busy", bool(service.wait_for(status("busy"), timeout=20)), str(activity()))
        service.read_for(1)
        control(home, session_id, "\x1b")
        case.check("Esc settles the turn without completion",
                   bool(service.wait_for(settled, timeout=10)) and
                   read_json(os.path.join(session_dir, "last-hook-event.json")).get("hook_event_name") == "StopCancelled",
                   str(activity()))
        saved = read_json(os.path.join(session_dir, "provider-session.json")).get("provider_session_id") or ""
        case.check("the turn end captured the saved session Codewhale holds",
                   bool(re.fullmatch(UUID, saved)) and
                   os.path.exists(home.path(".codewhale", "sessions", saved + ".json")), saved)
        transcript = run_cli(home, ["transcript", session_id], env=environment)
        case.check("the saved session resolves as the transcript",
                   transcript.returncode == 0 and "say hello" in transcript.stdout,
                   transcript.stdout[-2000:] + transcript.stderr)
        control(home, session_id, "\x04")
        case.check("Codewhale exits to the Session's shell",
                   bool(service.wait_for(lambda: output_has(session_dir, b"codewhale resume"), timeout=20)))
        service.read_for(1)
        # Codewhale strips its MCP children's environment; the shim's gate
        # must still find this Session through process ancestry.
        control(home, session_id, "codewhale mcp tools unpeel\r")

        def mounted():
            screen = run_cli(home, ["screen", session_id], env=environment).stdout
            return "sessions" in screen and "agents" in screen

        if not case.check("the unpeel MCP server serves its tools inside the hosted Session",
                          bool(service.wait_for(mounted, timeout=30)),
                          run_cli(home, ["screen", session_id], env=environment).stdout):
            manifest = home.manifests()[session_id]
            case.note("grants: " + str({key: value for key, value in manifest.items() if "mcp" in key}))
        resumed = run_cli(home, ["resume", session_id], env=environment)

        def relaunched():
            listing = subprocess.run(["ps", "-axo", "args="], capture_output=True, text=True).stdout
            return f"--skip-onboarding --resume {saved}" in listing

        case.check("Resume Agent relaunches the captured session in the same PTY",
                   resumed.returncode == 0 and bool(service.wait_for(relaunched, timeout=20)),
                   resumed.stdout + resumed.stderr)

        def reopened():
            # The exited TUI left the shell on screen, so earlier prompts can
            # only be drawn by the relaunched one.
            screen = run_cli(home, ["screen", session_id], env=environment).stdout
            return any(prompt_text in screen for prompt_text in ("say hello", "RUN touch made-by-stub"))

        case.check("the resumed TUI reopens the saved conversation", bool(service.wait_for(reopened, timeout=30)),
                   run_cli(home, ["screen", session_id], env=environment).stdout)
    finally:
        run_cli(home, ["rm", session_id], env=environment, timeout=45)
        stub.shutdown()


def check(case):
    binary = os.environ.get("UNPEEL_CODEWHALE_TEST_BINARY")
    if binary:
        real_codewhale(case, binary)
    else:
        substitute(case)


run("codewhale_lifecycle", check)
