"""Run Sessions after a Run, end to end through `unpeel serve`.

A Project already holds five of the user's own stopped Sessions (the
default stopped window is five). One script task then runs seven times via
Run now. Covered: starting each Run stops the previous Run's idle Session,
which stays a stopped row; the latest Run's Session stays live; Run
Sessions never push the user's stopped Sessions out of the Project; the
task keeps its newest five stopped Run Sessions and the oldest is removed,
directory and kept output with it;
and deleting the task leaves its Run Sessions where retention put them.
Every finished Run is unread (no one looks at them here), and that never
exempts a Run from its task's keep limit.
"""

import datetime
import json
import os
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402

ZONE = "America/New_York"
USER_SESSIONS = [f"user-stopped-{n}" for n in range(1, 6)]
RUNS = 7
KEPT_STOPPED_RUNS = 5


def cli(home, *args):
    return run_cli(home, list(args), env={"TZ": ZONE}, timeout=45)


def tomorrow():
    later = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) + datetime.timedelta(days=1)
    return later.strftime("%Y-%m-%dT%H:%M")


def run_entry(home, task_id, run_id):
    shown = cli(home, "schedules", "history", task_id, "--json")
    try:
        entries = json.loads(shown.stdout)
    except ValueError:
        return {}
    return next((entry for entry in entries if entry.get("run_id") == run_id), {})


def state_of(home, session_id):
    return home.manifests().get(session_id or "", {}).get("state")


def run_once(case, service, home, task_id, number):
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    if not case.check(f"Run {number}: Run now is accepted",
                      started.returncode == 0 and run_id.startswith("run_"), started.stderr):
        return None
    done = service.wait_for(
        lambda: run_entry(home, task_id, run_id).get("status") == "done"
        and run_entry(home, task_id, run_id),
        timeout=45,
    ) or run_entry(home, task_id, run_id)
    case.check(f"Run {number}: recorded done", done.get("status") == "done", json.dumps(done))
    return done.get("session_id")


def seed_user_sessions(home):
    """Five stopped Sessions of the user's own, older than every Run."""
    created = int(time.time() * 1000) - 3_600_000
    for offset, session_id in enumerate(USER_SESSIONS):
        home.session(session_id, label=session_id, command="true", project_id="p",
                     created_at=created + offset * 1000)


def check_runs(case, service, home, task_id):
    sessions = []
    for number in range(1, RUNS + 1):
        session_id = run_once(case, service, home, task_id, number)
        if session_id is None:
            return sessions
        if sessions:
            previous = sessions[-1]
            stopped = service.wait_for(lambda: state_of(home, previous) == "exited", timeout=30)
            case.check(f"Run {number}: starting it stopped Run {number - 1}'s idle Session",
                       bool(stopped), f"{previous}: {state_of(home, previous)}")
        sessions.append(session_id)
    return sessions


def check_retention(case, service, home, sessions):
    oldest, stopped, latest = sessions[0], sessions[1:-1], sessions[-1]
    removed = service.wait_for(lambda: oldest not in home.manifests(), timeout=30)
    case.check("the task's oldest stopped Run Session is removed past its five",
               bool(removed), f"{oldest}: {state_of(home, oldest)}")
    # A stopped Run keeps its output (ADR 0006) only until it is removed.
    directory = home.path("app-sessions", oldest)
    gone = service.wait_for(lambda: not os.path.exists(directory), timeout=10)
    case.check("its directory goes with it, kept output included", bool(gone),
               str(os.listdir(directory)) if os.path.isdir(directory) else "")
    case.check(f"the task keeps its newest {KEPT_STOPPED_RUNS} stopped Run Sessions",
               len(stopped) == KEPT_STOPPED_RUNS
               and all(state_of(home, session_id) == "exited" for session_id in stopped),
               json.dumps({session_id: state_of(home, session_id) for session_id in stopped}))
    case.check("the latest Run's Session stays live", state_of(home, latest) == "running",
               f"{latest}: {state_of(home, latest)}")
    case.check("the user's five stopped Sessions are all still there",
               all(state_of(home, session_id) == "exited" for session_id in USER_SESSIONS),
               json.dumps({session_id: state_of(home, session_id) for session_id in USER_SESSIONS}))


def check_delete(case, service, home, task_id, sessions):
    removed = cli(home, "schedules", "rm", task_id)
    case.check("rm deletes the task", removed.returncode == 0, removed.stderr)
    service.read_for(3)
    kept = sessions[1:]
    case.check("deleting the task leaves its Run Sessions to retention",
               all(session_id in home.manifests() for session_id in kept)
               and state_of(home, sessions[-1]) == "running",
               json.dumps({session_id: state_of(home, session_id) for session_id in kept}))
    case.check("and the user's stopped Sessions with them",
               all(session_id in home.manifests() for session_id in USER_SESSIONS))


def body(case):
    home = case.home
    home.project("p", "retain", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    seed_user_sessions(home)
    service = case.serve(env={"TZ": ZONE})
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    try:
        added = cli(home, "schedules", "add", "Nightly", "--project", "p", "--preset", "ok",
                    "--once", tomorrow())
        task_id = added.stdout.strip()
        if not case.check("add prints the task id",
                          added.returncode == 0 and task_id.startswith("sch_"), added.stderr):
            return
        sessions = check_runs(case, service, home, task_id)
        if not case.check(f"all {RUNS} Runs started a Session", len(sessions) == RUNS,
                          json.dumps(sessions)):
            return
        check_retention(case, service, home, sessions)
        check_delete(case, service, home, task_id, sessions)
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_retention", body)
