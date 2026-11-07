"""Scheduled Task Triggers, edit, pause and resume, through the CLI and app-state.json.

Every Trigger kind (hourly, daily, weekdays, weekly, once, cron) is stored
in its canonical form and the Host publishes its next run; invalid cron
expressions and impossible times are refused at save time with a message
and change nothing. `edit` changes each field it names and passes fields
it does not know through; a new Trigger restarts the task's clock. `pause`
stops a task firing; `resume` restarts its clock from the resume, so an
occurrence that fell while it was paused never fires, and the task then
fires again on its own (a weekly Trigger, end to end). A Once task that
ran and paused itself still edits, its stored time sent back included; a
paused task saves a past Once as is and resumes only with a new time; an
edit that sends back the stored Trigger is not checked again, while a new
past Once on an enabled task is refused. A Project with no folder is
refused for every preset. Mutating verbs refuse inside a Session.
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
WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def local_now():
    return datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)).replace(microsecond=0)


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


def tasks(home):
    return home.state().get("schedules", [])


def task(home, task_id):
    return next((entry for entry in tasks(home) if entry.get("id") == task_id), {})


def listed(home, task_id):
    shown = cli(home, "schedules", "list", "--json")
    try:
        return next((row for row in json.loads(shown.stdout) if row.get("id") == task_id), {})
    except ValueError:
        return {}


def history(home, task_id):
    shown = cli(home, "schedules", "history", task_id, "--json")
    try:
        return json.loads(shown.stdout)
    except ValueError:
        return []


def published(home, task_id):
    try:
        with open(home.path("schedules", task_id, "clock.json")) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def add(case, home, name, *trigger, preset="ok"):
    added = cli(home, "schedules", "add", name, "--project", "p", "--preset", preset, *trigger)
    task_id = added.stdout.strip()
    case.check(f"{name}: add {' '.join(trigger)} succeeds",
               added.returncode == 0 and task_id.startswith("sch_"), added.stderr)
    return task_id


def stored(moment):
    text = moment.strftime("%Y-%m-%dT%H:%M:%S")
    return text[:-3] if text.endswith(":00") else text


def next_daily(now, hour, minute):
    candidate = now.replace(hour=hour, minute=minute, second=0)
    return candidate if candidate > now else candidate + datetime.timedelta(days=1)


def check_every_kind(case, service, home):
    now = local_now()
    tomorrow = (now + datetime.timedelta(days=1)).replace(second=0)
    kinds = [
        ("Hourly", ["--hourly", "15"], {"kind": "hourly", "minute": 15}),
        ("Daily", ["--daily", "09:00"], {"kind": "daily", "time": "09:00"}),
        ("Weekdays", ["--weekdays", "08:30:00"], {"kind": "weekdays", "time": "08:30"}),
        ("Weekly", ["--weekly", "Fri", "17:00"], {"kind": "weekly", "weekday": "friday", "time": "17:00"}),
        ("Once", ["--once", tomorrow.strftime("%Y-%m-%dT%H:%M")],
         {"kind": "once", "at": tomorrow.strftime("%Y-%m-%dT%H:%M")}),
        ("Cron", ["--cron", "*/15  9-17 * * 1-5"], {"kind": "cron", "expr": "*/15 9-17 * * 1-5"}),
    ]
    for name, flags, trigger in kinds:
        task_id = add(case, home, name, *flags)
        case.check(f"{name}: stored in its canonical form",
                   task(home, task_id).get("trigger") == trigger, json.dumps(task(home, task_id)))
        clock = service.wait_for(lambda: published(home, task_id).get("next_occurrence")
                                 and published(home, task_id), timeout=20) or {}
        case.check(f"{name}: the Host publishes its next run", bool(clock.get("next_occurrence_ms")),
                   json.dumps(clock))
        case.check(f"{name}: list shows the same next run",
                   bool(listed(home, task_id).get("next_run")), json.dumps(listed(home, task_id)))
        if name == "Daily":
            expected = stored(next_daily(local_now(), 9, 0))
            case.check("Daily: its next run is the next 09:00", clock.get("next_occurrence") == expected,
                       f"{clock.get('next_occurrence')} vs {expected}")
        if name == "Cron":
            due = datetime.datetime.fromtimestamp(clock.get("next_occurrence_ms", 0) / 1000,
                                                  zoneinfo.ZoneInfo(ZONE))
            case.check("Cron: its next run is a weekday quarter hour in office hours",
                       due.minute % 15 == 0 and 9 <= due.hour <= 17 and due.weekday() < 5
                       and due > now, due.isoformat())
        cli(home, "schedules", "rm", task_id)


def check_refusals(case, home):
    before = json.dumps(tasks(home), sort_keys=True)
    for flags, phrase in (
        (["--cron", "61 * * * *"], "minute"),
        (["--cron", "0 9 * *"], "5 fields"),
        (["--cron", "0 0 30 2 *"], "never comes due"),
        (["--cron", "0 9 * * 5#2"], "day of week"),
        (["--hourly", "60"], "0-59"),
        (["--weekly", "funday", "09:00"], "day of the week"),
        (["--weekly", "fri"], "--weekly"),
        (["--daily", "25:00"], "HH:MM"),
        (["--once", "2026-02-30T09:00"], "YYYY-MM-DD"),
        (["--once", "2020-01-01T09:00"], "past"),
        (["--daily", "09:00", "--hourly", "5"], "exactly one Trigger"),
    ):
        refused = cli(home, "schedules", "add", "Bad", "--project", "p", "--preset", "ok", *flags)
        case.check(f"add {' '.join(flags)} is refused saying why",
                   refused.returncode != 0 and phrase in refused.stderr, refused.stderr)
    case.check("no refused task was saved", json.dumps(tasks(home), sort_keys=True) == before,
               json.dumps(tasks(home)))


def check_edit(case, home):
    task_id = add(case, home, "Edit me", "--daily", "09:00")
    state = home.state()
    for entry in state["schedules"]:
        if entry["id"] == task_id:
            entry["a_field_from_a_future_version"] = {"kept": True}
    home.write_state(state)

    renamed = cli(home, "schedules", "edit", "Edit me", "--name", "Edited")
    entry = task(home, task_id)
    case.check("edit --name renames the task", renamed.returncode == 0 and entry.get("name") == "Edited",
               renamed.stderr)
    case.check("a rename leaves the Trigger and its clock alone",
               entry.get("trigger") == {"kind": "daily", "time": "09:00"}
               and "clock_reset_at_ms" not in entry, json.dumps(entry))

    before_ms = int(time.time() * 1000)
    for flags, trigger in (
        (["--hourly", "5"], {"kind": "hourly", "minute": 5}),
        (["--weekdays", "07:45"], {"kind": "weekdays", "time": "07:45"}),
        (["--weekly", "sunday", "10:00"], {"kind": "weekly", "weekday": "sunday", "time": "10:00"}),
        (["--cron", "0 9 * * 1-5"], {"kind": "cron", "expr": "0 9 * * 1-5"}),
    ):
        edited = cli(home, "schedules", "edit", task_id, *flags)
        entry = task(home, task_id)
        case.check(f"edit {' '.join(flags)} sets the Trigger",
                   edited.returncode == 0 and entry.get("trigger") == trigger, edited.stderr or json.dumps(entry))
    case.check("a new Trigger restarts the clock",
               entry.get("clock_reset_at_ms", 0) >= before_ms, json.dumps(entry))

    moved = cli(home, "schedules", "edit", task_id, "--project", "other", "--preset", "touch", "--no-notify")
    entry = task(home, task_id)
    case.check("edit moves the task to another Project and preset and turns notify off",
               moved.returncode == 0 and entry.get("project_id") == "q"
               and entry.get("preset_id") == "touch" and entry.get("notify_when_done") is False,
               moved.stderr or json.dumps(entry))
    notify = cli(home, "schedules", "edit", task_id, "--notify")
    case.check("edit --notify turns it back on",
               notify.returncode == 0 and task(home, task_id).get("notify_when_done") is True, notify.stderr)
    case.check("fields this build does not know pass through every edit",
               task(home, task_id).get("a_field_from_a_future_version") == {"kept": True},
               json.dumps(task(home, task_id)))

    before = json.dumps(task(home, task_id), sort_keys=True)
    for args, phrase in (
        ([task_id], "nothing to change"),
        ([task_id, "--cron", "* * * * * *"], "5 fields"),
        ([task_id, "--preset", "missing"], "no preset"),
        ([task_id, "--name", "  "], "name"),
        ([task_id, "--once", "2020-01-01T09:00"], "past"),
        ([task_id, "--project", "g"], "has no folder"),
        ([task_id, "--notify", "--no-notify"], "--notify"),
        (["no such task", "--hourly", "5"], "no Scheduled Task"),
    ):
        refused = cli(home, "schedules", "edit", *args)
        case.check(f"edit {' '.join(args[1:]) or '(no change)'} is refused saying why",
                   refused.returncode != 0 and phrase in refused.stderr, refused.stderr)
    case.check("a refused edit changes nothing", json.dumps(task(home, task_id), sort_keys=True) == before)
    cli(home, "schedules", "rm", task_id)


def weekly_at(moment):
    return ["--weekly", WEEKDAYS[moment.weekday()], moment.strftime("%H:%M:%S")]


def check_pause_resume(case, service, home):
    due = local_now() + datetime.timedelta(seconds=10)
    task_id = add(case, home, "Paused", *weekly_at(due))
    first = service.wait_for(lambda: published(home, task_id).get("next_occurrence") == stored(due),
                             timeout=8)
    case.check("the Host publishes the task's next run", bool(first), json.dumps(published(home, task_id)))
    paused = cli(home, "schedules", "pause", task_id)
    case.check("pause succeeds", paused.returncode == 0, paused.stderr)
    case.check("a paused task is disabled in app-state.json", task(home, task_id).get("enabled") is False)
    human = cli(home, "schedules", "list")
    case.check("list shows it paused", "paused" in human.stdout, human.stdout)
    cleared = service.wait_for(lambda: "next_occurrence" not in published(home, task_id), timeout=15)
    case.check("the Host publishes no next run while it is paused", bool(cleared),
               json.dumps(published(home, task_id)))
    again = cli(home, "schedules", "pause", task_id)
    case.check("pausing a paused task says so", again.returncode == 0 and "already paused" in again.stdout,
               again.stdout + again.stderr)

    while local_now() < due + datetime.timedelta(seconds=3):
        service.read_for(0.5)
    case.check("the occurrence did not fire while paused", history(home, task_id) == [],
               json.dumps(history(home, task_id)))

    resumed = cli(home, "schedules", "resume", task_id)
    entry = task(home, task_id)
    case.check("resume enables the task and restarts its clock",
               resumed.returncode == 0 and entry.get("enabled") is True
               and entry.get("clock_reset_at_ms", 0) >= int(due.timestamp() * 1000),
               resumed.stderr or json.dumps(entry))
    service.read_for(4)
    case.check("resume does not catch up the occurrence it missed", history(home, task_id) == [],
               json.dumps(history(home, task_id)))
    next_week = stored(due + datetime.timedelta(days=7))
    clock = service.wait_for(lambda: published(home, task_id).get("next_occurrence") == next_week
                             and published(home, task_id), timeout=15)
    case.check("its next run is next week's", bool(clock), json.dumps(published(home, task_id)))
    again = cli(home, "schedules", "resume", task_id)
    case.check("resuming a running task says so", again.returncode == 0 and "not paused" in again.stdout,
               again.stdout + again.stderr)

    soon = local_now() + datetime.timedelta(seconds=6)
    moved = cli(home, "schedules", "edit", task_id, *weekly_at(soon))
    case.check("edit moves the weekly time to a few seconds ahead", moved.returncode == 0, moved.stderr)
    fired = service.wait_for(lambda: [run for run in history(home, task_id) if run.get("status") == "done"],
                             timeout=45)
    case.check("the resumed weekly task fires on its own", bool(fired), json.dumps(history(home, task_id)))
    if fired:
        case.check("for the edited occurrence, on time",
                   fired[0].get("scheduled_for") == stored(soon) and fired[0].get("late") is False,
                   json.dumps(fired[0]))

    once = add(case, home, "Spent", "--once", stored(local_now() + datetime.timedelta(seconds=4)))
    spent = service.wait_for(lambda: task(home, once).get("enabled") is False, timeout=30)
    case.check("a Once task disables itself after its Run", bool(spent), json.dumps(task(home, once)))
    check_spent_once(case, home, once)


def check_spent_once(case, home, once):
    """A Once task that ran and paused itself: it edits, and resumes only with a new time."""
    spent = task(home, once)
    renamed = cli(home, "schedules", "edit", once, "--name", "Spent again")
    case.check("a finished Once task still renames",
               renamed.returncode == 0 and task(home, once).get("name") == "Spent again",
               renamed.stderr)
    resent = cli(home, "schedules", "edit", once, "--once", spent["trigger"]["at"])
    entry = task(home, once)
    case.check("sending its stored Once time back succeeds and changes nothing else",
               resent.returncode == 0 and entry.get("trigger") == spent["trigger"]
               and entry.get("clock_reset_at_ms") == spent.get("clock_reset_at_ms")
               and entry.get("enabled") is False, resent.stderr or json.dumps(entry))
    past = cli(home, "schedules", "edit", once, "--once", "2020-01-01T09:00")
    entry = task(home, once)
    case.check("a paused task saves a past Once time as is",
               past.returncode == 0 and entry.get("trigger") == {"kind": "once", "at": "2020-01-01T09:00"}
               and entry.get("enabled") is False, past.stderr or json.dumps(entry))
    refused = cli(home, "schedules", "resume", once)
    case.check("resuming a Once task whose time has passed is refused, asking for a new time",
               refused.returncode != 0 and "give it a new time" in refused.stderr
               and f"unpeel schedules edit {once} --once" in refused.stderr, refused.stderr)
    case.check("and it stays paused", task(home, once).get("enabled") is False,
               json.dumps(task(home, once)))


def check_without_a_host(case, home):
    """What the CLI decides alone, before the Host starts and could run a missed time."""
    state = home.state()
    state.setdefault("schedules", []).append({
        "id": "sch_missed", "name": "Missed", "project_id": "p", "preset_id": "ok",
        "trigger": {"kind": "once", "at": "2020-01-01T09:00"}, "enabled": True,
        "notify_when_done": True, "created_at_ms": 1,
    })
    with open(home.path("app-state.json"), "w") as handle:
        json.dump(state, handle, indent=2)
    stored_trigger = task(home, "sch_missed").get("trigger")
    renamed = cli(home, "schedules", "edit", "sch_missed", "--name", "Missed it",
                  "--once", "2020-01-01T09:00")
    entry = task(home, "sch_missed")
    case.check("an enabled task whose Once passed with no Host renames, its stored time sent back",
               renamed.returncode == 0 and entry.get("name") == "Missed it"
               and entry.get("trigger") == stored_trigger and "clock_reset_at_ms" not in entry,
               renamed.stderr or json.dumps(entry))
    moved = cli(home, "schedules", "edit", "sch_missed", "--once", "2020-02-01T09:00")
    case.check("a new past Once on an enabled task is still refused",
               moved.returncode != 0 and "past" in moved.stderr
               and task(home, "sch_missed").get("trigger") == stored_trigger, moved.stderr)
    cli(home, "schedules", "rm", "sch_missed")

    before = json.dumps(tasks(home), sort_keys=True)
    for preset, extra in (("ok", []), ("claude", ["--instructions", "brief me"])):
        refused = cli(home, "schedules", "add", "Nowhere", "--project", "g", "--preset", preset,
                      "--daily", "09:00", *extra)
        case.check(f"a Project with no folder is refused for the {preset} preset",
                   refused.returncode != 0 and "has no folder" in refused.stderr, refused.stderr)
    case.check("nothing was saved", json.dumps(tasks(home), sort_keys=True) == before)


def check_inside_session(case, home):
    task_id = add(case, home, "Guarded", "--daily", "09:00")
    launched = cli(home, "new", "--preset", "ok", "--project", "p")
    ids = SESSION_ID.findall(launched.stdout)
    if not case.check("a Session to run the CLI from", launched.returncode == 0 and bool(ids),
                      launched.stderr):
        return
    inside = {"UNPEEL_SESSION_ID": ids[0]}
    before = json.dumps(task(home, task_id), sort_keys=True)
    for verb in (["edit", task_id, "--hourly", "5"], ["pause", task_id], ["resume", task_id]):
        refused = cli(home, "schedules", *verb, env=inside)
        case.check(f"schedules {verb[0]} is refused inside a Session",
                   refused.returncode != 0 and "inside a Session" in refused.stderr,
                   refused.stderr or refused.stdout)
    case.check("nothing changed", json.dumps(task(home, task_id), sort_keys=True) == before)


def body(case):
    home = case.home
    home.project("p", "sched", home.root)
    home.project("q", "other", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="touch", command="true", preset_id="touch")
    home.preset(label="Claude", command="claude", preset_id="claude")
    state = home.state()
    state["projects"].append({"id": "g", "name": "Docs", "path": "", "parent_project_id": "p",
                              "is_folder": True})
    with open(home.path("app-state.json"), "w") as handle:
        json.dump(state, handle, indent=2)
    check_without_a_host(case, home)
    service = case.serve(env={"TZ": ZONE})
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    try:
        check_every_kind(case, service, home)
        check_refusals(case, home)
        check_edit(case, home)
        check_pause_resume(case, service, home)
        check_inside_session(case, home)
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_edit", body)
