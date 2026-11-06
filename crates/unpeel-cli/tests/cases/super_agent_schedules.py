"""Fork-only: the Super Agent manages Scheduled Tasks for the user.

Through `unpeel mcp workspace …` (the dispatcher an agent's MCP server
runs) from inside the Session marked Super Agent, against a live `unpeel
serve`: `create_schedule` saves a task through the Host's own write route
(Trigger in stored form, a preset label resolved to its id), `edit_schedule`
renames it, moves its Trigger, pauses and resumes it, `run_schedule` starts
a Run that finishes, and `delete_schedule` removes the task and keeps its
Run Session. The Host's refusals come back with their codes (instructions
on a script preset, a past Once) and save nothing. Any other Session is
refused every write, through MCP and `unpeel schedules` alike, while the
Super Agent may use the CLI too. With the Host stopped a write says so and
changes nothing.

A write's answer carries the task's next run on the Host's clock at once,
and when the worker then publishes it the Host pings the state bus, so a
Controller that re-read the list before that sweep is told to read again.
"""

import datetime
import json
import os
import re
import socket
import sys
import threading
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402

ZONE = "America/New_York"
SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
WRITES = ("create_schedule", "edit_schedule", "delete_schedule", "run_schedule")


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


def as_json(result):
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {}


def detail(result):
    return (result.stderr or result.stdout)[-500:]


def stored(home):
    return {task["id"]: task for task in home.state().get("schedules", [])}


def listen_on_the_bus(home):
    """A stand-in Controller registered in `app-ports`: when it heard which change."""
    heard = []
    peer = socket.socket()
    peer.bind(("127.0.0.1", 0))
    peer.listen(8)

    def serve():
        while True:
            try:
                conn, _ = peer.accept()
            except OSError:
                return
            data = conn.recv(4096).decode("utf-8", "replace")
            # Only the bus route answers: the Host probes `app-ports` for a
            # native app, and this stand-in must not pass for one.
            if "/state-changed" in data:
                heard.append((time.time(), data))
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
            else:
                conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            conn.close()

    threading.Thread(target=serve, daemon=True).start()
    with open(home.path("app-ports"), "a") as handle:
        handle.write(f"{peer.getsockname()[1]}\n")
    return heard


def published_next(home, task_id):
    """The next run the worker last published for the task, and when."""
    path = home.path("schedules", task_id, "clock.json")
    try:
        with open(path) as handle:
            return json.load(handle).get("next_occurrence"), os.stat(path).st_mtime
    except (OSError, ValueError):
        return None, None


def check_published(case, service, home, heard, task_id, ending):
    """The worker publishes the edited next run, then pings the bus."""
    published = service.wait_for(
        lambda: (lambda at, when: when if at and at.endswith(ending) else None)(
            *published_next(home, task_id)), timeout=10)
    case.check(f"the worker publishes the next run ending {ending}", bool(published),
               str(published_next(home, task_id)))
    pinged = service.wait_for(
        lambda: any(at >= published - 0.05 and '"change":"schedules"' in note
                    for at, note in heard), timeout=5) if published else False
    case.check("then it pings the state bus, so Controllers read the new next run",
               bool(pinged), str([(round(at - (published or 0), 3), note[-40:]) for at, note in heard]))


def launch(case, home):
    launched = cli(home, "new", "--preset", "cat", "--project", "p")
    ids = SESSION_ID.findall(launched.stdout)
    case.check("a Session to call MCP from", launched.returncode == 0 and bool(ids), detail(launched))
    return ids[0] if ids else None


def check_others_refused(case, home, other):
    inside = {"UNPEEL_SESSION_ID": other}
    for action in WRITES:
        refused = cli(home, "mcp", "workspace", action, "schedule_id=sch_x", env=inside)
        case.check(f"{action} is refused for a Session that is not the Super Agent",
                   refused.returncode != 0 and "Only the Super Agent" in refused.stderr,
                   detail(refused))
    added = cli(home, "schedules", "add", "Theirs", "--project", "p", "--preset", "ok",
                "--daily", "10:00", env=inside)
    case.check("schedules add still refuses inside any other Session",
               added.returncode != 0 and "inside a Session" in added.stderr, detail(added))
    case.check("nothing was saved for them", stored(home) == {}, json.dumps(stored(home)))


def check_create(case, home, mcp):
    created = mcp("create_schedule", "name=Backup", "project_id=p", "preset=OK",
                  'trigger={"kind":"daily","time":"09:30:00"}')
    row = as_json(created).get("schedule") or {}
    task_id = row.get("id", "")
    case.check("the Super Agent creates a task through the Host",
               created.returncode == 0 and task_id.startswith("sch_"), detail(created))
    saved = stored(home).get(task_id, {})
    case.check("it is saved with the preset's id and its Trigger in stored form",
               saved.get("name") == "Backup" and saved.get("project_id") == "p"
               and saved.get("preset_id") == "ok" and saved.get("enabled") is True
               and saved.get("trigger") == {"kind": "daily", "time": "09:30"}, json.dumps(saved))
    case.check("the answer is the list row, with its next run",
               (row.get("nextRun") or {}).get("at", "").endswith("T09:30"), json.dumps(row))

    agent = mcp("create_schedule", "name=Briefing", "project_id=p", "preset=agent",
                'trigger={"kind":"weekdays","time":"08:00"}', "instructions=Summarise my day",
                "enabled=false", "notify_when_done=false")
    agent_id = (as_json(agent).get("schedule") or {}).get("id", "")
    briefing = stored(home).get(agent_id, {})
    case.check("an Agent Preset task keeps its instructions, saved paused and quiet",
               agent.returncode == 0 and briefing.get("instructions") == "Summarise my day"
               and briefing.get("enabled") is False and briefing.get("notify_when_done") is False,
               detail(agent) + json.dumps(briefing))

    before = stored(home)
    script = mcp("create_schedule", "name=Bad", "project_id=p", "preset=ok",
                 'trigger={"kind":"daily","time":"10:00"}', "instructions=do it")
    case.check("instructions on a script preset come back with the Host's code",
               script.returncode != 0 and "not_agent_preset" in script.stderr, detail(script))
    past = (datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) - datetime.timedelta(hours=1))
    once = json.dumps({"kind": "once", "at": past.strftime("%Y-%m-%dT%H:%M")})
    late = mcp("create_schedule", "name=Late", "project_id=p", "preset=ok", f"trigger={once}")
    case.check("a past Once comes back with the Host's code",
               late.returncode != 0 and "trigger_in_past" in late.stderr, detail(late))
    case.check("a refused create saves nothing", stored(home) == before, json.dumps(stored(home)))
    return task_id


def check_edit(case, service, home, heard, mcp, task_id):
    check_published(case, service, home, heard, task_id, "T09:30")
    heard.clear()
    edited = mcp("edit_schedule", f"schedule_id={task_id}", "name=Nightly backup",
                 'trigger={"kind":"weekly","weekday":"friday","time":"17:00"}')
    saved = stored(home).get(task_id, {})
    case.check("edit_schedule renames the task and moves its Trigger",
               edited.returncode == 0 and saved.get("name") == "Nightly backup"
               and saved.get("trigger") == {"kind": "weekly", "weekday": "friday", "time": "17:00"},
               detail(edited) + json.dumps(saved))
    case.check("the edit answers with the new Trigger's next run",
               ((as_json(edited).get("schedule") or {}).get("nextRun") or {})
               .get("at", "").endswith("T17:00"), detail(edited))
    check_published(case, service, home, heard, task_id, "T17:00")

    paused = mcp("edit_schedule", f"schedule_id={task_id}", "enabled=false")
    row = as_json(paused).get("schedule") or {}
    case.check("enabled=false pauses it: no next run",
               paused.returncode == 0 and row.get("enabled") is False and row.get("nextRun") is None,
               detail(paused))
    resumed = mcp("edit_schedule", f"schedule_id={task_id}", "enabled=true")
    row = as_json(resumed).get("schedule") or {}
    case.check("enabled=true resumes it with a next run",
               resumed.returncode == 0 and row.get("enabled") is True
               and (row.get("nextRun") or {}).get("at", "").endswith("T17:00"), detail(resumed))
    nothing = mcp("edit_schedule", f"schedule_id={task_id}")
    case.check("an edit with nothing to change says so",
               nothing.returncode != 0 and "nothing to change" in nothing.stderr, detail(nothing))


def check_run(case, service, home, mcp, task_id):
    started = mcp("run_schedule", f"schedule_id={task_id}")
    run_id = as_json(started).get("runID", "")
    case.check("run_schedule starts a Run", started.returncode == 0 and run_id.startswith("run_"),
               detail(started))

    def entry():
        runs = as_json(mcp("list_schedule_runs", f"schedule_id={task_id}")).get("runs", [])
        return next((r for r in runs if r.get("runID") == run_id), {})

    done = service.wait_for(lambda: entry().get("status") == "done" and entry(), timeout=45) or entry()
    case.check("the Run finishes", done.get("status") == "done", json.dumps(done))
    return done.get("sessionID")


def check_delete(case, home, mcp, task_id, run_session):
    deleted = mcp("delete_schedule", f"schedule_id={task_id}")
    case.check("delete_schedule removes the task",
               deleted.returncode == 0 and as_json(deleted).get("deleted") is True
               and task_id not in stored(home), detail(deleted))
    case.check("its Run Session stays", bool(run_session) and run_session in home.manifests(),
               str(run_session))
    again = mcp("delete_schedule", f"schedule_id={task_id}")
    case.check("a removed task is unknown", again.returncode != 0 and "unknown_task" in again.stderr,
               detail(again))


def check_cli(case, home, router):
    added = cli(home, "schedules", "add", "From CLI", "--project", "p", "--preset", "ok",
                "--hourly", "15", env={"UNPEEL_SESSION_ID": router})
    task_id = added.stdout.strip()
    case.check("the Super Agent may use unpeel schedules too",
               added.returncode == 0 and task_id in stored(home), detail(added))
    return task_id


def body(case):
    home = case.home
    home.project("p", "sched", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="cat", command="cat", preset_id="cat")
    home.preset(label="agent", command="claude", preset_id="agent")
    heard = listen_on_the_bus(home)
    service = case.serve(env={"TZ": ZONE})
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    try:
        router, other = launch(case, home), launch(case, home)
        if not (router and other):
            return
        state = home.state()
        state["super_agent"] = {"session_id": router, "since": int(time.time() * 1000)}
        home.write_state(state)

        def mcp(*words):
            return cli(home, "mcp", "workspace", *words, env={"UNPEEL_SESSION_ID": router})

        check_others_refused(case, home, other)
        task_id = check_create(case, home, mcp)
        if not task_id:
            return
        check_edit(case, service, home, heard, mcp, task_id)
        run_session = check_run(case, service, home, mcp, task_id)
        check_delete(case, home, mcp, task_id, run_session)
        cli_task = check_cli(case, home, router)

        service.close()
        before = stored(home)
        down = mcp("edit_schedule", f"schedule_id={cli_task}", "enabled=false")
        case.check("with the Host stopped a write says so",
                   down.returncode != 0 and "Host service runs" in down.stderr, detail(down))
        case.check("and changes nothing", stored(home) == before, json.dumps(stored(home)))
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)


run("super_agent_schedules", body)
