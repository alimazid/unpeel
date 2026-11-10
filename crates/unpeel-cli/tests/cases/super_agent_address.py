"""Fork-only: a Run reports to the Super Agent by its address (#82).

`sessions report` to `session_id: "super_agent"` reaches whichever Session
is marked Super Agent when the report is sent. With the write policy at its
default, Ask, and no Controller to answer a prompt, a Scheduled Task's live
Run reports there and is queued at once in the Super Agent's Inbox, from
the Run (ADR 0010), over MCP and through `unpeel report --to super_agent`;
`sessions list` marks the Super Agent's row. The user's own Session
reporting to the address still waits on the approval prompt, as it would
by id. After the Super Agent is resumed under a new id the same call reaches
the new one. With no Super Agent the call fails at once with a clear error.
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
from harness import BINARY, CRATES, run, run_cli, wait_running, TRUST_SESSION_ENV  # noqa: E402
from hook_cancellation import control, fixture_started  # noqa: E402

ZONE = "America/New_York"
SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
QUIT = "QUIT-FAKE-AGENT"
ADDRESS = "super_agent"

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
    # Named `claude`: its preset is an Agent Preset, and a stopped Session of
    # it resumes under a new id.
    path = os.path.join(folder, "claude")
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_AGENT % {"quit": QUIT})
    os.chmod(path, 0o755)
    return path


def tomorrow():
    later = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) + datetime.timedelta(days=1)
    return later.strftime("%Y-%m-%dT%H:%M")


def launch(case, home, preset, label):
    launched = cli(home, "new", "--preset", preset, "--project", "p")
    ids = SESSION_ID.findall(launched.stdout)
    case.check(f"{label} starts", launched.returncode == 0 and bool(ids), detail(launched))
    return ids[0] if ids else ""


def run_entry(home, task_id, run_id):
    try:
        entries = json.loads(cli(home, "schedules", "history", task_id, "--json").stdout)
    except ValueError:
        return {}
    return next((entry for entry in entries if entry.get("run_id") == run_id), {})


def start_run(case, service, home):
    """A task on the Agent Preset, run now by the user; the Run's live Session id."""
    added = cli(home, "schedules", "add", "Watch", "--project", "p", "--preset", "agent",
                "--once", tomorrow())
    task_id = added.stdout.strip()
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    if not case.check("a Run of a task on the Agent Preset starts",
                      task_id.startswith("sch_") and run_id.startswith("run_"),
                      detail(added) + detail(started)):
        return ""
    entry = service.wait_for(lambda: run_entry(home, task_id, run_id).get("status") == "done"
                             and run_entry(home, task_id, run_id), timeout=45)
    entry = entry or run_entry(home, task_id, run_id)
    session_id = entry.get("session_id") or ""
    if not case.check("the Run is done once its agent is ready, its Session live",
                      bool(session_id) and wait_running(home, session_id), json.dumps(entry)):
        return ""
    fixture_started(case, service, home.path("app-sessions", session_id))
    return session_id


def mcp(home, session_id, action, args, timeout=30):
    env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id,
               **TRUST_SESSION_ENV)
    started = time.monotonic()
    done = subprocess.run([BINARY, "mcp", "sessions", action, "--json", json.dumps(args)],
                          capture_output=True, text=True, timeout=timeout, env=env, cwd=CRATES)
    try:
        parsed = json.loads(done.stdout)
    except ValueError:
        parsed = {}
    return parsed, done, time.monotonic() - started


def report(home, caller, summary, timeout=30):
    return mcp(home, caller, "report", {"session_id": ADDRESS, "summary": summary,
                                        "status": "done"}, timeout=timeout)


def inbox_items(home, session_id, summary):
    listing = mcp(home, session_id, "inbox", {})[0]
    return [item for item in listing.get("pending", []) + listing.get("delivered", [])
            if item.get("summary") == summary]


def mark(home):
    return (home.state().get("super_agent") or {}).get("session_id")


def check_reaches(case, home, run_session, router, summary, label):
    reported, done, took = report(home, run_session, summary)
    case.check(f"{label}: the Run's report to super_agent is queued for {router[:8]} at once",
               reported.get("queued") is True and reported.get("session_id") == router
               and took < 20, f"{took:.1f}s " + (done.stdout + done.stderr)[:300])
    items = inbox_items(home, router, summary)
    case.check(f"{label}: the Super Agent's Inbox holds it, from the Run, as a report",
               len(items) == 1 and items[0].get("sender") == {"session": run_session}
               and items[0].get("kind") == "report", json.dumps(items)[:400])


def check_list_mark(case, home, caller, router):
    rows = mcp(home, caller, "list", {})[0].get("sessions", [])
    marked = [row.get("id") for row in rows if "super_agent" in row]
    case.check(f"sessions list marks only {router[:8]}, with super_agent: true",
               marked == [router] and all(row["super_agent"] is True
                                          for row in rows if "super_agent" in row),
               json.dumps([{k: row.get(k) for k in ("id", "super_agent")} for row in rows]))


def check_cli_reaches(case, home, run_session, router):
    summary = "From unpeel report"
    done = cli(home, "report", summary, "--to", ADDRESS, "--status", "done",
               env={"UNPEEL_SESSION_ID": run_session})
    case.check("unpeel report --to super_agent from the Run is queued for the Super Agent",
               done.returncode == 0 and json.loads(done.stdout or "{}").get("session_id") == router,
               detail(done))
    case.check("and the Super Agent's Inbox holds it",
               len(inbox_items(home, router, summary)) == 1)


def check_user_still_asks(case, home, user, router):
    summary = "From the user's Session"
    try:
        _, done, _ = report(home, user, summary, timeout=8)
        waited, output = False, (done.stdout + done.stderr)[:300]
    except subprocess.TimeoutExpired:
        waited, output = True, "still waiting after 8 s"
    case.check("the user's own Session's report to super_agent waits on the approval prompt",
               waited, output)
    case.check("and nothing of it reaches the Inbox", inbox_items(home, router, summary) == [])


def check_refused(case, home, run_session, label):
    reported, done, took = report(home, run_session, f"No Super Agent ({label})")
    case.check(f"{label}: a report to super_agent fails at once with a clear error",
               done.returncode != 0 and reported == {} and took < 10
               and "No Super Agent" in done.stderr and "nothing was sent" in done.stderr,
               f"{took:.1f}s rc={done.returncode} " + (done.stdout + done.stderr)[:300])


def resume(case, service, home, router):
    """Stop and resume the Super Agent; its new id once the mark follows it."""
    stopped = cli(home, "stop", router)
    home.seed_resume_data(router)
    resumed = cli(home, "resume", router)
    words = resumed.stdout.strip().split()
    resumed_id = words[-1] if words else ""
    if not case.check("the Super Agent resumes under a new id",
                      stopped.returncode == 0 and resumed.returncode == 0
                      and SESSION_ID.fullmatch(resumed_id) and resumed_id != router,
                      detail(stopped) + detail(resumed)):
        return ""
    case.check("the mark follows the Resume", mark(home) == resumed_id, str(mark(home)))
    if not wait_running(home, resumed_id):
        case.check("the resumed Super Agent runs", False)
        return ""
    fixture_started(case, service, home.path("app-sessions", resumed_id))
    return resumed_id


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
        router = launch(case, home, "agent", "the Super Agent")
        user = launch(case, home, "cat", "a user Session")
        run_session = start_run(case, service, home)
        if not (router and user and run_session):
            return
        case.check("the write policy is at its default, Ask",
                   home.state().get("mcp_nonchild_write_access") in (None, "ask"),
                   str(home.state().get("mcp_nonchild_write_access")))
        check_refused(case, home, run_session, "before any Super Agent")

        state = home.state()
        state["super_agent"] = {"session_id": router, "since": int(time.time() * 1000)}
        home.write_state(state)
        check_list_mark(case, home, run_session, router)
        check_reaches(case, home, run_session, router, "First report", "by address")
        check_cli_reaches(case, home, run_session, router)
        check_user_still_asks(case, home, user, router)

        resumed = resume(case, service, home, router)
        if not resumed:
            return
        check_reaches(case, home, run_session, resumed, "After the Resume", "after a Resume")
        check_list_mark(case, home, run_session, resumed)

        control(home, resumed, QUIT)
        removed = cli(home, "rm", resumed)
        case.check("removing the Super Agent clears the mark",
                   removed.returncode == 0 and mark(home) is None, detail(removed))
        check_refused(case, home, run_session, "after the Super Agent is removed")
    finally:
        for session_id in list(home.manifests()):
            try:
                control(home, session_id, QUIT)
            except OSError:
                pass
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("super_agent_address", body)
