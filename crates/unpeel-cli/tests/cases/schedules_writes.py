"""Scheduled Tasks written by a Controller, the way the Mac app writes them.

Both Controller transports serve the write routes: `/mobile` (a paired
device) and the local Host socket (the Mac app's own path). Bootstrap
advertises `schedules.create|edit|delete|run` and says which presets are
Agent Presets. A task created over the protocol is saved in
`app-state.json` with its Trigger in stored form and fires like one from
the CLI; edit, pause and resume round-trip; Run now starts a Run and is
refused (409) while one is in progress; delete removes the task and its
history and leaves its Run Session. A past Once on an enabled task,
instructions on a script preset, a Project with no folder (whatever the
preset), or an unknown task are refused and nothing is saved. A paused task
saves a past Once as is, edits with its stored Trigger sent back, and is
refused resuming until it has a new time.
"""

import base64
import datetime
import json
import os
import socket
import struct
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import host_certificate_pin, mobile_port, mobile_request, run, run_cli  # noqa: E402

ZONE = "America/New_York"
WRITES = ["schedule.create", "schedule.edit", "schedule.delete", "schedule.run"]


class LocalSocket:
    """The Mac app's transport: UPL1 frames on the workspace's host.sock."""

    def __init__(self, path):
        self.path = path
        self.next_id = 0

    def call(self, method, path, body=None):
        self.next_id += 1
        payload = json.dumps({
            "id": self.next_id, "method": method, "path": path, "query": {},
            "auth": None, "contentType": "application/json",
            "bodyB64": base64.b64encode(json.dumps(body or {}).encode()).decode(),
        }).encode()
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(20)
            conn.connect(self.path)
            conn.sendall(b"UPL1" + bytes([1, 0, 0, 0]) + struct.pack(">I", len(payload)) + payload)
            header = self._read(conn, 12)
            envelope = json.loads(self._read(conn, struct.unpack(">I", header[8:12])[0]))
        raw = base64.b64decode(envelope["bodyB64"]) if envelope.get("bodyB64") else b"{}"
        return envelope["status"], json.loads(raw or b"{}")

    @staticmethod
    def _read(conn, count):
        data = b""
        while len(data) < count:
            chunk = conn.recv(count - len(data))
            if not chunk:
                break
            data += chunk
        return data


class Phone:
    def __init__(self, home, port, token):
        self.home, self.port, self.token = home, port, token

    def call(self, method, path, body=None):
        return mobile_request(self.port, path, self.token, method=method, body=body,
                              home=self.home)


def task(home, task_id):
    return next((t for t in home.state().get("schedules", []) if t.get("id") == task_id), None)


def listed(transport, task_id):
    status, body = transport.call("GET", "/mobile/schedules")
    rows = body.get("schedules", []) if status == 200 else []
    return next((row for row in rows if row.get("id") == task_id), {})


def next_minute():
    """A Once time a little over a minute away at most, on the Host's clock."""
    now = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE))
    soon = (now + datetime.timedelta(seconds=75)).replace(second=0, microsecond=0)
    return soon.strftime("%Y-%m-%dT%H:%M")


def check_bootstrap(case, phone, local):
    for name, transport in (("/mobile", phone), ("the local socket", local)):
        status, boot = transport.call("GET", "/mobile/bootstrap")
        capabilities = (boot.get("hostProtocol") or {}).get("capabilities") or []
        case.check(f"{name} advertises the write capabilities",
                   status == 200 and all(cap in capabilities for cap in WRITES),
                   json.dumps(capabilities)[-400:])
        flags = {p.get("id"): p.get("agentPreset") for p in boot.get("presets", [])}
        case.check(f"{name} flags each preset's Agent Preset kind",
                   flags.get("claude") is True and flags.get("ok") is False
                   and flags.get("slow") is False, json.dumps(flags))
        bypass = {p.get("id"): p.get("bypassesApprovals") for p in boot.get("presets", [])}
        case.check(f"{name} says which presets turn off their agent's approvals",
                   bypass.get("unattended") is True and bypass.get("claude") is False
                   and bypass.get("ok") is False, json.dumps(bypass))


def check_create(case, home, phone):
    status, body = phone.call("POST", "/mobile/schedules", {
        "name": " Morning ", "projectID": "p", "presetID": "ok",
        "trigger": {"kind": "daily", "time": "09:43:00"},
    })
    task_id = (body.get("schedule") or {}).get("id", "")
    case.check("a phone creates a task", status == 200 and task_id.startswith("sch_"),
               json.dumps(body))
    saved = task(home, task_id) or {}
    case.check("it is saved with its defaults and a stored-form Trigger",
               saved.get("name") == "Morning" and saved.get("trigger")
               == {"kind": "daily", "time": "09:43"} and saved.get("enabled") is True
               and saved.get("notify_when_done") is True, json.dumps(saved))

    before = json.dumps(home.state().get("schedules"))
    for what, change, code in (
        ("a past Once", {"trigger": {"kind": "once", "at": "2001-01-01T09:00"}}, "trigger_in_past"),
        ("a Trigger that never reads", {"trigger": {"kind": "daily", "time": "25:00"}},
         "invalid_trigger"),
        ("instructions on a script preset", {"instructions": "hello"}, "not_agent_preset"),
        ("an unknown preset", {"presetID": "gone"}, "preset_missing"),
        ("an unknown Project", {"projectID": "gone"}, "project_missing"),
        ("a Project with no folder, script preset", {"projectID": "g"}, "project_missing"),
        ("a Project with no folder, Agent Preset",
         {"projectID": "g", "presetID": "claude", "instructions": "brief me"}, "project_missing"),
        ("a top-level Project with no folder", {"projectID": "v"}, "project_missing"),
    ):
        body = {"name": "Bad", "projectID": "p", "presetID": "ok",
                "trigger": {"kind": "daily", "time": "10:00"}}
        body.update(change)
        status, answer = phone.call("POST", "/mobile/schedules", body)
        case.check(f"{what} is refused with its code and a reason",
                   status == 400 and answer.get("code") == code and bool(answer.get("error")),
                   json.dumps(answer))
    case.check("nothing refused was saved", json.dumps(home.state().get("schedules")) == before)

    status, body = phone.call("POST", "/mobile/schedules", {
        "name": "Briefing", "projectID": "p", "presetID": "claude",
        "instructions": "brief me", "trigger": {"kind": "weekly", "weekday": "friday",
                                               "time": "17:00"},
    })
    case.check("an Agent Preset task keeps its instructions and lists them",
               status == 200 and (body.get("schedule") or {}).get("instructions") == "brief me",
               json.dumps(body))
    return task_id


def check_edit_pause_resume(case, service, home, local, task_id):
    status, body = local.call("POST", "/mobile/schedules/edit", {
        "scheduleID": task_id, "name": "Evening", "notifyWhenDone": False,
        "trigger": {"kind": "weekdays", "time": "18:30"},
    })
    saved = task(home, task_id) or {}
    case.check("the local socket edits it",
               status == 200 and saved.get("name") == "Evening"
               and saved.get("notify_when_done") is False
               and saved.get("trigger") == {"kind": "weekdays", "time": "18:30"}
               and isinstance(saved.get("clock_reset_at_ms"), int), json.dumps([body, saved]))

    status, _ = local.call("POST", "/mobile/schedules/edit", {"scheduleID": task_id,
                                                              "enabled": False})
    case.check("pause", status == 200 and (task(home, task_id) or {}).get("enabled") is False)
    paused = service.wait_for(lambda: listed(local, task_id).get("nextRun") is None
                              and listed(local, task_id).get("enabled") is False, timeout=10)
    case.check("a paused task lists no next run", bool(paused), json.dumps(listed(local, task_id)))
    reset_before = (task(home, task_id) or {}).get("clock_reset_at_ms")
    status, _ = local.call("POST", "/mobile/schedules/edit", {"scheduleID": task_id,
                                                              "enabled": True})
    resumed = task(home, task_id) or {}
    case.check("resume restarts its clock",
               status == 200 and resumed.get("enabled") is True
               and resumed.get("clock_reset_at_ms", 0) >= (reset_before or 0), json.dumps(resumed))
    status, _ = local.call("POST", "/mobile/schedules/edit", {"scheduleID": "sch_gone",
                                                              "name": "x"})
    case.check("an unknown task is 404", status == 404, str(status))


def check_paused_past_once(case, home, local):
    past = {"kind": "once", "at": "2001-01-01T09:00"}
    status, body = local.call("POST", "/mobile/schedules", {
        "name": "Later", "projectID": "p", "presetID": "ok", "trigger": past, "enabled": False,
    })
    task_id = (body.get("schedule") or {}).get("id", "")
    case.check("a paused task is created with a past Once time as is",
               status == 200 and (task(home, task_id) or {}).get("trigger") == past,
               json.dumps(body))
    status, body = local.call("POST", "/mobile/schedules/edit", {
        "scheduleID": task_id, "name": "Later still", "trigger": past,
    })
    case.check("it edits with its stored Trigger sent back",
               status == 200 and (task(home, task_id) or {}).get("name") == "Later still",
               json.dumps(body))
    status, body = local.call("POST", "/mobile/schedules/edit", {
        "scheduleID": task_id, "trigger": {"kind": "once", "at": "2002-02-02T09:00"},
    })
    case.check("a paused task is edited to another past Once time",
               status == 200 and (task(home, task_id) or {}).get("trigger", {}).get("at")
               == "2002-02-02T09:00", json.dumps(body))
    status, body = local.call("POST", "/mobile/schedules/edit", {"scheduleID": task_id,
                                                                 "enabled": True})
    case.check("resuming it is refused, asking for a new time",
               status == 400 and body.get("code") == "trigger_in_past"
               and "give it a new time" in body.get("error", ""), json.dumps(body))
    case.check("and it stays paused", (task(home, task_id) or {}).get("enabled") is False)
    local.call("POST", "/mobile/schedules/delete", {"scheduleID": task_id})


def wait_last_run(service, transport, task_id, run_id, statuses, timeout=45):
    def finished():
        last = listed(transport, task_id).get("lastRun") or {}
        return last if last.get("runID") == run_id and last.get("status") in statuses else None
    return service.wait_for(finished, timeout=timeout) or {}


def check_run_now(case, service, home, phone, local):
    status, body = phone.call("POST", "/mobile/schedules", {
        "name": "Slow", "projectID": "p", "presetID": "slow",
        "trigger": {"kind": "daily", "time": "03:00"},
    })
    slow = (body.get("schedule") or {}).get("id", "")
    status, started = local.call("POST", "/mobile/schedules/run", {"scheduleID": slow})
    run_id = started.get("runID", "")
    case.check("Run now starts a Run", status == 200 and run_id.startswith("run_"),
               json.dumps(started))
    running = wait_last_run(service, phone, slow, run_id, ("running",), timeout=30)
    case.check("the Run is in progress", bool(running), json.dumps(listed(phone, slow)))
    status, refused = phone.call("POST", "/mobile/schedules/run", {"scheduleID": slow})
    case.check("a second Run now is refused while it runs",
               status == 409 and refused.get("code") == "run_in_progress",
               json.dumps([status, refused]))
    status, gone = phone.call("POST", "/mobile/schedules/run", {"scheduleID": "sch_gone"})
    case.check("Run now of an unknown task is 404",
               status == 404 and gone.get("code") == "unknown_task", json.dumps([status, gone]))
    return slow, running.get("sessionID")


def check_fires(case, service, home, phone):
    at = next_minute()
    status, body = phone.call("POST", "/mobile/schedules", {
        "name": "Soon", "projectID": "p", "presetID": "ok",
        "trigger": {"kind": "once", "at": at},
    })
    soon = (body.get("schedule") or {}).get("id", "")
    case.check("a Once task a minute away is saved", status == 200, json.dumps(body))
    fired = service.wait_for(
        lambda: (lambda last: last if last.get("status") == "done" else None)(
            listed(phone, soon).get("lastRun") or {}), timeout=100, poll=1.0) or {}
    case.check("it fires on its own at its time", fired.get("scheduledFor") == at,
               json.dumps(listed(phone, soon)))


def check_delete(case, home, phone, slow, session_id):
    status, body = phone.call("POST", "/mobile/schedules/delete", {"scheduleID": slow})
    case.check("delete removes the task",
               status == 200 and task(home, slow) is None, json.dumps(body))
    case.check("and its history", not os.path.exists(home.path("schedules", slow)))
    case.check("its Run Session stays",
               bool(session_id) and session_id in home.manifests(), str(session_id))
    status, _ = phone.call("POST", "/mobile/schedules/delete", {"scheduleID": slow})
    case.check("a second delete is 404", status == 404, str(status))


def body(case):
    home = case.home
    home.project("p", "sched", home.root)
    home.project("v", "virtual", "")
    state = home.state()
    state["projects"].append({"id": "g", "name": "Docs", "path": "", "parent_project_id": "p",
                              "is_folder": True})
    home.write_state(state)
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="slow", command="sleep 25", preset_id="slow")
    home.preset(label="Claude", command="claude", preset_id="claude")
    home.preset(label="Unattended", command="claude --dangerously-skip-permissions",
                preset_id="unattended")
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
    phone = Phone(home, port, token)
    local = LocalSocket(service.status().get("localSocket") or home.path("host.sock"))
    try:
        check_bootstrap(case, phone, local)
        task_id = check_create(case, home, phone)
        check_edit_pause_resume(case, service, home, local, task_id)
        check_paused_past_once(case, home, local)
        slow, session_id = check_run_now(case, service, home, phone, local)
        check_fires(case, service, home, phone)
        check_delete(case, home, phone, slow, session_id)
    finally:
        for session_id in list(home.manifests()):
            run_cli(home, ["rm", session_id], timeout=30)
        time.sleep(0.5)


run("schedules_writes", body)
