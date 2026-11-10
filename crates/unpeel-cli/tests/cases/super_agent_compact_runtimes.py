"""The Host compacts Codex and Codewhale Super Agent Workers too (fork-only, #68).

The Codex Worker is a fake `codex` launched by absolute path with
`--no-daemon` (#54): a 7501 program that writes a rollout under the private
`$HOME/.codex/sessions/`, each turn's `token_count` holding the token count in
its working directory's `tokens` file, against `gpt-5.6-sol`'s usable 258,400
window less Codex's 12,000 baseline. Typed `/compact` + Enter is a
compaction: working, `compacted`, a new `turn_context`, Codex's estimate in a
`token_count`, then done, as Codex 0.167.0 writes it.

The Codewhale Worker is a fake `codewhale` that fires the hooks the installed
integration wrote and saves its session to `$CODEWHALE_HOME/sessions/`, sized
so Codewhale's own estimate is the turn's token count. Its compaction is
v0.10.2's: no `session_busy`, no `session_idle`, one `turn_end` with
`model_backed: false`, and a smaller saved session. So the Host types
`/compact`, but never sees it start and sends the Router no `compacted`
notice (the deviation ADR 0012 records). Set UNPEEL_CODEWHALE_TEST_BINARY to
an installed `codewhale` to run the real TUI against a local stub model
instead, with `supervisor_compact_percent` at 25 (its lowest step). Its task's
paste ends with one Enter (#78), so no message pager takes the Host's
`/compact` as a search.
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
from super_agent_alerts import FakeAdapter, write_fixture  # noqa: E402

COMPACT = "/compact\r"
# A compaction that has not gone busy this long after the command never
# started (compaction.rs START_MS), plus a few rescans.
START_SECONDS = 36

FAKE_CODEX = '''
import datetime, json, os, select, sys, time, tty, uuid
tty.setraw(0)
here = os.getcwd()
log = os.path.join(here, "stdin.log")
timer = os.path.join(here, "timer")
tokens_file = os.path.join(here, "tokens")
with open(os.path.join(here, "argv"), "w") as out:
    out.write(json.dumps(sys.argv[1:]))
def now():
    return datetime.datetime.now(datetime.timezone.utc)
thread = str(uuid.uuid4())
folder = os.path.join(os.environ["HOME"], ".codex", "sessions", now().strftime("%Y/%m/%d"))
os.makedirs(folder, exist_ok=True)
rollout = os.path.join(folder, "rollout-" + now().strftime("%Y-%m-%dT%H-%M-%S") + "-" + thread + ".jsonl")
def record(kind, payload):
    stamp = now().isoformat(timespec="milliseconds").replace("+00:00", "Z")
    with open(rollout, "a") as out:
        out.write(json.dumps({"timestamp": stamp, "type": kind, "payload": payload}) + "\\n")
def usage(total):
    return {"input_tokens": total - 100, "cached_input_tokens": 0, "output_tokens": 100,
            "reasoning_output_tokens": 0, "total_tokens": total}
def token_count(total):
    record("event_msg", {"type": "token_count", "info": {
        "total_token_usage": usage(total), "last_token_usage": usage(total),
        "model_context_window": 258400}, "rate_limits": None})
def turn_context():
    record("turn_context", {"cwd": LOGICAL_CWD, "approval_policy": "on-request",
                            "model": "gpt-5.6-sol", "summary": "auto"})
record("session_meta", {"id": thread, "timestamp": now().isoformat(), "cwd": LOGICAL_CWD,
                        "originator": "codex-tui", "cli_version": "0.167.0",
                        "model_provider": "openai"})
record("event_msg", {"type": "token_count", "info": None, "rate_limits": None})
def turn_tokens():
    try:
        return int(open(tokens_file).read().strip())
    except (OSError, ValueError):
        return 131234
def report(state):
    os.write(1, b"\\x1b]7501;state=" + state.encode() + b":app=codex\\x1b\\\\")
os.write(1, b"\\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\\r\\n\\xe2\\x80\\xba ")
report("idle")
pasted = False
typed = b""
phase = None
def start(kind):
    global phase
    report("working")
    record("event_msg", {"type": "task_started", "model_context_window": 258400})
    turn_context()
    phase = (time.time() + WORK_SECONDS, kind)
def finish(kind):
    if kind == "turn":
        token_count(turn_tokens())
        record("event_msg", {"type": "agent_message", "message": REPLY})
    else:
        record("compacted", {"message": "", "replacement_history": []})
        turn_context()
        token_count(18532)
        with open(os.path.join(here, "compactions"), "a") as out:
            out.write("1\\n")
    record("event_msg", {"type": "task_complete", "last_agent_message": REPLY})
    report("done")
while True:
    if os.path.exists(timer):
        os.remove(timer)
        start("turn")
    wait = 0.2 if phase is None else max(0.0, min(0.2, phase[0] - time.time()))
    ready, _, _ = select.select([0], [], [], wait)
    if not ready:
        if phase is not None and time.time() >= phase[0]:
            finish(phase[1])
            phase = None
        continue
    data = os.read(0, 65536)
    if not data or data == b"q":
        break
    with open(log, "ab") as out:
        out.write(data)
    pasted = pasted or b"\\x1b[200~" in data
    if pasted and b"\\r" in data:
        pasted = False
        typed = b""
        start("turn")
        continue
    if not pasted:
        typed += data
        if typed.endswith(b"\\r"):
            line, typed = typed[:-1], b""
            if line == b"/compact":
                start("compact")
'''

FAKE_CODEWHALE = '''
import json, os, select, subprocess, time, tty, uuid
tty.setraw(0)
here = os.getcwd()
log = os.path.join(here, "stdin.log")
timer = os.path.join(here, "timer")
tokens_file = os.path.join(here, "tokens")
session = os.path.join(os.environ["CODEWHALE_HOME"], "sessions", str(uuid.uuid4()) + ".json")
os.makedirs(os.path.dirname(session), exist_ok=True)
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
def turn_end(model_backed, turn_id):
    fire("turn_end", {"event": "turn_end", "session_id": "sess_0badc0de",
                      "model_backed": model_backed, "turn_id": turn_id, "status": "completed",
                      "error": None})
def save(messages):
    document = {"schema_version": 1, "metadata": {"id": os.path.basename(session)[:-5],
                "workspace": LOGICAL_CWD, "model": "deepseek-flash"}, "messages": messages}
    with open(session + ".tmp", "w") as out:
        out.write(json.dumps(document, separators=(",", ":")))
    os.replace(session + ".tmp", session)
def text(role, body):
    return {"role": role, "content": [{"type": "text", "text": body}]}
def turn_tokens():
    try:
        return int(open(tokens_file).read().strip())
    except (OSError, ValueError):
        return 412000
def draw(*lines):
    os.write(1, b"\\x1b[2J\\x1b[H" + "\\r\\n".join(lines).encode())
prompt_line = "\\u2502\\u276f Type a message\\u2026"
fire("session_start")
os.write(1, b"\\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\\r\\n")
draw("HOOK_FIXTURE_PROCESS_STARTED", prompt_line)
pasted = False
typed = b""
turns = 0
def turn(prompt):
    global turns
    turns += 1
    fire("session_busy", {"from": "idle", "to": "in_progress"})
    draw(prompt, "Working", "\\u2502\\u276f Type a follow-up\\u2026", "Esc to interrupt")
    time.sleep(WORK_SECONDS)
    # Codewhale's estimate: a quarter of each text block's bytes, plus 12
    # per message and 48 of framing.
    tokens = turn_tokens()
    reply = "x" * (4 * (tokens - 72 - len(prompt.encode()) // 4))
    save([text("user", prompt), text("assistant", reply)])
    turn_end(True, "turn_" + str(turns))
    fire("session_idle", {"from": "in_progress", "to": "idle", "last_turn_status": "completed"})
    draw(prompt, REPLY, prompt_line)
def compact():
    draw("Note Making room\\u2026", prompt_line, "Esc to interrupt")
    time.sleep(WORK_SECONDS)
    save([text("user", "<!-- codewhale.compaction-checkpoint.v1 -->\\nCodewhale handoff note. "
                       + REPLY)])
    turn_end(False, "lifecycle_" + str(turns))
    with open(os.path.join(here, "compactions"), "a") as out:
        out.write("1\\n")
    draw("Note Made room", prompt_line)
while True:
    if os.path.exists(timer):
        os.remove(timer)
        turn("timer")
    ready, _, _ = select.select([0], [], [], 0.2)
    if not ready:
        continue
    data = os.read(0, 65536)
    if not data or data == b"q":
        fire("session_end")
        break
    with open(log, "ab") as out:
        out.write(data)
    pasted = pasted or b"\\x1b[200~" in data
    typed += data
    if b"\\r" not in typed:
        continue
    line, typed = typed.split(b"\\r", 1)[0], b""
    if pasted:
        pasted = False
        turn(line.replace(b"\\x1b[200~", b"").replace(b"\\x1b[201~", b"").decode())
    elif line == b"/compact":
        compact()
'''


def write_fake(path, source, reply, work_seconds, cwd):
    """`cwd` as the Session has it (a symlinked /tmp path): Codex and
    Codewhale record the directory they were started in."""
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\nREPLY = {reply!r}\nWORK_SECONDS = {work_seconds!r}\n"
                     f"LOGICAL_CWD = {cwd!r}\n" + source)
    os.chmod(path, 0o755)


class StubModel(BaseHTTPRequestHandler):
    """OpenAI-compatible chat stub for the real Codewhale: a task gets a
    reply big enough for Codewhale's estimate to pass 25% of 1M; the
    compaction's handoff request gets a short note."""

    handoffs = 0

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
        last = json.dumps(messages[-1] if messages else {})
        # Long enough to close the pager while the turn runs.
        time.sleep(6)
        if "handoff note" in last:
            StubModel.handoffs += 1
            contents = ["## Task\\nThe login form fix is done."]
        else:
            # ~1.05 MB of text: ~262K tokens by Codewhale's estimate.
            contents = ["login form fixed. "] + ["detail " * 1_500] * 100
        if not request.get("stream"):
            # The compaction's handoff request is not streamed.
            message = {"role": "assistant", "content": "".join(contents)}
            self._send(200, json.dumps({"id": "c", "object": "chat.completion", "model": "stub", "choices": [
                {"index": 0, "message": message, "finish_reason": "stop"}]}).encode())
            return
        chunk = {"id": "c", "object": "chat.completion.chunk", "created": int(time.time()), "model": "stub"}
        choices = [{"index": 0, "delta": {"role": "assistant", "content": content}, "finish_reason": None}
                   for content in contents] + [{"index": 0, "delta": {}, "finish_reason": "stop"}]
        body = "".join(f"data: {json.dumps(dict(chunk, choices=[choice]))}\n\n" for choice in choices)
        try:
            self._send(200, (body + "data: [DONE]\n\n").encode(), "text/event-stream")
        except OSError:
            pass


def body(case):
    real_codewhale = os.environ.get("UNPEEL_CODEWHALE_TEST_BINARY")
    home = case.home
    folders = {name: home.path(name) for name in ("p", "q", "r")}
    for folder in folders.values():
        os.makedirs(folder)
    home.project("p", "Router's", folders["p"])
    home.project("q", "Codex work", folders["q"])
    home.project("r", "Codewhale work", folders["r"])
    environment = {"HOME": home.root, "SHELL": "/bin/bash", "CODEWHALE_TELEMETRY": "0"}
    for directory in ("bin", "codex-bin", "codewhale-bin", ".codewhale"):
        os.makedirs(home.path(directory), exist_ok=True)
    write_fixture(home.path("bin", "router-agent"), "Router turn done", 1.5)
    # Named `codex` and `codewhale` and launched by absolute path, so the
    # Host reads them as those runtimes whatever the login shell's PATH.
    codex = home.path("codex-bin", "codex")
    write_fake(codex, FAKE_CODEX, "WORKER-REPLY codex done", 2.0, folders["q"])
    codewhale = home.path("codewhale-bin", "codewhale")
    stub = None
    if real_codewhale:
        stub = ThreadingHTTPServer(("127.0.0.1", 0), StubModel)
        threading.Thread(target=stub.serve_forever, daemon=True).start()
        with open(home.path(".codewhale", "config.toml"), "w") as config:
            config.write(f'[providers.deepseek]\napi_key = "sk-stub"\n'
                         f'base_url = "http://127.0.0.1:{stub.server_port}"\n')
        os.symlink(os.path.realpath(real_codewhale), codewhale)
        codewhale_command = shlex.quote(codewhale) + " --skip-onboarding"
    else:
        write_fake(codewhale, FAKE_CODEWHALE, "WORKER-REPLY codewhale done", 2.0, folders["r"])
        codewhale_command = shlex.quote(codewhale)
    home.preset(label="router", command=shlex.quote(home.path("bin", "router-agent")),
                preset_id="router")
    home.preset(label="codex worker", command=shlex.quote(codex) + " --no-daemon",
                preset_id="codex-worker")
    home.preset(label="codewhale worker", command=codewhale_command, preset_id="codewhale-worker")

    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=25)), service.log()):
        return
    installed = run_cli(home, ["integrations", "install", "codewhale"], env=environment)
    if not case.check("the Codewhale integration installs into the private HOME",
                      installed.returncode == 0, installed.stdout + installed.stderr):
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

    def read(project, name):
        try:
            with open(os.path.join(folders[project], name), "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    router_log = lambda: read("p", "stdin.log")  # noqa: E731

    def about(worker, status=None):
        pending = mcp(router, "inbox", {})[0].get("pending", [])
        return [item for item in pending if item.get("about") == worker
                and (status is None or item.get("status") == status)]

    def settings_set(value):
        done = run_cli(home, ["settings", "set", "supervisor_compact_percent", str(value)],
                       env=environment)
        return case.check(f"supervisor_compact_percent can be set to {value}",
                          done.returncode == 0
                          and home.state().get("supervisor_compact_percent") == value,
                          done.stdout + done.stderr)

    def turn_at(project, tokens):
        with open(os.path.join(folders[project], "tokens"), "w") as handle:
            handle.write(str(tokens))
        with open(os.path.join(folders[project], "timer"), "w"):
            pass

    def trace():
        try:
            with open(home.path("hooks", "trace.log"), errors="replace") as handle:
                return "".join([line for line in handle if "compact" in line][-15:])
        except OSError:
            return ""

    def start_worker(preset, project, label, task):
        created, done = mcp(router, "create", {
            "preset": preset, "project_id": project, "label": label, "text": task})
        worker = created.get("session_id", "")
        workers.append(worker)
        ok = case.check(f"the Router starts the {label} Worker with its task",
                        bool(worker) and created.get("worker") is True,
                        (done.stdout + done.stderr)[:400])
        return worker if ok else ""

    def codex_worker():
        worker = start_worker("codex-worker", "q", "codex task", "Please fix the codex login.")
        if not worker or not fixture_started(case, service, home.path("app-sessions", worker)):
            return
        case.check("the Codex Worker launched by absolute path with --no-daemon",
                   read("q", "argv") == '["--no-daemon"]', read("q", "argv"))
        compactions = lambda: read("q", "compactions").count("1")  # noqa: E731
        # 1. 131,234 tokens of 258,400, less the 12,000 baseline: 48%.
        case.check("the Host types /compact and Enter when the Codex turn ends",
                   bool(service.wait_for(lambda: compactions() == 1, timeout=40))
                   and read("q", "stdin.log").endswith(COMPACT),
                   repr(read("q", "stdin.log")[-300:]) + "\n" + trace())
        case.check("the Router hears the Codex Worker finished",
                   bool(service.wait_for(lambda: "\"codex task\" finished." in router_log(),
                                         timeout=40)), router_log()[-1200:])
        compacted = service.wait_for(lambda: about(worker, "compacted"), timeout=20) or []
        summary = compacted[0].get("summary", "") if compacted else ""
        case.check("a compacted notice rides along, at Codex's own percent",
                   len(compacted) == 1 and compacted[0].get("priority") == "ride_along"
                   and "was at 48% of its context (131K tokens)" in summary
                   and "supervisor_compact_percent is 40" in summary,
                   json.dumps(compacted)[:600])
        # 2. The compaction's own turn (working, then done) is nobody's news.
        service.read_for(8)
        others = [item for item in about(worker) if item.get("status") != "compacted"]
        case.check("the Codex compaction's finish reaches neither the Router nor the user",
                   router_log().count("\"codex task\" finished") == 1 and not others
                   and adapter.notified(worker) == []
                   and read("q", "stdin.log").count("/compact") == 1,
                   router_log()[-800:] + json.dumps(others)[:600])
        # 3. 105,000 tokens: 41% of the window, but 38% past the baseline.
        turn_at("q", 105_000)
        service.read_for(10)
        case.check("a Codex turn under the threshold once the baseline is left out is left alone",
                   compactions() == 1 and read("q", "stdin.log").count("/compact") == 1,
                   repr(read("q", "stdin.log")[-200:]))

    def fake_codewhale_worker():
        worker = start_worker("codewhale-worker", "r", "codewhale task",
                              "Please fix the codewhale login.")
        if not worker or not fixture_started(case, service, home.path("app-sessions", worker)):
            return
        compactions = lambda: read("r", "compactions").count("1")  # noqa: E731
        # 1. Codewhale's estimate of its saved session: 412,000 of 1M.
        case.check("the Host types /compact and Enter when the Codewhale turn ends",
                   bool(service.wait_for(lambda: compactions() == 1, timeout=40))
                   and read("r", "stdin.log").endswith(COMPACT),
                   repr(read("r", "stdin.log")[-300:]) + "\n" + trace())
        case.check("the Router hears the Codewhale Worker finished",
                   bool(service.wait_for(lambda: "\"codewhale task\" finished." in router_log(),
                                         timeout=40)), router_log()[-1200:])
        codewhale_quiet(worker, lambda: read("r", "stdin.log").count("/compact") == 1)
        # 2. Under the threshold after the compaction: left alone.
        turn_at("r", 300_000)
        service.read_for(10)
        case.check("a Codewhale turn ending at 30% is left alone",
                   compactions() == 1 and read("r", "stdin.log").count("/compact") == 1,
                   repr(read("r", "stdin.log")[-200:]))

    def codewhale_quiet(worker, typed_once):
        """ADR 0012's Codewhale deviation: its compaction never reports busy,
        so the Host never sees it start, and nobody hears of it."""
        service.read_for(START_SECONDS)
        case.check("a Codewhale compaction sends the Router no compacted notice and nothing else",
                   about(worker) == [] and router_log().count("\"codewhale task\" finished") == 1
                   and "went idle without finishing" not in router_log()
                   and adapter.notified(worker) == [] and typed_once(),
                   json.dumps(about(worker))[:600] + router_log()[-600:] + "\n" + trace())
        case.check("the Host saw it never start", "compaction never started" in trace(), trace())

    def real_codewhale_worker():
        if not settings_set(25):
            return
        worker = start_worker("codewhale-worker", "r", "codewhale task",
                              "Please fix the codewhale login.")
        if not worker:
            return

        def screen():
            return run_cli(home, ["screen", worker], env=environment).stdout

        case.check("the real Codewhale draws its composer",
                   bool(service.wait_for(lambda: "Type a" in screen(), timeout=60)), screen())
        # #78: a second Enter after the task's paste would land on the empty
        # composer and open the sent message's pager, which takes the Host's
        # /compact as a search.
        case.check("the task's paste opens no message pager",
                   not service.wait_for(lambda: "q/Esc close" in screen(), timeout=10),
                   screen())
        case.check("the Router hears the real Codewhale Worker finished",
                   bool(service.wait_for(lambda: "\"codewhale task\" finished." in router_log(),
                                         timeout=60)), router_log()[-1200:] + screen())
        if not case.check("the Host types /compact into the real Codewhale and it compacts",
                          bool(service.wait_for(lambda: StubModel.handoffs == 1, timeout=60)),
                          screen() + "\n" + trace()):
            return
        case.check("the real Codewhale makes room",
                   bool(service.wait_for(lambda: "Made room" in screen(), timeout=60)), screen())
        codewhale_quiet(worker, lambda: StubModel.handoffs == 1)

    workers = []
    try:
        if not fixture_started(case, service, home.path("app-sessions", router)):
            return
        codex_worker()
        if real_codewhale:
            real_codewhale_worker()
        else:
            fake_codewhale_worker()
    finally:
        for session_id in [router, *workers]:
            if session_id and os.path.isdir(home.path("app-sessions", session_id)):
                try:
                    control(home, session_id, "q")
                except OSError:
                    pass
                run_cli(home, ["rm", session_id], env=environment, timeout=45)
        if stub:
            stub.shutdown()


if __name__ == "__main__":
    run("super_agent_compact_runtimes", body)
