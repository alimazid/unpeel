"""Scheduled Tasks on script presets, end to end through `unpeel serve`.

A task is created with `unpeel schedules add`; the Host fires it from its
own tick with no app present, starts a Session from the preset exactly as
typed (spawned_by `schedule:<id>`, `UNPEEL_SCHEDULE_ID` and
`UNPEEL_SCHEDULE_RUN_ID` in its environment) and records the Run from the
command's exit status. Covered: Run now records done (exit 0), failed with
the code (exit 3), and failed with a reason when the Session ends without
an exit record (a bare `exit 4`); a Once task a few seconds ahead fires on
its own, on time, and disables itself; an occurrence during a Run in
progress is skipped and Run now is refused; deleting a task leaves its Run
Sessions; and every mutating verb refuses inside a Session.
"""

import datetime
import json
import os
import re
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402

ZONE = "America/New_York"
SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")


def local_now():
    return datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)).replace(microsecond=0)


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


def add(case, home, name, preset, *trigger):
    added = cli(home, "schedules", "add", name, "--project", "p", "--preset", preset, *trigger)
    task_id = added.stdout.strip()
    case.check(f"{name}: add prints the task id",
               added.returncode == 0 and task_id.startswith("sch_"), added.stderr)
    return task_id


def history(home, task_id):
    shown = cli(home, "schedules", "history", task_id, "--json")
    try:
        return json.loads(shown.stdout)
    except ValueError:
        return []


def run_by_id(home, task_id, run_id):
    return next((entry for entry in history(home, task_id) if entry.get("run_id") == run_id), {})


def wait_for_run(service, home, task_id, run_id, statuses, timeout=45):
    return service.wait_for(
        lambda: run_by_id(home, task_id, run_id).get("status") in statuses and run_by_id(home, task_id, run_id),
        timeout=timeout,
    ) or run_by_id(home, task_id, run_id)


def stored(moment):
    """A local date-time as the Host stores it: seconds only when not zero."""
    text = moment.strftime("%Y-%m-%dT%H:%M:%S")
    return text[:-3] if text.endswith(":00") else text


def tomorrow():
    return (local_now() + datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M")


def check_run_now(case, service, home):
    for name, preset, status, code in (("Clean", "ok", "done", 0), ("Three", "three", "failed", 3)):
        task_id = add(case, home, name, preset, "--once", tomorrow())
        started = cli(home, "schedules", "run", task_id)
        run_id = started.stdout.strip()
        case.check(f"{name}: Run now answers with a Run id",
                   started.returncode == 0 and run_id.startswith("run_"), started.stderr)
        finished = wait_for_run(service, home, task_id, run_id, ("done", "failed"))
        case.check(f"{name}: the Run is recorded {status} with exit code {code}",
                   finished.get("status") == status and finished.get("exit_code") == code,
                   json.dumps(finished))
        case.check(f"{name}: a Run now Run has no occurrence and is not late",
                   finished.get("scheduled_for") is None and finished.get("late") is False,
                   json.dumps(finished))
        manifest = home.manifests().get(finished.get("session_id") or "", {})
        case.check(f"{name}: its Session was spawned by the task from the preset",
                   manifest.get("session", {}).get("spawned_by") == f"schedule:{task_id}"
                   and manifest.get("session", {}).get("source_preset_id") == preset,
                   json.dumps(manifest.get("session", {}))[:300])

    task_id = add(case, home, "Bare exit", "bare", "--once", tomorrow())
    run_id = cli(home, "schedules", "run", task_id).stdout.strip()
    ended = wait_for_run(service, home, task_id, run_id, ("done", "failed"))
    case.check("a Session that ends without an exit record fails the Run with a reason",
               ended.get("status") == "failed" and ended.get("exit_code") is None
               and "ended before" in (ended.get("reason") or ""), json.dumps(ended))


def check_once_fires(case, service, home):
    at = local_now() + datetime.timedelta(seconds=8)
    task_id = add(case, home, "Soon", "env", "--once", at.strftime("%Y-%m-%dT%H:%M:%S"))
    fired = service.wait_for(
        lambda: [entry for entry in history(home, task_id) if entry.get("status") == "done"],
        timeout=45,
    )
    case.check("a Once task fires on its own with the app absent", bool(fired),
               json.dumps(history(home, task_id)))
    if not fired:
        return
    entry = fired[0]
    case.check("it ran for its occurrence, on time",
               entry.get("scheduled_for") == stored(at) and entry.get("late") is False,
               json.dumps(entry))
    started_at = datetime.datetime.fromtimestamp(entry.get("started_at_ms", 0) / 1000,
                                                 zoneinfo.ZoneInfo(ZONE))
    case.check("it started at its time, not before",
               at <= started_at <= at + datetime.timedelta(seconds=10),
               f"{started_at.isoformat()} vs {at.isoformat()}")
    try:
        with open(home.path("env-seen")) as handle:
            seen = handle.read()
    except OSError:
        seen = ""
    case.check("the Run's Session names its task and Run in its environment",
               seen == f"{task_id} {entry.get('run_id')}", repr(seen))
    task = next((t for t in home.state().get("schedules", []) if t.get("id") == task_id), {})
    case.check("the Once task disabled itself and keeps its history",
               task.get("enabled") is False and len(history(home, task_id)) == 1, json.dumps(task))
    service.read_for(2)
    case.check("it never fires again", len(history(home, task_id)) == 1,
               json.dumps(history(home, task_id)))


def check_overlap(case, service, home):
    due = local_now() + datetime.timedelta(seconds=8)
    task_id = add(case, home, "Overlap", "slow", "--daily", due.strftime("%H:%M:%S"))
    run_id = cli(home, "schedules", "run", task_id).stdout.strip()
    running = wait_for_run(service, home, task_id, run_id, ("running",))
    live = service.wait_for(
        lambda: home.manifests().get(running.get("session_id") or "", {}).get("state") == "running",
        timeout=30,
    )
    case.check("Run now starts a Run that keeps running", bool(live), json.dumps(running))
    refused = cli(home, "schedules", "run", task_id)
    case.check("Run now is refused while a Run is in progress",
               refused.returncode != 0 and "in progress" in refused.stderr, refused.stderr)
    skipped = service.wait_for(
        lambda: [entry for entry in history(home, task_id) if entry.get("status") == "skipped"],
        timeout=45,
    )
    case.check("an occurrence during the Run is recorded skipped", bool(skipped),
               json.dumps(history(home, task_id)))
    if skipped:
        case.check("the skipped Run names its occurrence and starts no Session",
                   skipped[0].get("scheduled_for") == stored(due)
                   and skipped[0].get("session_id") is None
                   and "in progress" in (skipped[0].get("reason") or ""),
                   json.dumps(skipped[0]))
    case.check("the first Run is still running",
               run_by_id(home, task_id, run_id).get("status") == "running",
               json.dumps(run_by_id(home, task_id, run_id)))

    session_id = running.get("session_id")
    removed = cli(home, "schedules", "rm", task_id)
    case.check("rm deletes the task", removed.returncode == 0
               and all(t.get("id") != task_id for t in home.state().get("schedules", [])),
               removed.stderr)
    case.check("rm leaves the task's Run Session in place",
               home.manifests().get(session_id or "", {}).get("state") == "running")


def check_inside_session(case, home):
    task_id = add(case, home, "Guarded", "ok", "--once", tomorrow())
    launched = cli(home, "new", "--preset", "ok", "--project", "p")
    ids = SESSION_ID.findall(launched.stdout)
    if not case.check("a Session to run the CLI from", launched.returncode == 0 and bool(ids),
                      launched.stderr):
        return
    inside = {"UNPEEL_SESSION_ID": ids[0]}
    for verb in (["add", "Agent's", "--project", "p", "--preset", "ok", "--daily", "09:00"],
                 ["run", task_id], ["rm", task_id]):
        refused = cli(home, "schedules", *verb, env=inside)
        case.check(f"schedules {verb[0]} is refused inside a Session",
                   refused.returncode != 0 and "inside a Session" in refused.stderr,
                   refused.stderr or refused.stdout)
    case.check("nothing changed", [t.get("id") for t in home.state().get("schedules", [])
                                   if t.get("name") in ("Guarded", "Agent's")] == [task_id])
    case.check("schedules list still reads inside a Session",
               cli(home, "schedules", "list", env=inside).returncode == 0)
    case.check("schedules history still reads inside a Session",
               cli(home, "schedules", "history", task_id, env=inside).returncode == 0)


def body(case):
    home = case.home
    home.project("p", "sched", home.root)
    env_seen = home.path("env-seen")
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="three", command="/bin/sh -c 'exit 3'", preset_id="three")
    home.preset(label="bare", command="exit 4", preset_id="bare")
    home.preset(label="slow", command="sleep 60", preset_id="slow")
    home.preset(
        label="env",
        command=f"printf '%s %s' \"$UNPEEL_SCHEDULE_ID\" \"$UNPEEL_SCHEDULE_RUN_ID\" > {env_seen}",
        preset_id="env",
    )
    service = case.serve(env={"TZ": ZONE})
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    try:
        check_run_now(case, service, home)
        check_once_fires(case, service, home)
        check_overlap(case, service, home)
        check_inside_session(case, home)
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules", body)
