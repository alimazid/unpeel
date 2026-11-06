"""Scheduled Tasks over the Host protocol, as a paired Controller sees them.

The Host advertises `schedules` and `schedules.runs` in bootstrap, with a
`schedulesRevision` that moves whenever either route would answer
differently. `GET /mobile/schedules` lists every task with its next run and
its latest Run; `GET /mobile/schedules/runs` is one task's history, newest
first. A Run now that finishes (done, then failed with exit 3) shows up in
both, and the worker pings the state bus (`schedules`) when it records a
Run. Both routes read the disk, not the scheduler: a Run line or a rename
written straight to the files shows at once.
"""

import datetime
import json
import os
import socket
import sys
import threading
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import host_certificate_pin, mobile_port, mobile_request, run, run_cli  # noqa: E402

ZONE = "America/New_York"


def cli(home, *args):
    return run_cli(home, list(args), env={"TZ": ZONE}, timeout=45)


def tomorrow():
    later = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) + datetime.timedelta(days=1)
    return later.strftime("%Y-%m-%dT%H:%M")


def listen_on_the_bus(home):
    """A stand-in Controller registered in `app-ports`: every ping it hears."""
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
                heard.append(data)
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
            else:
                conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            conn.close()

    threading.Thread(target=serve, daemon=True).start()
    with open(home.path("app-ports"), "a") as handle:
        handle.write(f"{peer.getsockname()[1]}\n")
    return heard


class Controller:
    def __init__(self, home, port, token):
        self.home, self.port, self.token = home, port, token

    def get(self, path):
        return mobile_request(self.port, path, self.token, home=self.home)

    def task(self, task_id):
        status, body = self.get("/mobile/schedules")
        if status != 200:
            return {}
        return next((t for t in body.get("schedules", []) if t.get("id") == task_id), {})

    def revision(self):
        status, body = self.get("/mobile/bootstrap")
        return body.get("schedulesRevision") if status == 200 else None


def add(case, home, name, preset, *trigger):
    added = cli(home, "schedules", "add", name, "--project", "p", "--preset", preset, *trigger)
    task_id = added.stdout.strip()
    case.check(f"{name}: added", added.returncode == 0 and task_id.startswith("sch_"),
               added.stderr)
    return task_id


def run_now_and_wait(case, service, controller, home, task_id, status):
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    case.check(f"Run now of {task_id} is accepted", started.returncode == 0, started.stderr)
    last = service.wait_for(
        lambda: (lambda run: run if run.get("runID") == run_id
                 and run.get("status") == status else None)(
            controller.task(task_id).get("lastRun") or {}),
        timeout=45,
    )
    return run_id, last or controller.task(task_id).get("lastRun") or {}


def check_advertised(case, controller):
    status, boot = controller.get("/mobile/bootstrap")
    capabilities = (boot.get("hostProtocol") or {}).get("capabilities") or []
    case.check("bootstrap advertises both schedules capabilities",
               status == 200 and "schedules" in capabilities and "schedules.runs" in capabilities,
               json.dumps(capabilities)[:400])
    case.check("bootstrap carries a schedules revision",
               isinstance(boot.get("schedulesRevision"), str), json.dumps(boot)[:200])
    status, listed = controller.get("/mobile/schedules")
    case.check("a workspace without tasks lists none",
               status == 200 and listed.get("schedules") == [], json.dumps(listed)[:200])


def check_next_run(case, service, controller, home, empty_revision):
    task_id = add(case, home, "Morning", "ok", "--daily", "09:43")
    task = service.wait_for(lambda: (lambda t: t if t.get("nextRun") else None)(
        controller.task(task_id)), timeout=20) or controller.task(task_id)
    next_run = task.get("nextRun") or {}
    case.check("the task lists with the next run the worker published",
               str(next_run.get("at", "")).endswith("T09:43")
               and isinstance(next_run.get("atMs"), int)
               and next_run["atMs"] > time.time() * 1000,
               json.dumps(task))
    case.check("it lists its definition camelCased",
               task.get("name") == "Morning" and task.get("projectID") == "p"
               and task.get("presetID") == "ok" and task.get("enabled") is True
               and task.get("trigger") == {"kind": "daily", "time": "09:43"}
               and task.get("lastRun") is None, json.dumps(task))
    case.check("the revision moved with the new task",
               controller.revision() not in (None, empty_revision))
    return task_id


def check_run_events(case, service, controller, home, heard, task_id):
    heard.clear()
    revision = controller.revision()
    run_id, last = run_now_and_wait(case, service, controller, home, task_id, "done")
    case.check("a finished Run now is the task's last Run",
               last.get("runID") == run_id and last.get("exitCode") == 0
               and last.get("scheduledFor") is None and last.get("late") is False,
               json.dumps(last))
    manifest = home.manifests().get(last.get("sessionID") or "", {})
    case.check("its sessionID names the Run's Session",
               manifest.get("session", {}).get("spawned_by") == f"schedule:{task_id}",
               json.dumps(manifest.get("session", {}))[:300])
    case.check("the worker pinged the state bus with a schedules change",
               any('"change":"schedules"' in note for note in heard), str(heard)[:300])
    case.check("the revision moved with the Run", controller.revision() != revision)

    status, history = controller.get(f"/mobile/schedules/runs?scheduleID={task_id}")
    runs = history.get("runs") or []
    case.check("the Run history lists the Run",
               status == 200 and history.get("scheduleID") == task_id
               and [r.get("runID") for r in runs] == [run_id]
               and runs[0].get("status") == "done", json.dumps(history)[:400])

    broken = add(case, home, "Broken", "three", "--once", tomorrow())
    _, failed = run_now_and_wait(case, service, controller, home, broken, "failed")
    case.check("a failed Run is listed with its exit code and reason",
               failed.get("exitCode") == 3
               and "status 3" in (failed.get("reason") or ""), json.dumps(failed))


def check_disk_reads(case, service, controller, home, task_id):
    log = home.path("schedules", task_id, "runs.jsonl")
    with open(log, "a") as handle:
        handle.write(json.dumps({"run_id": "run_from_disk", "status": "skipped",
                                 "scheduled_for": "2026-11-06T09:43",
                                 "reason": "written straight to the log"}) + "\n")
    status, history = controller.get(f"/mobile/schedules/runs?scheduleID={task_id}&limit=1")
    case.check("the history reads the Run log on disk, newest first, within its limit",
               status == 200 and [r.get("runID") for r in history.get("runs", [])]
               == ["run_from_disk"], json.dumps(history)[:300])
    case.check("so does the list's last Run",
               (controller.task(task_id).get("lastRun") or {}).get("runID") == "run_from_disk")

    state = home.state()
    for entry in state.get("schedules", []):
        if entry.get("id") == task_id:
            entry["name"] = "Renamed on disk"
    home.write_state(state)
    case.check("the list reads definitions from app-state.json",
               controller.task(task_id).get("name") == "Renamed on disk")

    for path, expected in (("/mobile/schedules/runs", 400),
                           ("/mobile/schedules/runs?scheduleID=sch_gone", 404),
                           (f"/mobile/schedules/runs?scheduleID={task_id}&limit=0", 400)):
        status, _ = controller.get(path)
        case.check(f"{path} answers {expected}", status == expected, str(status))


def body(case):
    home = case.home
    home.project("p", "sched", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="three", command="/bin/sh -c 'exit 3'", preset_id="three")
    token = home.pair_device()
    home.reserve_mobile_port()
    service = case.serve(env={"TZ": ZONE})
    if not case.check("the Host starts", bool(service.ready(timeout=25)), service.log()):
        return
    port = mobile_port(home)
    # The Direct endpoint serves TLS once the Host has minted its
    # certificate, a moment after it reports ready.
    pinned = service.wait_for(lambda: host_certificate_pin(home), timeout=20)
    if not case.check("the Host serves /mobile", port is not None and bool(pinned),
                      json.dumps(sorted(os.listdir(home.root))) + service.log()[-1500:]):
        return
    heard = listen_on_the_bus(home)
    controller = Controller(home, port, token)
    try:
        check_advertised(case, controller)
        empty_revision = controller.revision()
        task_id = check_next_run(case, service, controller, home, empty_revision)
        check_run_events(case, service, controller, home, heard, task_id)
        check_disk_reads(case, service, controller, home, task_id)
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_routes", body)
