"""Upgrade guard: `schedules` in app-state.json never costs anyone their setup.

An app-state.json written before Scheduled Tasks existed has no `schedules`
key: it must load, list no tasks, and keep working. One written by a newer
version may hold a Trigger kind this build does not know, or an entry it
cannot decode: the rest of the document (presets especially, which the
Host's typed reader would otherwise drop with everything but projects) must
still load, the unknown task must be listed and never fire, and an edit by
this build must pass the newer entries through untouched.
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402

SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")

BASE_STATE = {
    "projects": [{"id": "p", "name": "compat", "path": "/tmp"}],
    "active_project_id": "p",
    "presets": [
        {"id": "ok", "label": "ok", "command": "true", "project_id": None,
         "enabled": True, "quick_launch": False}
    ],
    "active_tabs": {},
    "pinned_sessions": {},
    "a_key_from_a_future_version": {"nested": [1, 2, 3]},
}

FUTURE_TASK = {
    "id": "sch_future",
    "name": "Full moon",
    "project_id": "p",
    "preset_id": "ok",
    "trigger": {"kind": "lunar", "phase": "full", "at": "21:00"},
    "enabled": True,
    "notify_when_done": True,
    "created_at_ms": 1_700_000_000_000,
    "a_field_from_a_future_version": True,
}
UNREADABLE_TIME = {
    "id": "sch_unreadable",
    "name": "Quarter past",
    "project_id": "p",
    "preset_id": "ok",
    "trigger": {"kind": "daily", "time": "quarter past nine"},
    "created_at_ms": 1_700_000_000_000,
}
DAMAGED = [{"name": "no id at all"}, {"id": "sch_damaged", "enabled": "sometimes"}, "not a task"]


def write_state(home, extra):
    state = dict(BASE_STATE, **extra)
    with open(home.path("app-state.json"), "w") as handle:
        json.dump(state, handle, indent=2)


def listed(home):
    shown = run_cli(home, ["schedules", "list", "--json"])
    try:
        return shown.returncode, json.loads(shown.stdout)
    except ValueError:
        return shown.returncode, shown.stdout + shown.stderr


def presets_still_load(case, home, label):
    launched = run_cli(home, ["new", "--preset", "ok", "--project", "p"], timeout=45)
    ids = SESSION_ID.findall(launched.stdout)
    case.check(f"{label}: presets still load (a preset Session starts)",
               launched.returncode == 0 and bool(ids), launched.stderr)
    for session_id in ids:
        run_cli(home, ["rm", session_id], timeout=45)


def body(case):
    home = case.home

    write_state(home, {})
    code, tasks = listed(home)
    case.check("a state without schedules lists no tasks", code == 0 and tasks == [], str(tasks))
    presets_still_load(case, home, "no schedules")

    write_state(home, {"schedules": [FUTURE_TASK, UNREADABLE_TIME, *DAMAGED]})
    presets_still_load(case, home, "a newer schedule")
    code, tasks = listed(home)
    by_id = {task.get("id"): task for task in tasks} if isinstance(tasks, list) else {}
    case.check("the unknown Trigger's task and the unreadable one are listed, the damaged ones are not",
               code == 0 and sorted(by_id) == ["sch_future", "sch_unreadable"], str(tasks))
    case.check("neither has a next run",
               all(task.get("next_run") is None for task in by_id.values()), str(tasks))
    human = run_cli(home, ["schedules", "list"])
    case.check("list says the unknown task never fires", "never fires" in human.stdout, human.stdout)

    service = case.serve()
    if not case.check("the Host starts", bool(service.ready(timeout=25)), service.log()):
        return
    service.read_for(4)
    case.check("the Host fires neither task",
               not os.path.exists(home.path("schedules", "sch_future", "runs.jsonl"))
               and not os.path.exists(home.path("schedules", "sch_unreadable", "runs.jsonl")),
               str(os.listdir(home.path("schedules")) if os.path.isdir(home.path("schedules")) else []))
    spawned = [m for m in home.manifests().values()
               if (m.get("session", {}).get("spawned_by") or "").startswith("schedule:")]
    case.check("no Run Session was started", not spawned, json.dumps(spawned)[:300])

    added = run_cli(home, ["schedules", "add", "Later", "--project", "p", "--preset", "ok",
                           "--daily", "23:59"])
    case.check("this build can add a task beside them", added.returncode == 0, added.stderr)
    state = home.state()
    future = next((task for task in state.get("schedules", []) if task.get("id") == "sch_future"), None)
    case.check("the newer task's fields pass through an edit untouched", future == FUTURE_TASK,
               json.dumps(future))
    case.check("the damaged entries and the future top-level key survive the edit",
               all(entry in state.get("schedules", []) for entry in DAMAGED)
               and state.get("a_key_from_a_future_version") == {"nested": [1, 2, 3]},
               json.dumps(state.get("schedules")))


run("compat_schedules", body)
