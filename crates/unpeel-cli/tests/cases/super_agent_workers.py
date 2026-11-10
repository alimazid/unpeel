"""Super Agent Workers (fork-only).

The Router (marked directly in this private home's app-state) starts a
Worker in another Project with a first task: it runs in that Project's
folder, carries a Worker marker, and gets the task pasted once it is idle.
The Worker's report reaches the Router's Inbox with no approval prompt
(the write policy stays at its default, Ask), and the Router's
`sessions current` shows the Worker's card. The Router's waits are capped
at 5 s. `sessions stop` stops the Worker without removing it and returns
what its Inbox still held; `close` removes only the Router's own Workers,
by marker alone.
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

HEADER = "[unpeel inbox for id:"


def write_fixture(path):
    """A 7501 program with bracketed paste, logging stdin to `stdin.log` in
    its own working directory: idle at its prompt, briefly working after a
    submitted paste, and obeying `q` (quit)."""
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + '''
import os, select, time, tty
tty.setraw(0)
log = os.path.join(os.getcwd(), "stdin.log")
def report(state):
    os.write(1, b"\\x1b]7501;state=" + state.encode() + b":app=workers\\x1b\\\\")
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
        busy_until = time.time() + 1.0
''')
    os.chmod(path, 0o755)


def body(case):
    home = case.home
    folders = {name: home.path(name) for name in ("p", "q")}
    for folder in folders.values():
        os.makedirs(folder)
    home.project("p", "Router's", folders["p"])
    home.project("q", "Other", folders["q"])
    environment = {"HOME": home.root, "SHELL": "/bin/bash"}
    os.makedirs(home.path("bin"), exist_ok=True)
    program = home.path("bin", "worker-agent")
    write_fixture(program)
    home.preset(label="agent", command=shlex.quote(program), preset_id="agent")
    home.preset(label="cat", command="cat", preset_id="cat")

    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=25)), service.log()):
        return

    def launch(preset, project):
        started = run_cli(home, ["new", "--preset", preset, "--project", project,
                                 "--cwd", folders[project]], env=environment)
        ids = [w for w in started.stdout.split() if len(w) == 36 and w.count("-") == 4]
        return ids[0] if ids else ""

    router, user = launch("agent", "p"), launch("cat", "p")
    ids = [router, user]
    if not case.check("the Router and a user session start",
                      all(ids) and all(wait_running(home, i) for i in ids), str(ids)):
        return
    state = home.state()
    state["super_agent"] = {"session_id": router, "since": int(time.time() * 1000)}
    home.write_state(state)

    def mcp(session_id, action, args, timeout=60):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id, **TRUST_SESSION_ENV)
        started = time.monotonic()
        done = subprocess.run([BINARY, "mcp", "sessions", action, "--json", json.dumps(args)],
                              capture_output=True, text=True, timeout=timeout, env=env, cwd=CRATES)
        try:
            parsed = json.loads(done.stdout)
        except ValueError:
            parsed = {}
        return parsed, done, time.monotonic() - started

    def log_of(project):
        try:
            with open(os.path.join(folders[project], "stdin.log"), "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def router_inbox():
        listing = mcp(router, "inbox", {})[0]
        return listing.get("pending", []) + listing.get("delivered", [])

    def marker(session_id):
        return read_json(home.path("app-sessions", session_id, "supervision.json"))

    def manifest(session_id):
        return read_json(home.path("app-sessions", session_id, "manifest.json"))

    workers = []
    try:
        # 1. The Router starts a Worker in another Project, with its task.
        created, done, _ = mcp(router, "create", {
            "preset": "agent", "project_id": "q", "label": "fix login",
            "task": "login bug", "text": "Please fix the login form."})
        worker = created.get("session_id", "")
        workers.append(worker)
        case.check("the Router's create starts a Worker",
                   bool(worker) and created.get("worker") is True, (done.stdout + done.stderr)[:400])
        if not worker:
            return
        case.check("it runs in the other Project's folder",
                   created.get("cwd") == folders["q"] and manifest(worker).get("cwd") == folders["q"],
                   str(created)[:300])
        case.check("it carries a created Worker marker",
                   marker(worker).get("router_id") == router
                   and marker(worker).get("origin") == "created", str(marker(worker)))
        case.check("its task is queued in its own Inbox", bool(created.get("task_item_id")),
                   str(created)[:300])
        if not fixture_started(case, service, home.path("app-sessions", worker)):
            return
        case.check("the task is pasted into the Worker once it is idle",
                   bool(service.wait_for(lambda: "Please fix the login form." in log_of("q")
                                         and f"{HEADER}{worker}" in log_of("q"), timeout=30)),
                   log_of("q")[-400:])
        case.check("nothing of it reached the Router's own folder",
                   "Please fix the login form." not in log_of("p"), log_of("p")[-200:])

        # 2. The Worker reports back: queued for the Router, no approval.
        reported, done, took = mcp(worker, "report", {
            "session_id": router, "summary": "Login form fixed", "status": "done"}, timeout=90)
        case.check("the Worker's report reaches the Router's Inbox without an approval prompt",
                   reported.get("queued") is True and took < 20,
                   f"{took:.1f}s " + (done.stdout + done.stderr)[:300])
        case.check("the Router's Inbox holds the report",
                   any(item.get("summary") == "Login form fixed" for item in router_inbox()),
                   str(router_inbox())[:400])

        # 3. Worker cards and router_id in sessions current.
        def card():
            current = mcp(router, "current", {})[0]
            cards = [c for c in current.get("workers", []) if c.get("id") == worker]
            return current, (cards[0] if cards else {})
        current, worker_card = card()
        case.check("the Router's current shows super_agent and the Worker's card",
                   current.get("super_agent") is True and worker_card.get("project_id") == "q"
                   and worker_card.get("label") == "fix login", str(current)[-600:])
        case.check("the card carries the last report",
                   worker_card.get("last_report_status") == "done"
                   and worker_card.get("preview") == "Login form fixed", str(worker_card))
        mine = mcp(worker, "current", {})[0]
        case.check("the Worker's current names its Router", mine.get("router_id") == router,
                   str(mine)[-300:])

        # 4. The Router never waits long.
        _, done, took = mcp(router, "wait_for_text", {
            "session_id": worker, "text": "never-appears", "timeout_ms": 60000})
        case.check("a Router wait is capped at 5 s and says why",
                   done.returncode != 0 and took < 20 and "end your turn" in done.stderr,
                   f"{took:.1f}s " + done.stderr[:300])

        # 5. Stop: queued items come back, the Worker stays (stopped).
        leftover, done, _ = mcp(router, "report", {
            "session_id": worker, "summary": "also tidy the CSS", "status": "progress"})
        case.check("the Router queues a ride-along item for the Worker",
                   leftover.get("queued") is True, (done.stdout + done.stderr)[:300])
        stopped, done, _ = mcp(router, "stop", {"session_id": worker})
        case.check("sessions stop stops the Worker and returns its queue",
                   stopped.get("stopped") is True and stopped.get("returned_items") == 1,
                   (done.stdout + done.stderr)[:300])
        case.check("the stopped Worker's row stays (exited, marker kept)",
                   bool(service.wait_for(lambda: manifest(worker).get("state") == "exited",
                                         timeout=15))
                   and marker(worker).get("router_id") == router, str(manifest(worker).get("state")))
        case.check("the returned item is back in the Router's Inbox",
                   any(item.get("summary") == "also tidy the CSS" for item in router_inbox()),
                   str(router_inbox())[:400])
        refused = mcp(router, "stop", {"session_id": user})[1]
        case.check("sessions stop refuses the user's session",
                   refused.returncode != 0 and "not one of your Workers" in refused.stderr,
                   refused.stderr[:300])

        # 6. Close: only the Router's own Workers, by marker alone.
        refused = mcp(router, "close", {"session_id": user})[1]
        case.check("close refuses the user's session",
                   refused.returncode != 0 and "not one of your Workers" in refused.stderr,
                   refused.stderr[:300])
        second = mcp(router, "create", {"preset": "cat", "project_id": "q"})[0].get("session_id", "")
        workers.append(second)
        os.remove(home.path("app-sessions", second, "supervision.json"))
        refused = mcp(router, "close", {"session_id": second})[1]
        case.check("a Worker without its marker is not the Router's to close, though it spawned it",
                   bool(second) and refused.returncode != 0
                   and "not one of your Workers" in refused.stderr, refused.stderr[:300])
        closed = mcp(router, "close", {"session_id": worker})[1]
        case.check("close removes the Router's own Worker",
                   closed.returncode == 0 and not os.path.exists(home.path("app-sessions", worker)),
                   (closed.stdout + closed.stderr)[:300])
    finally:
        for session_id in [router, user, *workers]:
            if session_id and os.path.isdir(home.path("app-sessions", session_id)):
                try:
                    control(home, session_id, "q")
                except OSError:
                    pass
                run_cli(home, ["rm", session_id], env=environment, timeout=45)


run("super_agent_workers", body)
