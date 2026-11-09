"""The Host compacts a Super Agent Worker whose context is full (fork-only, #64).

The Worker is a fake `claude`: a 7501 program that writes a Claude Code
transcript under the private `$HOME/.claude/projects/`. Each turn records an
assistant reply whose usage is the token count in its working directory's
`tokens` file, against `claude-opus-5-5`'s 1M window from the runtime
package. Typed `/compact` + Enter is a compaction: working, a
`compact_boundary`, then done carrying the previous reply's message, as real
Claude Code reports it.

At 41% when its task's turn ends, the Host types `/compact`; the Router gets
the finished notice and a ride-along "compacted" notice, and the
compaction's own turn reaches neither the Router nor the user. Under the
threshold, or with `supervisor_compact_percent` at 0, nothing is typed.
"""

import json
import os
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running, TRUST_SESSION_ENV  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402
from super_agent_alerts import FakeAdapter, write_fixture  # noqa: E402

WORKER_REPLY = "WORKER-REPLY login form fixed"
COMPACT = "/compact\r"

FAKE_CLAUDE = '''
import base64, json, os, select, time, tty, uuid
tty.setraw(0)
here = os.getcwd()
log = os.path.join(here, "stdin.log")
timer = os.path.join(here, "timer")
tokens_file = os.path.join(here, "tokens")
cwds = {here, LOGICAL_CWD}
dirs = {os.path.join(os.environ["HOME"], ".claude", "projects", cwd.replace("/", "-"))
        for cwd in cwds}
name = str(uuid.uuid4()) + ".jsonl"
for directory in dirs:
    os.makedirs(directory, exist_ok=True)
    open(os.path.join(directory, name), "a").close()
def transcript(record):
    for directory in dirs:
        with open(os.path.join(directory, name), "a") as out:
            out.write(json.dumps(record) + "\\n")
def reply():
    try:
        tokens = int(open(tokens_file).read().strip())
    except (OSError, ValueError):
        tokens = 412000
    transcript({"type": "assistant", "isSidechain": False, "message": {
        "model": "claude-opus-5-5", "role": "assistant",
        "content": [{"type": "text", "text": REPLY}],
        "usage": {"input_tokens": 2, "cache_creation_input_tokens": 1000,
                  "cache_read_input_tokens": tokens - 1002, "output_tokens": 10}}})
def boundary():
    transcript({"type": "system", "subtype": "compact_boundary",
                "content": "Conversation compacted",
                "compactMetadata": {"trigger": "manual", "postTokens": 23000}})
    with open(os.path.join(here, "compactions"), "a") as out:
        out.write("1\\n")
def report(pairs):
    os.write(1, b"\\x1b]7501;" + pairs.encode() + b":app=claude-code\\x1b\\\\")
def msg(text):
    return base64.b64encode(text.encode()).decode()
os.write(1, b"\\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\\r\\n\\xe2\\x9d\\xaf ")
report("state=idle")
pasted = False
typed = b""
phase = None
def start(kind):
    global phase
    report("state=working")
    phase = ("working", time.time() + WORK_SECONDS, kind)
while True:
    if os.path.exists(timer):
        os.remove(timer)
        start("turn")
    wait = 0.2 if phase is None else max(0.0, min(0.2, phase[1] - time.time()))
    ready, _, _ = select.select([0], [], [], wait)
    if not ready:
        if phase is None or time.time() < phase[1]:
            continue
        if phase[0] == "working":
            if phase[2] == "turn":
                reply()
            else:
                boundary()
            report("state=done:msg=" + msg(REPLY))
            phase = ("done", time.time() + 1.5, None)
        else:
            report("state=idle")
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


def write_fake_claude(path, reply, work_seconds, cwd):
    """`cwd` as the Session has it: real Claude Code's hooks report the
    transcript's path; without them the Host looks under the Session's cwd,
    which here is a symlinked /tmp path."""
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\nREPLY = {reply!r}\nWORK_SECONDS = {work_seconds!r}\n"
                     f"LOGICAL_CWD = {cwd!r}\n" + FAKE_CLAUDE)
    os.chmod(path, 0o755)


def body(case):
    home = case.home
    folders = {name: home.path(name) for name in ("p", "q")}
    for folder in folders.values():
        os.makedirs(folder)
    home.project("p", "Router's", folders["p"])
    home.project("q", "Work", folders["q"])
    environment = {"HOME": home.root, "SHELL": "/bin/bash"}
    os.makedirs(home.path("bin"), exist_ok=True)
    os.makedirs(home.path("claude-bin"), exist_ok=True)
    write_fixture(home.path("bin", "router-agent"), "Router turn done", 1.5)
    # Named `claude`, so the Host reads it as Claude Code and finds its
    # transcript.
    write_fake_claude(home.path("claude-bin", "claude"), WORKER_REPLY, 2.0, folders["q"])
    home.preset(label="router", command=shlex.quote(home.path("bin", "router-agent")),
                preset_id="router")
    home.preset(label="worker", command=shlex.quote(home.path("claude-bin", "claude")),
                preset_id="worker")

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
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id, **TRUST_SESSION_ENV)
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

    def compactions():
        return read("q", "compactions").count("1")

    def settings_set(value):
        done = run_cli(home, ["settings", "set", "supervisor_compact_percent", str(value)],
                       env=environment)
        return case.check(f"supervisor_compact_percent can be set to {value}",
                          done.returncode == 0
                          and home.state().get("supervisor_compact_percent") == value,
                          done.stdout + done.stderr)

    def turn_at(tokens):
        with open(os.path.join(folders["q"], "tokens"), "w") as handle:
            handle.write(str(tokens))
        with open(os.path.join(folders["q"], "timer"), "w"):
            pass

    def diagnose(worker):
        """What the Host had to go on, for a failure's detail."""
        projects = home.path(".claude", "projects")
        listing = [os.path.join(root, name) for root, _, names in os.walk(projects)
                   for name in names]
        try:
            with open(home.path("hooks", "trace.log"), errors="replace") as handle:
                trace = [line for line in handle if "compact" in line or "supervisor" in line]
        except OSError:
            trace = []
        manifest = read_json(home.path("app-sessions", worker, "manifest.json"))
        return (f"\ntranscripts: {listing}\ncwd: {manifest.get('cwd')}\n"
                f"trace: {''.join(trace[-15:])}")

    workers = []
    try:
        if not fixture_started(case, service, home.path("app-sessions", router)):
            return
        created, done = mcp(router, "create", {
            "preset": "worker", "project_id": "q", "label": "fix login",
            "text": "Please fix the login form."})
        worker = created.get("session_id", "")
        workers.append(worker)
        if not case.check("the Router starts a fake-claude Worker with its task",
                          bool(worker) and created.get("worker") is True,
                          (done.stdout + done.stderr)[:400]):
            return
        if not fixture_started(case, service, home.path("app-sessions", worker)):
            return
        manifest = read_json(home.path("app-sessions", worker, "manifest.json"))
        case.check("the Worker's PTY core has the draft guard",
                   manifest.get("draft_guard") is True, str(manifest)[:300])

        # 1. Its task's turn ends at 41% of 1M: the Host types /compact.
        case.check("the task is pasted into the Worker",
                   bool(service.wait_for(lambda: "Please fix the login form." in read("q", "stdin.log"),
                                         timeout=30)), read("q", "stdin.log")[-300:])
        case.check("the Host types /compact and Enter when the turn ends",
                   bool(service.wait_for(lambda: compactions() == 1, timeout=40)),
                   repr(read("q", "stdin.log")[-300:]) + diagnose(worker))
        case.check("as typed keys, after the task",
                   read("q", "stdin.log").endswith(COMPACT), repr(read("q", "stdin.log")[-200:]))
        router_log = lambda: read("p", "stdin.log")  # noqa: E731
        case.check("the Router hears the Worker finished",
                   bool(service.wait_for(lambda: "\"fix login\" finished." in router_log(),
                                         timeout=40)), router_log()[-1200:])

        def about_worker(status=None):
            pending = mcp(router, "inbox", {})[0].get("pending", [])
            return [item for item in pending if item.get("about") == worker
                    and (status is None or item.get("status") == status)]

        compacted = service.wait_for(lambda: about_worker("compacted"), timeout=20) or []
        case.check("a compacted notice rides along in the Router's Inbox, not waking it",
                   len(compacted) == 1 and compacted[0].get("priority") == "ride_along"
                   and "the Host compacted it" not in router_log(), json.dumps(compacted)[:600])
        summary = compacted[0].get("summary", "") if compacted else ""
        case.check("the notice names the percent and the setting",
                   "was at 41% of its context (412K tokens)" in summary
                   and "supervisor_compact_percent is 40" in summary, summary)

        # 2. The compaction's own turn (working, then done) is nobody's news.
        service.read_for(8)
        others = [item for item in about_worker() if item.get("status") != "compacted"]
        case.check("its finish reaches the Router neither pasted nor waiting",
                   router_log().count("\"fix login\" finished") == 1
                   and "went idle without finishing" not in router_log() and not others,
                   router_log()[-800:] + json.dumps(others)[:600])
        case.check("no notification was requested for the Worker",
                   adapter.notified(worker) == [], json.dumps(adapter.notified(worker)))
        case.check("the Host typed /compact once",
                   read("q", "stdin.log").count("/compact") == 1, repr(read("q", "stdin.log")))

        # 3. Under the threshold: nothing typed.
        turn_at(300_000)
        service.read_for(10)
        case.check("a turn ending at 30% is left alone",
                   compactions() == 1 and read("q", "stdin.log").count("/compact") == 1,
                   repr(read("q", "stdin.log")[-200:]))

        # 4. Off: nothing typed, however full.
        if not settings_set(0):
            return
        turn_at(900_000)
        service.read_for(10)
        case.check("with supervisor_compact_percent 0 a 90% turn is left alone",
                   compactions() == 1, repr(read("q", "stdin.log")[-200:]))

        # 5. Back on at 50: a 55% turn is compacted again (re-armed by the
        # compaction's 2% and the 30% turn).
        if not settings_set(50):
            return
        turn_at(550_000)
        case.check("set to 50, a 55% turn is compacted",
                   bool(service.wait_for(lambda: compactions() == 2, timeout=40)),
                   repr(read("q", "stdin.log")[-200:]))
    finally:
        for session_id in [router, *workers]:
            if session_id and os.path.isdir(home.path("app-sessions", session_id)):
                try:
                    control(home, session_id, "q")
                except OSError:
                    pass
                run_cli(home, ["rm", session_id], env=environment, timeout=45)


if __name__ == "__main__":
    run("super_agent_compaction", body)
