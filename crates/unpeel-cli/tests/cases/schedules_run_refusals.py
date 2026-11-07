"""Run now's refusals keep their own reason on every wire (#28).

A task whose Run log (`runs.jsonl`) will not read is refused because the
Host cannot tell whether a Run is in progress, never as "a Run is still in
progress": `unpeel schedules run` (the owner-only `/_unpeel/schedules`
control path) exits non-zero with the Host's message, a paired Controller's
`POST /mobile/schedules/run` answers 500 `run_log_unreadable` naming the
task, and the Super Agent's MCP `run_schedule` shows that code. A Run
already queued, and one really in progress, still answer 409
`run_in_progress` on both wires.
"""

import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import host_certificate_pin, mobile_port, mobile_request, run, run_cli  # noqa: E402

ZONE = "America/New_York"
SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


def detail(result):
    return f"exit {result.returncode}: {(result.stderr or result.stdout)[-500:]}"


def add(case, home, name, preset):
    added = cli(home, "schedules", "add", name, "--project", "p", "--preset", preset,
                "--daily", "03:00")
    task_id = added.stdout.strip()
    case.check(f"{name} is added", added.returncode == 0 and task_id.startswith("sch_"),
               detail(added))
    return task_id if task_id.startswith("sch_") else None


def route(phone, task_id):
    status, answer = phone(task_id)
    return status, answer, json.dumps([status, answer])


def router_mcp(case, home):
    """`unpeel mcp workspace …` from a Session marked Super Agent."""
    launched = cli(home, "new", "--preset", "cat", "--project", "p")
    ids = SESSION_ID.findall(launched.stdout)
    if not case.check("a Session to call MCP from", launched.returncode == 0 and bool(ids),
                      detail(launched)):
        return None
    state = home.state()
    state["super_agent"] = {"session_id": ids[0], "since": int(time.time() * 1000)}
    home.write_state(state)
    return lambda *words: cli(home, "mcp", "workspace", *words,
                              env={"UNPEEL_SESSION_ID": ids[0]})


def check_unreadable_run_log(case, home, phone, mcp):
    task_id = add(case, home, "Morning", "ok")
    if not task_id:
        return
    os.makedirs(home.path("schedules", task_id, "runs.jsonl"), exist_ok=True)

    refused = cli(home, "schedules", "run", task_id)
    case.check("the CLI refuses with the Run log's own reason",
               refused.returncode != 0 and "runs.jsonl" in refused.stderr
               and "cannot tell whether a Run of Morning" in refused.stderr
               and "still in progress" not in refused.stderr, detail(refused))

    status, answer, shown = route(phone, task_id)
    case.check("the route answers 500 run_log_unreadable naming the task",
               status == 500 and answer.get("code") == "run_log_unreadable"
               and "Morning" in answer.get("error", "")
               and "runs.jsonl" in answer.get("error", ""), shown)

    if mcp:
        refused = mcp("run_schedule", f"schedule_id={task_id}")
        case.check("MCP run_schedule shows run_log_unreadable",
                   refused.returncode != 0 and "run_log_unreadable" in refused.stderr
                   and "cannot tell whether a Run of Morning" in refused.stderr,
                   detail(refused))


def last_run_status(phone_get, task_id):
    status, body = phone_get()
    rows = body.get("schedules", []) if status == 200 else []
    row = next((row for row in rows if row.get("id") == task_id), {})
    return (row.get("lastRun") or {}).get("status")


def check_in_progress(case, service, home, phone, phone_get):
    task_id = add(case, home, "Slow", "slow")
    if not task_id:
        return
    started = cli(home, "schedules", "run", task_id)
    case.check("Run now starts a Run", started.returncode == 0
               and started.stdout.strip().startswith("run_"), detail(started))

    # Asked again at once, the first is queued or already running: either is
    # a Run in progress.
    again = cli(home, "schedules", "run", task_id)
    case.check("the CLI refuses a second Run now as in progress",
               again.returncode != 0 and "still in progress" in again.stderr, detail(again))
    status, answer, shown = route(phone, task_id)
    case.check("so does the route, 409 run_in_progress",
               status == 409 and answer.get("code") == "run_in_progress", shown)

    running = service.wait_for(lambda: last_run_status(phone_get, task_id) == "running",
                               timeout=30)
    case.check("the Run is in progress", bool(running), str(last_run_status(phone_get, task_id)))
    again = cli(home, "schedules", "run", task_id)
    case.check("while it runs the CLI refuses as in progress",
               again.returncode != 0 and "still in progress" in again.stderr, detail(again))
    status, answer, shown = route(phone, task_id)
    case.check("and the route answers 409 run_in_progress",
               status == 409 and answer.get("code") == "run_in_progress", shown)


def body(case):
    home = case.home
    home.project("p", "sched", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="slow", command="sleep 25", preset_id="slow")
    home.preset(label="cat", command="cat", preset_id="cat")
    token = home.pair_device()
    home.reserve_mobile_port()
    service = case.serve(env={"TZ": ZONE})
    if not case.check("the Host starts", bool(service.ready(timeout=25)), service.log()):
        return
    port = mobile_port(home)
    pinned = service.wait_for(lambda: host_certificate_pin(home), timeout=20)
    if not case.check("the Host serves /mobile", port is not None and bool(pinned),
                      service.log()[-1500:]):
        return

    def phone(task_id):
        return mobile_request(port, "/mobile/schedules/run", token, method="POST",
                              body={"scheduleID": task_id}, home=home)

    def phone_get():
        return mobile_request(port, "/mobile/schedules", token, home=home)

    try:
        check_unreadable_run_log(case, home, phone, router_mcp(case, home))
        check_in_progress(case, service, home, phone, phone_get)
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_run_refusals", body)
