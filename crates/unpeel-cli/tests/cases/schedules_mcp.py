"""Scheduled Tasks over the `unpeel` MCP `workspace` tool, read-only.

From inside a Session (`unpeel mcp`, the same dispatcher an agent's MCP
server runs), `schedules_list` shows the task with its next run and last
Run and `schedule_runs` reads its Runs newest first, both from the files
the Host publishes on disk. Help documents both; there is no write action,
`unpeel schedules add` still refuses inside a Session, and even under the
Create & remove role an agent cannot close the task's Run Session (the
`spawned_by` rule: it was not created by the caller).
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402

ZONE = "America/New_York"
SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
RUN_KEYS = {"runID", "scheduledFor", "startedAtMs", "endedAtMs", "status", "late",
            "sessionID", "exitCode", "reason", "snippet"}


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


def as_json(result):
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None


def history(home, task_id):
    return as_json(cli(home, "schedules", "history", task_id, "--json")) or []


def run_now_done(case, service, home, task_id):
    """Run now, waiting for the Run to finish; its history entry."""
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    case.check("Run now answers with a Run id", started.returncode == 0 and run_id.startswith("run_"),
               started.stderr)
    entry = lambda: next((e for e in history(home, task_id) if e.get("run_id") == run_id), {})
    return service.wait_for(lambda: entry().get("status") == "done" and entry(), timeout=45) or entry()


def check_list(case, service, home, task_id, inside, last_run_id):
    def listed():
        answer = as_json(cli(home, "mcp", "workspace", "schedules_list", env=inside)) or {}
        return next((t for t in answer.get("schedules", []) if t.get("id") == task_id), {})

    task = service.wait_for(lambda: listed().get("nextRun") and listed(), timeout=30) or listed()
    case.check("schedules_list shows the task's definition",
               task.get("name") == "Briefing" and task.get("projectID") == "p"
               and task.get("presetID") == "ok" and task.get("enabled") is True
               and task.get("trigger") == {"kind": "daily", "time": "09:30"}, json.dumps(task))
    next_run = task.get("nextRun") or {}
    case.check("schedules_list shows the next run the Host published",
               str(next_run.get("at", "")).endswith("T09:30") and isinstance(next_run.get("atMs"), int),
               json.dumps(next_run))
    last = task.get("lastRun") or {}
    case.check("schedules_list shows the last Run's status",
               last.get("runID") == last_run_id and last.get("status") == "done", json.dumps(last))


def check_runs(case, home, task_id, inside, first, second):
    answer = as_json(cli(home, "mcp", "workspace", "schedule_runs", f"schedule_id={task_id}",
                         env=inside)) or {}
    runs = answer.get("runs", [])
    case.check("schedule_runs reads the task's Runs newest first",
               answer.get("scheduleID") == task_id
               and [r.get("runID") for r in runs] == [second["run_id"], first["run_id"]],
               json.dumps(answer)[:600])
    case.check("each Run has status, times, late marker and snippet",
               all(set(r) == RUN_KEYS and r["status"] == "done" and r["exitCode"] == 0
                   and r["late"] is False and r["scheduledFor"] is None
                   and isinstance(r["startedAtMs"], int) and isinstance(r["endedAtMs"], int)
                   for r in runs), json.dumps(runs)[:600])
    case.check("a Run names its Session", bool(runs) and runs[0].get("sessionID") == second["session_id"],
               json.dumps(runs[:1]))
    limited = as_json(cli(home, "mcp", "workspace", "schedule_runs", f"schedule_id={task_id}",
                          "limit=1", env=inside)) or {}
    case.check("limit caps the Runs",
               [r.get("runID") for r in limited.get("runs", [])] == [second["run_id"]],
               json.dumps(limited)[:300])
    unknown = cli(home, "mcp", "workspace", "schedule_runs", "schedule_id=sch_nope", env=inside)
    case.check("an unknown task points at schedules_list",
               unknown.returncode != 0 and "schedules_list" in unknown.stderr, unknown.stderr)


def check_read_only(case, home, inside):
    shown = cli(home, "mcp", "workspace", "help", env=inside)
    case.check("help documents both actions",
               shown.returncode == 0 and "### schedules_list" in shown.stdout
               and "### schedule_runs" in shown.stdout, shown.stdout[-600:])
    for action in ("schedules_add", "schedule_run", "schedules_rm"):
        refused = cli(home, "mcp", "workspace", action, env=inside)
        case.check(f"there is no {action} action",
                   refused.returncode != 0 and "Unknown workspace action" in refused.stderr,
                   refused.stderr)
    added = cli(home, "schedules", "add", "Agent's", "--project", "p", "--preset", "ok",
                "--daily", "10:00", env=inside)
    case.check("schedules add still refuses inside a Session",
               added.returncode != 0 and "inside a Session" in added.stderr, added.stderr)


def check_close_refused(case, home, caller, inside, run_session):
    state = home.state()
    state.setdefault("mcp_orchestrators", {})[caller] = {"role": "manage", "reach": "project"}
    home.write_state(state)
    refused = cli(home, "mcp", "sessions", "close", f"session_id={run_session}", env=inside)
    case.check("Create & remove cannot close a Run Session",
               refused.returncode != 0 and "not created by this session" in refused.stderr,
               refused.stderr or refused.stdout)
    case.check("the Run Session is still there",
               home.manifests().get(run_session, {}).get("state") == "running")


def body(case):
    home = case.home
    home.project("p", "sched", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="cat", command="cat", preset_id="cat")
    service = case.serve(env={"TZ": ZONE})
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    try:
        added = cli(home, "schedules", "add", "Briefing", "--project", "p", "--preset", "ok",
                    "--daily", "09:30")
        task_id = added.stdout.strip()
        if not case.check("a task to read", added.returncode == 0 and task_id.startswith("sch_"),
                          added.stderr):
            return
        first = run_now_done(case, service, home, task_id)
        second = run_now_done(case, service, home, task_id)
        if not case.check("two finished Runs", first.get("status") == second.get("status") == "done",
                          json.dumps([first, second])):
            return
        launched = cli(home, "new", "--preset", "cat", "--project", "p")
        ids = SESSION_ID.findall(launched.stdout)
        if not case.check("a Session to call MCP from", launched.returncode == 0 and bool(ids),
                          launched.stderr):
            return
        caller = ids[0]
        inside = {"UNPEEL_SESSION_ID": caller}
        check_list(case, service, home, task_id, inside, second["run_id"])
        check_runs(case, home, task_id, inside, first, second)
        check_read_only(case, home, inside)
        check_close_refused(case, home, caller, inside, second["session_id"])
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)


run("schedules_mcp", body)
