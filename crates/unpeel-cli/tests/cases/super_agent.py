"""Super Agent end to end (fork-only).

One Host, the whole flow. A Session whose command is `claude` becomes the
Router through the `session.super_agent.set` Host verb and gets its
instructions pasted. It starts two Workers in two other Projects, each with
its task; while it is busy both Workers' reports queue, and they arrive as
ONE paste once it is idle. A third Worker that only its screen speaks for is
reported `finished` (screen-detected) when its turn ends, never
`went_quiet`. A Hand-over makes another agent a Worker, and its summary
reaches the Router. The Router stops a Worker and hears nothing about its
own stop. Making another Session the Router moves every Worker and what was
pending; a Router Resume keeps the Workers and the Inbox under the new id;
clear makes the Workers the user's again.

Every agent here is a fake: a 7501 program with bracketed paste that logs
its stdin to `logs/<session id>.log`, and a fake `claude` drawing Claude's
screens (no integration installed in the private HOME, so only the screen
tier speaks for it).
"""

import json
import os
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402
from host_launch_conformance import LocalHostClient  # noqa: E402

HEADER = "[unpeel inbox for id:"
INSTRUCTIONS = "You are now the Super Agent"

AGENT = '''
import base64, os, select, time, tty
tty.setraw(0)
me = os.environ.get("UNPEEL_SESSION_ID", "unknown")
log = os.path.join(LOGS, me + ".log")
def report(pairs):
    os.write(1, b"\\x1b]7501;" + pairs.encode() + b":app=e2e\\x1b\\\\")
def msg(text):
    return base64.b64encode(text.encode()).decode()
os.write(1, b"\\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\\r\\n> ")
report("state=idle")
pasted = False
phase = None
while True:
    wait = None if phase is None or phase[1] is None else max(0.0, phase[1] - time.time())
    ready, _, _ = select.select([0], [], [], wait)
    if not ready:
        if phase[0] == "working":
            report("state=done:msg=" + msg(REPLY + " " + me[:8]))
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
        phase = ("held", None)
        continue
    if data == b"i":
        report("state=idle")
        phase = None
        continue
    pasted = pasted or b"\\x1b[200~" in data
    if pasted and b"\\r" in data:
        pasted = False
        report("state=working")
        phase = ("working", time.time() + 1.5)
'''

SCREEN = '''
import os, tty
tty.setraw(0)
def screen(text):
    print("\\x1b[2J\\x1b[H" + text.replace("\\n", "\\r\\n"), end="", flush=True)
IDLE = "Claude Code\\n\\n✻ Brewed for 12s · done\\n────\\n❯\\n────\\n  ⏵⏵ auto mode on"
print("HOOK_FIXTURE_PROCESS_STARTED", flush=True)
screen(IDLE)
while True:
    data = os.read(0, 4096)
    if not data or data == b"q":
        break
    if data == b"w":
        screen("Claude Code\\n\\n✽ Thinking… (2s · esc to interrupt)\\n────\\n❯\\n────\\n  ⏵⏵ auto mode on")
    elif data == b"d":
        screen(IDLE)
'''


def write_program(path, source, **constants):
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n")
        for name, value in constants.items():
            handle.write(f"{name} = {value!r}\n")
        handle.write(source)
    os.chmod(path, 0o755)


def body(case):
    home = case.home
    folders = {name: home.path(name) for name in ("p", "q", "r")}
    for folder in folders.values():
        os.makedirs(folder)
    home.project("p", "Router's", folders["p"])
    home.project("q", "Queue", folders["q"])
    home.project("r", "Reports", folders["r"])
    logs = home.path("logs")
    for folder in (logs, home.path("bin"), home.path("screen")):
        os.makedirs(folder, exist_ok=True)
    # The command head names the runtime: `claude` is Claude Code.
    write_program(home.path("bin", "claude"), AGENT, LOGS=logs, REPLY="ROUTER-TURN")
    write_program(home.path("bin", "worker-agent"), AGENT, LOGS=logs, REPLY="WORKER-REPLY")
    write_program(home.path("screen", "claude"), SCREEN)
    home.preset(label="claude", command=shlex.quote(home.path("bin", "claude")), preset_id="claude")
    home.preset(label="worker", command=shlex.quote(home.path("bin", "worker-agent")),
                preset_id="worker")
    home.preset(label="screen", command=shlex.quote(home.path("screen", "claude")),
                preset_id="screen")
    environment = {"HOME": home.root, "SHELL": "/bin/bash"}

    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=25)), service.log()):
        return
    client = case.track(LocalHostClient(service.status().get("localSocket", "")))
    calls = iter(range(1, 1_000_000))
    sessions = []

    def launch(project="p"):
        started = run_cli(home, ["new", "--preset", "claude", "--project", project,
                                 "--cwd", folders[project]], env=environment)
        ids = [w for w in started.stdout.split() if len(w) == 36 and w.count("-") == 4]
        sessions.extend(ids[:1])
        return ids[0] if ids else ""

    def verb(name, session_id):
        return client.call(next(calls), "POST", f"/mobile/super-agent/{name}",
                           body={"sessionID": session_id})

    def summaries():
        status, boot = client.call(next(calls), "GET", "/mobile/bootstrap")
        return {item.get("id"): item for item in boot.get("sessions", [])} if status == 200 else {}

    def mcp(session_id, action, args, domain="sessions", timeout=60):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id)
        started = time.monotonic()
        done = subprocess.run([BINARY, "mcp", domain, action, "--json", json.dumps(args)],
                              capture_output=True, text=True, timeout=timeout, env=env, cwd=CRATES)
        try:
            parsed = json.loads(done.stdout)
        except ValueError:
            parsed = {}
        return parsed, done, time.monotonic() - started

    def log_of(session_id):
        try:
            with open(os.path.join(logs, session_id + ".log"), "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def inbox(session_id):
        listing = mcp(session_id, "inbox", {})[0]
        return listing.get("pending", []), listing.get("delivered", [])

    def items(session_id):
        pending, delivered = inbox(session_id)
        return pending + delivered

    def router_of(session_id):
        return read_json(home.path("app-sessions", session_id, "supervision.json")).get("router_id")

    def mark():
        return (home.state().get("super_agent") or {}).get("session_id")

    def settled(session_id):
        """Its Inbox is empty and it is idle again after taking the last paste."""
        return lambda: inbox(session_id)[0] == [] and read_json(
            home.path("activity-state.json")).get("sessions", {}).get(session_id, {}).get(
                "raw_status") == "idle"

    try:
        router, helper, successor = launch(), launch(), launch()
        if not case.check("three claude sessions start",
                          all(sessions) and len(sessions) == 3
                          and all(wait_running(home, i) for i in sessions), str(sessions)):
            return
        for session_id in sessions:
            if not fixture_started(case, service, home.path("app-sessions", session_id)):
                return

        # 1. The Host verb makes the Router; its instructions are pasted.
        status, made = verb("set", router)
        case.check("session.super_agent.set makes the Router",
                   status == 200 and made.get("changed") is True and mark() == router,
                   f"{status} {made}")
        case.check("the Router's instructions are pasted once it is idle",
                   bool(service.wait_for(lambda: INSTRUCTIONS in log_of(router)
                                         and "unpeel/router" in log_of(router), timeout=30)),
                   log_of(router)[-400:])
        case.check("the bootstrap names the Super Agent",
                   summaries().get(router, {}).get("superAgent") is True
                   and summaries().get(helper, {}).get("superAgent") is False)
        service.wait_for(settled(router), timeout=20)

        # 2. Busy Router; two Workers in two Projects, each with its task.
        control(home, router, "w")
        workers = {}
        for project in ("q", "r"):
            created, done, _ = mcp(router, "create", {
                "preset": "worker", "project_id": project, "label": f"task {project}",
                "text": f"Please do the {project} task."})
            workers[project] = created.get("session_id", "")
            sessions.append(workers[project])
            case.check(f"the Router starts a Worker in Project {project}",
                       created.get("worker") is True and created.get("cwd") == folders[project]
                       and router_of(workers[project]) == router,
                       (done.stdout + done.stderr)[:400])
        wq, wr = workers["q"], workers["r"]
        if not (wq and wr):
            return
        for worker in (wq, wr):
            if not fixture_started(case, service, home.path("app-sessions", worker)):
                return
        case.check("each Worker's task is pasted into it, and only into it",
                   bool(service.wait_for(lambda: "the q task" in log_of(wq)
                                         and "the r task" in log_of(wr), timeout=30))
                   and "the r task" not in log_of(wq), log_of(wq)[-200:] + log_of(wr)[-200:])
        case.check("the bootstrap names each Worker's Router",
                   all(summaries().get(w, {}).get("superAgentRouterID") == router
                       for w in (wq, wr)))

        # 3. Both Workers finish and report while the Router is busy.
        case.check("both Workers' finished turns reach the busy Router's Inbox",
                   bool(service.wait_for(lambda: {i.get("about") for i in inbox(router)[0]
                                                  if i.get("status") == "finished"} == {wq, wr},
                                         timeout=30)), str(inbox(router)[0])[:600])
        before = len(log_of(router))
        for worker, text in ((wq, "Q REPORT queue drained"), (wr, "R REPORT numbers added")):
            reported, done, took = mcp(worker, "report", {
                "session_id": router, "summary": text, "status": "done"}, timeout=90)
            case.check(f"{text.split()[0]} reaches the Router's Inbox with no approval prompt",
                       reported.get("queued") is True and took < 20,
                       f"{took:.1f}s " + (done.stdout + done.stderr)[:300])
        service.read_for(3)
        case.check("nothing is pasted while the Router is busy",
                   HEADER not in log_of(router)[before:], log_of(router)[before:][-300:])
        control(home, router, "i")
        case.check("the Router gets the reports once it is idle",
                   bool(service.wait_for(lambda: "R REPORT" in log_of(router)[before:], timeout=30)),
                   log_of(router)[before:][-600:])
        batch = log_of(router)[before:]
        case.check("exactly one paste carries both reports, in order, with the finished notices",
                   batch.count(HEADER) == 1
                   and 0 <= batch.find("Q REPORT") < batch.find("R REPORT")
                   and batch.count("WORKER-REPLY") == 2, batch[-900:])
        case.check("the batch is confirmed", bool(service.wait_for(settled(router), timeout=30)),
                   str(inbox(router)[0])[:300])

        # 4. A Worker only its screen speaks for: finished, never went_quiet.
        created, done, _ = mcp(router, "create", {
            "preset": "screen", "project_id": "q", "label": "screen task"})
        screen = created.get("session_id", "")
        sessions.append(screen)
        if not case.check("the Router starts a screen-only Worker", bool(screen),
                          (done.stdout + done.stderr)[:300]):
            return
        if not fixture_started(case, service, home.path("app-sessions", screen)):
            return

        def screen_activity():
            return read_json(home.path("activity-state.json")).get("sessions", {}).get(screen, {})

        case.check("the screen tier says the Worker is idle",
                   bool(service.wait_for(lambda: screen_activity().get("raw_status") == "idle"
                                         and screen_activity().get("activity_source") == "screen",
                                         timeout=20)), str(screen_activity()))
        before = len(log_of(router))
        control(home, screen, "w")
        case.check("the screen tier sees its turn",
                   bool(service.wait_for(lambda: screen_activity().get("raw_status") == "busy",
                                         timeout=15)), str(screen_activity()))
        control(home, screen, "d")
        case.check("the end of its turn reaches the Router as a screen-detected finish",
                   bool(service.wait_for(lambda: "\"screen task\" finished (screen-detected"
                                         in log_of(router)[before:], timeout=40)),
                   log_of(router)[before:][-600:])
        about_screen = [i for i in items(router) if i.get("about") == screen]
        case.check("it is one finished notice, never went_quiet",
                   [i.get("status") for i in about_screen] == ["finished"], str(about_screen))
        service.wait_for(settled(router), timeout=30)

        # 5. Hand-over: another agent becomes a Worker and briefs the Router.
        status, handed = verb("hand-over", helper)
        case.check("session.super_agent.hand_over makes the helper a Worker",
                   status == 200 and handed.get("changed") is True and router_of(helper) == router
                   and read_json(home.path("app-sessions", helper, "supervision.json"))
                   .get("origin") == "handed_over", f"{status} {handed}")
        case.check("the helper is asked for its summary",
                   bool(service.wait_for(lambda: "summarise this conversation" in log_of(helper)
                                         and f"session_id={router}" in log_of(helper),
                                         timeout=30)), log_of(helper)[-400:])
        before = len(log_of(router))
        reported, done, _ = mcp(helper, "report", {
            "session_id": router, "status": "done", "summary": "HANDOVER SUMMARY of the helper",
            "details": "It was halfway through the docs."})
        case.check("the helper's summary is queued for the Router", reported.get("queued") is True,
                   (done.stdout + done.stderr)[:300])
        case.check("the summary is pasted into the Router",
                   bool(service.wait_for(lambda: "HANDOVER SUMMARY" in log_of(router)[before:],
                                         timeout=40)), log_of(router)[before:][-600:])
        case.check("it is the helper's hand-over item",
                   any(i.get("kind") == "handover" and i.get("sender") == {"session": helper}
                       for i in items(router)), str(items(router))[:600])
        service.wait_for(settled(router), timeout=30)

        # 6. The Router stops a Worker: stopped, kept, and no notice about it.
        stopped, done, _ = mcp(router, "stop", {"session_id": wq})
        case.check("sessions stop stops the Worker", stopped.get("stopped") is True,
                   (done.stdout + done.stderr)[:300])
        case.check("the stopped Worker stays, still the Router's",
                   bool(service.wait_for(lambda: read_json(home.path(
                       "app-sessions", wq, "manifest.json")).get("state") == "exited", timeout=15))
                   and router_of(wq) == router)
        service.read_for(6)
        case.check("the Router hears nothing about its own stop",
                   not any(i.get("about") == wq and "exit" in (i.get("status") or "")
                           for i in items(router)), str(items(router))[:600])

        # 7. Another Session becomes the Router: Workers and pending items move.
        all_workers = [wq, wr, screen, helper]
        control(home, router, "w")
        mcp(wr, "report", {"session_id": router, "summary": "R SECOND waiting", "status": "done"})
        before = len(log_of(successor))
        status, switched = verb("set", successor)
        case.check("set on another Session moves the mark",
                   status == 200 and switched.get("changed") is True and mark() == successor,
                   f"{status} {switched}")
        case.check("every Worker, stopped ones too, now works for the new Router",
                   all(router_of(w) == successor for w in all_workers),
                   str({w: router_of(w) for w in all_workers}))
        case.check("the new Router gets its instructions, what it took over, and the pending report",
                   bool(service.wait_for(lambda: all(text in log_of(successor)[before:] for text in (
                       INSTRUCTIONS, "You took over 4 Workers", "R SECOND")), timeout=40)),
                   log_of(successor)[before:][-900:])
        old = mcp(router, "current", {})[0]
        refused = mcp(router, "stop", {"session_id": wr})[1]
        case.check("the old Router is an ordinary agent again",
                   old.get("super_agent") is not True and refused.returncode != 0
                   and summaries().get(router, {}).get("superAgent") is False,
                   str(old)[-300:] + refused.stderr[:200])
        control(home, router, "i")
        service.wait_for(settled(successor), timeout=30)

        # 8. Resume the Router: same Workers, same Inbox, under the new id.
        control(home, successor, "w")
        mcp(wr, "report", {"session_id": successor, "summary": "R THIRD across a Resume",
                           "status": "done"})
        case.check("a report waits while the Router is busy",
                   any(i.get("summary") == "R THIRD across a Resume" for i in inbox(successor)[0]))
        stopped = run_cli(home, ["stop", successor], env=environment, timeout=45)
        # Resume needs the provider's durable state, which a fake never writes.
        home.seed_resume_data(successor)
        resumed = run_cli(home, ["resume", successor], env=environment, timeout=45)
        resumed_id = resumed.stdout.strip().split()[-1] if resumed.stdout.strip() else ""
        sessions.append(resumed_id)
        if not case.check("the Router resumes under a new id",
                          stopped.returncode == 0 and resumed.returncode == 0
                          and len(resumed_id) == 36 and resumed_id != successor,
                          stopped.stderr[:200] + resumed.stdout[:200] + resumed.stderr[:200]):
            return
        case.check("the mark follows the Resume", mark() == resumed_id, str(mark()))
        case.check("every Worker follows it too",
                   all(router_of(w) == resumed_id for w in all_workers),
                   str({w: router_of(w) for w in all_workers}))
        case.check("the Inbox moved with it",
                   not os.path.exists(home.path("session-inboxes", successor))
                   and any(i.get("summary") == "R THIRD across a Resume" for i in items(resumed_id)),
                   str(items(resumed_id))[:400])
        if not (wait_running(home, resumed_id)
                and fixture_started(case, service, home.path("app-sessions", resumed_id))):
            return
        case.check("the resumed Router gets its instructions again and the waiting report",
                   bool(service.wait_for(lambda: INSTRUCTIONS in log_of(resumed_id)
                                         and "R THIRD" in log_of(resumed_id), timeout=40)),
                   log_of(resumed_id)[-600:])
        cards = {c.get("id") for c in mcp(resumed_id, "current", {})[0].get("workers", [])}
        case.check("its current lists every Worker", cards == set(all_workers), str(cards))
        closed = mcp(resumed_id, "close", {"session_id": wq})[1]
        case.check("the resumed Router may close its stopped Worker",
                   closed.returncode == 0 and not os.path.exists(home.path("app-sessions", wq)),
                   (closed.stdout + closed.stderr)[:300])
        service.wait_for(settled(resumed_id), timeout=30)

        # 9. Clear: the Workers become the user's.
        status, cleared = verb("clear", resumed_id)
        live_workers = [wr, screen, helper]
        case.check("session.super_agent.clear drops the mark",
                   status == 200 and cleared.get("changed") is True and mark() is None,
                   f"{status} {cleared}")
        case.check("no Session is a Worker any more",
                   not any(home.has_marker(w, "supervision.json") for w in live_workers)
                   and all("superAgentRouterID" not in summaries().get(w, {})
                           for w in live_workers))
        case.check("the former Router's current has no Workers",
                   "workers" not in mcp(resumed_id, "current", {})[0]
                   and "router_id" not in mcp(wr, "current", {})[0])
    finally:
        for session_id in sessions:
            if session_id and os.path.isdir(home.path("app-sessions", session_id)):
                try:
                    control(home, session_id, "q")
                except OSError:
                    pass
                run_cli(home, ["rm", session_id], env=environment, timeout=45)


run("super_agent", body)
