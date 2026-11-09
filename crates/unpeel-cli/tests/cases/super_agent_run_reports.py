"""Fork-only: a Scheduled Task's Run reports to the Super Agent unasked (#47).

The Super Agent creates a task on an Agent Preset (a fake `claude` that
reports idle over OSC 7501) and starts it with `run_schedule`; its Run
Session stays live once the agent is ready. With the write policy at its default, Ask, and no Controller to
answer a prompt, the Run's `sessions report` to the Session marked Super
Agent comes back queued at once and waits in the Super Agent's Inbox
(ADR 0010). The same report from the user's own Session still waits on
the approval prompt, and nothing of it reaches the Inbox.
"""

import datetime
import json
import os
import re
import subprocess
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, TRUST_SESSION_ENV  # noqa: E402
from hook_cancellation import control, fixture_started  # noqa: E402

ZONE = "America/New_York"
SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
QUIT = "QUIT-FAKE-AGENT"

FAKE_AGENT = r'''
import os, termios, tty
tty.setraw(0, termios.TCSANOW)
os.write(1, b"\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\r\n> ")
os.write(1, b"\x1b]7501;state=idle:app=fake\x1b\\")
while True:
    data = os.read(0, 4096)
    if not data or data == %(quit)r.encode():
        break
'''


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


def detail(result):
    return (result.stderr or result.stdout)[-500:]


def write_fake(home):
    folder = home.path("agents")
    os.makedirs(folder, exist_ok=True)
    # Named `claude`, so its preset is an Agent Preset.
    path = os.path.join(folder, "claude")
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_AGENT % {"quit": QUIT})
    os.chmod(path, 0o755)
    return path


def tomorrow():
    later = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) + datetime.timedelta(days=1)
    return later.strftime("%Y-%m-%dT%H:%M")


def launch(case, home, label):
    launched = cli(home, "new", "--preset", "cat", "--project", "p")
    ids = SESSION_ID.findall(launched.stdout)
    case.check(f"{label} starts", launched.returncode == 0 and bool(ids), detail(launched))
    return ids[0] if ids else ""


def run_entry(home, task_id, run_id):
    try:
        entries = json.loads(cli(home, "schedules", "history", task_id, "--json").stdout)
    except ValueError:
        return {}
    return next((entry for entry in entries if entry.get("run_id") == run_id), {})


def as_json(result):
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {}


def start_run(case, service, home, router):
    """The Super Agent's task on the Agent Preset, run now; the Run's live Session id."""
    def workspace(*words):
        return cli(home, "mcp", "workspace", *words, env={"UNPEEL_SESSION_ID": router})

    trigger = json.dumps({"kind": "once", "at": tomorrow()})
    created = workspace("create_schedule", "name=Watch", "project_id=p", "preset=agent",
                        f"trigger={trigger}")
    task_id = (as_json(created).get("schedule") or {}).get("id", "")
    if not case.check("the Super Agent creates a task on the Agent Preset",
                      created.returncode == 0 and task_id.startswith("sch_"), detail(created)):
        return ""
    started = workspace("run_schedule", f"schedule_id={task_id}")
    run_id = as_json(started).get("runID", "")
    if not case.check("run_schedule starts a Run",
                      started.returncode == 0 and run_id.startswith("run_"), detail(started)):
        return ""
    done = service.wait_for(lambda: run_entry(home, task_id, run_id).get("status") == "done"
                            and run_entry(home, task_id, run_id), timeout=45)
    entry = done or run_entry(home, task_id, run_id)
    session_id = entry.get("session_id") or ""
    case.check("the Run is done once its agent is ready, its Session live",
               bool(session_id) and home.manifests().get(session_id, {}).get("state") == "running",
               json.dumps(entry))
    if session_id:
        case.check("the Run Session is stamped with its task",
                   home.manifests()[session_id]["session"].get("spawned_by") == f"schedule:{task_id}",
                   json.dumps(home.manifests()[session_id]["session"]))
        fixture_started(case, service, home.path("app-sessions", session_id))
    return session_id


def mcp(home, session_id, action, args, timeout):
    env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id, **TRUST_SESSION_ENV)
    started = time.monotonic()
    done = subprocess.run([BINARY, "mcp", "sessions", action, "--json", json.dumps(args)],
                          capture_output=True, text=True, timeout=timeout, env=env, cwd=CRATES)
    try:
        parsed = json.loads(done.stdout)
    except ValueError:
        parsed = {}
    return parsed, done, time.monotonic() - started


def router_inbox(home, router):
    listing = mcp(home, router, "inbox", {}, timeout=30)[0]
    return listing.get("pending", []) + listing.get("delivered", [])


def check_run_report(case, home, router, run_session):
    try:
        reported, done, took = mcp(home, run_session, "report", {
            "session_id": router, "summary": "No new upstream commits", "status": "done"},
            timeout=30)
        output = f"{took:.1f}s " + (done.stdout + done.stderr)[:300]
    except subprocess.TimeoutExpired:
        reported, took, output = {}, 30.0, "still waiting after 30 s (an approval prompt?)"
    case.check("the Run's report reaches the Super Agent's Inbox without an approval prompt",
               reported.get("queued") is True and took < 20, output)
    items = [item for item in router_inbox(home, router)
             if item.get("summary") == "No new upstream commits"]
    case.check("the Super Agent's Inbox holds it, from the Run Session, as a report",
               len(items) == 1 and items[0].get("sender") == {"session": run_session}
               and items[0].get("kind") == "report", json.dumps(items)[:400])


def check_user_still_asks(case, home, router, user):
    try:
        _, done, _ = mcp(home, user, "report", {
            "session_id": router, "summary": "From the user's Session", "status": "done"},
            timeout=8)
        waited = False
        output = (done.stdout + done.stderr)[:300]
    except subprocess.TimeoutExpired:
        waited, output = True, "still waiting after 8 s"
    case.check("the user's own Session's report still waits on the approval prompt",
               waited, output)
    case.check("and nothing of it reaches the Inbox",
               not any(item.get("summary") == "From the user's Session"
                       for item in router_inbox(home, router)), str(router_inbox(home, router))[:400])


def body(case):
    home = case.home
    home.project("p", "runs", home.root)
    home.preset(label="cat", command="cat", preset_id="cat")
    home.preset(label="agent", command=write_fake(home), preset_id="agent")
    environment = {"HOME": home.root, "SHELL": "/bin/bash", "TZ": ZONE}
    service = case.serve(env=environment)
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    try:
        router, user = launch(case, home, "the Super Agent"), launch(case, home, "a user Session")
        if not (router and user):
            return
        state = home.state()
        state["super_agent"] = {"session_id": router, "since": int(time.time() * 1000)}
        home.write_state(state)
        case.check("the write policy is at its default, Ask",
                   home.state().get("mcp_nonchild_write_access") in (None, "ask"),
                   str(home.state().get("mcp_nonchild_write_access")))
        run_session = start_run(case, service, home, router)
        if not run_session:
            return
        check_run_report(case, home, router, run_session)
        check_user_still_asks(case, home, router, user)
    finally:
        for session_id in list(home.manifests()):
            try:
                control(home, session_id, QUIT)
            except OSError:
                pass
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("super_agent_run_reports", body)
