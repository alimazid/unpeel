"""Only a Session's own processes speak for it (#70, #71).

An exported `UNPEEL_SESSION_ID` is a claim. A process that inherited a
Session's environment and then left its process tree (Codex's shared
app-server daemon, which keeps the environment of whichever Session started
it and runs other clients' hooks and MCP servers with it) must move none of
that Session's state and get none of its tools.

A fake Codex runs in Session A with the installed Codex integration:

* its own hook commands, MCP gate and `unpeel` CLI calls apply to A, also
  from a child in a new POSIX session (Claude Code runs every hook and
  Bash-tool command that way);
* a detached runner (double fork into a new session, its parent no longer
  A's process tree) that keeps A's whole exported environment fires the same
  hook commands, starts the same gate and makes the same CLI call: A's
  activity and its durable `last-hook-event.json` stay as they were, the
  trace records the refusal, the gate lists no tools and the CLI refuses.
  The reporter refuses before it writes the marker or posts, so the Host
  never sees the event: the Host re-seeds activity from that marker on every
  scan, so a refused POST alone would not keep A's activity unchanged;
* after a Host restart the adopted Session's own processes still pass.

The Host itself runs with the test switch that trusts an exported id: the
Session must not inherit it, or the detached runner would pass.

The real Codex is never run here.
"""

import json
import os
import re
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, TRUST_SESSION_ENV, run, run_cli  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402

UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"

FAKE_CODEX = r'''
import json, os, select, subprocess, sys, time, tty

UNPEEL = "@UNPEEL@"
OUT = os.path.join(os.environ["HOME"], "fake-codex")
FAKE_PID = os.getpid()
os.makedirs(OUT, exist_ok=True)
tty.setraw(0)


def hook(event):
    with open(os.path.join(os.environ["HOME"], ".codex", "hooks.json")) as handle:
        registrations = json.load(handle)["hooks"][event]
    for entry in registrations:
        for command in entry["hooks"]:
            subprocess.run(command["command"], shell=True, executable="/bin/bash",
                           input=json.dumps({"hook_event_name": event}), text=True,
                           capture_output=True, timeout=30)


def registration():
    path = os.path.join(os.environ["HOME"], ".codex", "config.toml")
    table, server = None, {}
    for line in open(path).read().splitlines():
        line = line.strip()
        if line.startswith("["):
            table = line
        elif table == "[mcp_servers.unpeel]" and " = " in line:
            key, value = line.split(" = ", 1)
            server[key] = json.loads(value)
    return server


def gate():
    # The registered server with this process's whole environment, exported
    # Session id included: what a launcher that forwards it would start.
    server = registration()
    child = subprocess.Popen([server["command"]] + server.get("args", []),
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "fake-codex", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
            "name": "sessions", "arguments": {"action": "current"}}},
    ]
    child.stdin.write("".join(json.dumps(r) + "\n" for r in requests).encode())
    child.stdin.flush()
    responses, buffered, deadline = {}, b"", time.time() + 30
    while 3 not in responses and time.time() < deadline:
        ready, _, _ = select.select([child.stdout], [], [], 1)
        if not ready:
            continue
        chunk = os.read(child.stdout.fileno(), 65536)
        if not chunk:
            break
        buffered += chunk
        while b"\n" in buffered:
            line, buffered = buffered.split(b"\n", 1)
            if line.strip():
                message = json.loads(line)
                responses[message.get("id")] = message
    child.stdin.close()
    child.wait(timeout=30)
    tools = [tool.get("name") for tool in
             responses.get(2, {}).get("result", {}).get("tools", [])]
    return {"tools": tools, "current": json.dumps(responses.get(3, {}))}


def cli():
    done = subprocess.run([UNPEEL, "mcp", "sessions", "current"],
                          capture_output=True, text=True, timeout=60)
    return {"rc": done.returncode, "out": done.stdout[-4000:], "err": done.stderr[-1000:]}


def write(name, result):
    with open(os.path.join(OUT, name + ".json"), "w") as handle:
        json.dump(result, handle)
    os.write(1, ("FAKE_DONE " + name + "\r\n").encode())


def in_new_posix_session(work):
    # A child that is still ours but leads its own POSIX session.
    pid = os.fork()
    if pid == 0:
        try:
            os.setsid()
            work()
        finally:
            os._exit(0)
    os.waitpid(pid, 0)


def detached(work):
    # Double fork into a new session: the runner's parent is no longer this
    # process, as for the hooks and servers of Codex's shared daemon.
    middle = os.fork()
    if middle == 0:
        os.setsid()
        if os.fork() == 0:
            for _ in range(100):
                if os.getppid() not in (FAKE_PID, middle):
                    break
                time.sleep(0.05)
            try:
                work(middle)
            finally:
                os._exit(0)
        os._exit(0)
    os.waitpid(middle, 0)


def probe():
    write("probe", dict(gate(), cli=cli()))


def setsid_probe():
    write("setsid", {"own_session": os.getsid(0) == os.getpid(),
                     "parent": os.getppid(), "fake": FAKE_PID, "cli": cli()})


def detached_run(event):
    def work(middle):
        parent = os.getppid()
        hook(event)
        write("detached-" + event, dict(
            gate(), cli=cli(), parent=parent, fake=FAKE_PID, middle=middle,
            env={key: os.environ.get(key) for key in (
                "UNPEEL_SESSION_ID", "UNPEEL_SESSION_DIR", "UNPEEL_HOST_BIN",
                "UNPEEL_HOME", "UNPEEL_APP_PORT_REGISTRY_FILE")}))
    detached(work)


os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\r\n")
hook("UserPromptSubmit")
actions = {
    b"r": lambda: hook("UserPromptSubmit"),
    b"s": lambda: hook("Stop"),
    b"p": probe,
    b"q": lambda: in_new_posix_session(setsid_probe),
    b"u": lambda: in_new_posix_session(lambda: hook("UserPromptSubmit")),
    b"t": lambda: in_new_posix_session(lambda: hook("Stop")),
    b"d": lambda: detached_run("UserPromptSubmit"),
    b"e": lambda: detached_run("Stop"),
}
while True:
    data = os.read(0, 4096)
    if not data:
        break
    for key in data:
        action = actions.get(bytes([key]))
        if action:
            action()
'''


def output_has(session_dir, needle):
    try:
        with open(os.path.join(session_dir, "output.bin"), "rb") as output:
            return output.read().count(needle)
    except OSError:
        return 0


def marker(session_dir):
    path = os.path.join(session_dir, "last-hook-event.json")
    try:
        with open(path, "rb") as handle:
            return handle.read(), os.stat(path).st_mtime_ns
    except OSError:
        return None


def body(case):
    home = case.home
    home.project("p", "Codex", home.root)
    os.makedirs(home.path("bin"), exist_ok=True)
    fake = home.path("bin", "codex")
    with open(fake, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_CODEX.replace("@UNPEEL@", BINARY))
    os.chmod(fake, 0o755)
    environment = {"SHELL": "/bin/bash", **TRUST_SESSION_ENV}
    # The login shell rebuilds PATH, so launch the fake by its absolute path.
    home.preset(label="codex", preset_id="codex", command=shlex.quote(fake))
    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=20)), service.log()):
        return
    installed = run_cli(home, ["integrations", "install", "codex"], env=environment)
    case.check("the Codex integration installs into the private HOME",
               installed.returncode == 0, installed.stderr)
    launched = run_cli(home, ["new", "--preset", "codex", "--project", "p", "--cwd", home.root],
                       env=environment)
    ids = re.findall(UUID, launched.stdout)
    if not case.check("the fake Codex launches", launched.returncode == 0 and bool(ids),
                      launched.stderr):
        return
    session_id = ids[0]
    session_dir = home.path("app-sessions", session_id)
    trace = home.path("hooks", "trace.log")

    def activity():
        return read_json(home.path("activity-state.json")).get("sessions", {}).get(session_id, {})

    def expect(label, status, completed):
        return case.check(label, bool(service.wait_for(
            lambda: activity().get("raw_status") == status
            and activity().get("completed") is completed, timeout=20)), str(activity()))

    def stays(label, status, completed):
        service.read_for(3)
        current = activity()
        case.check(label, current.get("raw_status") == status
                   and current.get("completed") is completed, str(current))

    def act(key, name):
        before = output_has(session_dir, f"FAKE_DONE {name}".encode())
        control(home, session_id, key)
        done = service.wait_for(
            lambda: output_has(session_dir, f"FAKE_DONE {name}".encode()) > before, timeout=90)
        return read_json(home.path("fake-codex", name + ".json")) if done else {}

    def refusals():
        try:
            with open(trace) as handle:
                return sum(f"hook-refused session={session_id} reason=not-an-ancestor" in line
                           for line in handle)
        except OSError:
            return 0

    def own_processes_pass(when):
        probe = act("p", "probe")
        case.check(f"{when}: the Session's own MCP gate lists the Unpeel tools",
                   "sessions" in probe.get("tools", []), str(probe.get("tools")))
        case.check(f"{when}: its tools act as this Session",
                   session_id in probe.get("current", ""), probe.get("current", "")[:300])
        cli = probe.get("cli", {})
        case.check(f"{when}: its `unpeel` CLI call works",
                   cli.get("rc") == 0 and session_id in cli.get("out", ""), str(cli)[:400])
        control(home, session_id, "r")
        expect(f"{when}: its opening hook makes the Session busy", "busy", False)
        control(home, session_id, "s")
        expect(f"{when}: its Stop completes the turn", "idle", True)

    try:
        if not fixture_started(case, service, session_dir):
            return
        expect("the fake Codex's opening hook makes the Session busy", "busy", False)
        control(home, session_id, "s")
        expect("its Stop completes the turn", "idle", True)
        own_processes_pass("in the Session")

        posix = act("q", "setsid")
        case.check("the setsid child leads its own POSIX session and is still the fake's child",
                   posix.get("own_session") is True and posix.get("parent") == posix.get("fake"),
                   str(posix))
        cli = posix.get("cli", {})
        case.check("from a new POSIX session the `unpeel` CLI call still works",
                   cli.get("rc") == 0 and session_id in cli.get("out", ""), str(cli)[:400])
        control(home, session_id, "u")
        expect("from a new POSIX session the opening hook still applies", "busy", False)
        control(home, session_id, "t")
        expect("from a new POSIX session the Stop still applies", "idle", True)

        seed = marker(session_dir)
        case.check("the Session has a durable hook marker", seed is not None)
        opening = act("d", "detached-UserPromptSubmit")
        case.check("the detached runner's parent is outside the Session",
                   opening.get("parent") not in (None, opening.get("fake"), opening.get("middle")),
                   str({key: opening.get(key) for key in ("parent", "fake", "middle")}))
        env = opening.get("env", {})
        case.check("the detached runner keeps the Session's exported environment",
                   env.get("UNPEEL_SESSION_ID") == session_id
                   and bool(env.get("UNPEEL_SESSION_DIR")) and bool(env.get("UNPEEL_HOST_BIN")),
                   str(env))
        stays("a detached runner's opening hook leaves the Session idle", "idle", True)
        case.check("and leaves its durable marker untouched", marker(session_dir) == seed)
        case.check("the detached runner's MCP gate lists no tools",
                   opening.get("tools") == [], str(opening.get("tools")))
        case.check("and its tool call is refused",
                   session_id not in opening.get("current", "")
                   and '"error"' in opening.get("current", ""), opening.get("current", "")[:300])
        cli = opening.get("cli", {})
        case.check("the detached runner's `unpeel` CLI call does not act as the Session",
                   session_id not in cli.get("out", "") and cli.get("rc") != 0, str(cli)[:400])

        control(home, session_id, "r")
        expect("the Session's own opening hook still applies", "busy", False)
        seed = marker(session_dir)
        act("e", "detached-Stop")
        stays("a detached runner's Stop leaves the Session busy", "busy", False)
        case.check("and leaves its durable marker untouched", marker(session_dir) == seed)
        case.check("the trace records both refusals", refusals() == 2, str(refusals()))
        control(home, session_id, "s")
        expect("the Session's own Stop completes the turn", "idle", True)

        before = home.manifests().get(session_id, {})
        service.close()
        service = case.serve(env=environment)
        ready = bool(service.ready(timeout=25))
        after = home.manifests().get(session_id, {})
        case.check("the Host restarts and adopts the same running Session",
                   ready and after.get("state") == "running"
                   and bool(before.get("pid")) and after.get("pid") == before.get("pid")
                   and after.get("pid_started_at") == before.get("pid_started_at"),
                   str({key: (before.get(key), after.get(key))
                        for key in ("state", "pid", "pid_started_at")}))
        own_processes_pass("after a Host restart")
    finally:
        run_cli(home, ["rm", session_id], env=environment, timeout=45)


if __name__ == "__main__":
    run("session_identity_ancestry", body)
