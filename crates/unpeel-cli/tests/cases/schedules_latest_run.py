"""PROJECTS lists only each task's latest Run, as the Host publishes it.

A Project holds five of the user's own stopped Sessions (the default
stopped window is five). One script task then runs three times via Run now.
Both session-row builders are read: `/mobile/bootstrap` as a paired phone
sees it (`unpeel serve`'s snapshot) and as the Mac app sees it over the
persistent `host.sock` (the disk-backed Controller runtime). Covered: every
Run Session carries `scheduleID`; the latest Run's (the Session of the
task's current Run) has `superseded: false` and the two older ones `true`;
the user's Sessions carry neither; and on both wires every Run Session and
all five of the user's stopped Sessions are still listed, so Runs never
crowd the user's rows out and a superseded Run stays openable by id. Then
the latest Run is replaced the way Resume leaves it on disk (a new id with
the same `spawned_by` and `created_at`, the logged one gone): the
replacement is the latest and the older two stay superseded. Last, a Run
of an Agent Preset task is stopped and resumed for real: the task's Run
history names the replacement id instead of the old one.
"""

import datetime
import json
import os
import shlex
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import (  # noqa: E402
    host_certificate_pin, host_sock_request, mobile_port, mobile_request, run, run_cli,
)

ZONE = "America/New_York"
USER_SESSIONS = [f"user-stopped-{n}" for n in range(1, 6)]
RUNS = 3

# Draws a loading screen, then Claude's idle prompt once its runtime has
# been observed (the screen tier classifies a screen that changes).
FAKE_CLAUDE = r'''
import os, select, termios, time, tty
tty.setraw(0, termios.TCSANOW)
def screen(text):
    os.write(1, ("\x1b[2J\x1b[H" + text.replace("\n", "\r\n")).encode())
screen("Claude Code\n\nStarting up")
time.sleep(2)
screen("Claude Code\n\n✻ Welcome back\n────\n❯\n────\n  ? for shortcuts")
while True:
    select.select([0], [], [])
    if not os.read(0, 4096):
        break
'''


def cli(home, *args):
    return run_cli(home, list(args), env={"TZ": ZONE}, timeout=45)


def tomorrow():
    later = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) + datetime.timedelta(days=1)
    return later.strftime("%Y-%m-%dT%H:%M")


def local_bootstrap(socket_path):
    """`GET /mobile/bootstrap` over `host.sock`, as the Mac app reads it."""
    return host_sock_request(socket_path, "/mobile/bootstrap")


def run_entry(home, task_id, run_id):
    shown = cli(home, "schedules", "history", task_id, "--json")
    try:
        entries = json.loads(shown.stdout)
    except ValueError:
        return {}
    return next((entry for entry in entries if entry.get("run_id") == run_id), {})


def run_three_times(case, service, home, task_id):
    sessions = []
    for number in range(1, RUNS + 1):
        started = cli(home, "schedules", "run", task_id)
        run_id = started.stdout.strip()
        if not case.check(f"Run {number}: Run now is accepted",
                          started.returncode == 0 and run_id.startswith("run_"), started.stderr):
            return sessions
        done = service.wait_for(
            lambda: run_entry(home, task_id, run_id).get("status") == "done"
            and run_entry(home, task_id, run_id),
            timeout=45,
        ) or run_entry(home, task_id, run_id)
        if not case.check(f"Run {number}: recorded done", done.get("status") == "done",
                          json.dumps(done)):
            return sessions
        sessions.append(done.get("session_id"))
    return sessions


def check_rows(case, wire, rows, task_id, runs):
    by_id = {row.get("id"): row for row in rows}
    latest, older = runs[-1], runs[:-1]
    case.check(f"{wire}: every Run Session names its task",
               all((by_id.get(run_id) or {}).get("scheduleID") == task_id for run_id in runs),
               json.dumps({run_id: by_id.get(run_id) for run_id in runs})[:800])
    case.check(f"{wire}: the latest Run's Session is not superseded",
               (by_id.get(latest) or {}).get("superseded") is False,
               json.dumps(by_id.get(latest))[:400])
    case.check(f"{wire}: the two older Run Sessions are superseded",
               all((by_id.get(run_id) or {}).get("superseded") is True for run_id in older),
               json.dumps({run_id: by_id.get(run_id) for run_id in older})[:800])
    case.check(f"{wire}: the user's own Sessions carry neither field",
               all(session_id in by_id
                   and "scheduleID" not in by_id[session_id]
                   and "superseded" not in by_id[session_id]
                   for session_id in USER_SESSIONS),
               json.dumps(sorted(by_id)))


def phone_rows_settled(phone, runs):
    """The phone's bootstrap once it lists every Run (the worker's snapshot
    follows its rescan)."""
    status, boot = phone()
    listed = {row.get("id") for row in boot.get("sessions", [])}
    return boot if status == 200 and set(runs) <= listed else None


def check_both_wires(case, service, task_id, runs, phone, stage):
    boot = service.wait_for(lambda: phone_rows_settled(phone, runs), timeout=15)
    if not case.check(f"{stage}: the phone's /mobile/bootstrap lists every Run", bool(boot),
                      json.dumps(phone()[1].get("sessions", []))[:800]):
        return
    check_rows(case, f"{stage}, phone", boot.get("sessions", []), task_id, runs)

    socket_path = (service.status() or {}).get("localSocket")
    if not case.check(f"{stage}: the Host serves host.sock",
                      bool(socket_path and os.path.exists(socket_path)),
                      json.dumps(service.status())):
        return
    status, local = local_bootstrap(socket_path)
    case.check(f"{stage}: the Mac app's wire reads /mobile/bootstrap", status == 200, str(status))
    check_rows(case, f"{stage}, host.sock", local.get("sessions", []), task_id, runs)


def history_sessions(home, task_id):
    shown = cli(home, "schedules", "history", task_id, "--json")
    try:
        return [entry.get("session_id") for entry in json.loads(shown.stdout)]
    except ValueError:
        return []


def write_fake_claude(home):
    """A fake `claude` (no integration) that draws Claude's idle prompt once
    it is up: the screen tier says it is ready, so its Run is done."""
    path = home.path("bin", "claude")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_CLAUDE)
    os.chmod(path, 0o755)
    return shlex.quote(path)


def check_resume_follows(case, service, home):
    """A real Resume relaunches a Run Session under a new id; the task's Run
    history follows it there, so the Run still opens it."""
    added = cli(home, "schedules", "add", "Agent", "--project", "p", "--preset", "agent",
                "--once", tomorrow())
    task_id = added.stdout.strip()
    if not case.check("an Agent Preset task is added", added.returncode == 0, added.stderr):
        return
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    done = service.wait_for(
        lambda: run_entry(home, task_id, run_id).get("status") == "done"
        and run_entry(home, task_id, run_id),
        timeout=60,
    ) or run_entry(home, task_id, run_id)
    original = done.get("session_id")
    if not case.check("its Run is done once the agent is ready",
                      done.get("status") == "done" and bool(original), json.dumps(done)):
        return
    stopped = cli(home, "stop", original)
    if not case.check("the Run's Session stops", stopped.returncode == 0, stopped.stderr):
        return
    # The fake leaves no conversation; give it the evidence Resume asks for.
    home.seed_resume_data(original)
    resumed = cli(home, "resume", original)
    replacement = resumed.stdout.strip()
    if not case.check("Resume relaunches it under a new id",
                      resumed.returncode == 0 and bool(replacement) and replacement != original,
                      resumed.stdout + resumed.stderr):
        return
    named = history_sessions(home, task_id)
    case.check("the task's Run history names the replacement, not the old id",
               replacement in named and original not in named, json.dumps(named))


def resume_latest_on_disk(case, home, task_id, runs):
    """Resume replaces a Session under a new id, keeping its `spawned_by`
    and `created_at` (`session_ops::restart_session_unlocked`). Leave that on
    disk without the resume machinery (a script Run has no resume evidence)."""
    latest = runs[-1]
    created = home.manifests().get(latest, {}).get("session", {}).get("created_at")
    removed = cli(home, "rm", latest)
    if not case.check("the latest Run's Session is removed", removed.returncode == 0
                      and latest not in home.manifests(), removed.stderr):
        return None
    replacement = "resumed-latest-run"
    home.session(replacement, label="Nightly", command="true", project_id="p",
                 extra_manifest={"session": {
                     "id": replacement, "project_id": "p", "label": "Nightly",
                     "command": "true", "created_at": created,
                     "spawned_by": f"schedule:{task_id}",
                 }})
    return runs[:-1] + [replacement]


def seed_user_sessions(home):
    """Five stopped Sessions of the user's own, older than every Run."""
    created = int(time.time() * 1000) - 3_600_000
    for offset, session_id in enumerate(USER_SESSIONS):
        home.session(session_id, label=session_id, command="true", project_id="p",
                     created_at=created + offset * 1000)


def body(case):
    home = case.home
    home.project("p", "latest", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="agent", command=write_fake_claude(home), preset_id="agent")
    seed_user_sessions(home)
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
    try:
        added = cli(home, "schedules", "add", "Nightly", "--project", "p", "--preset", "ok",
                    "--once", tomorrow())
        task_id = added.stdout.strip()
        if not case.check("add prints the task id",
                          added.returncode == 0 and task_id.startswith("sch_"), added.stderr):
            return
        runs = run_three_times(case, service, home, task_id)
        if not case.check(f"all {RUNS} Runs started a Session",
                          len(runs) == RUNS and all(runs), json.dumps(runs)):
            return
        phone = lambda: mobile_request(port, "/mobile/bootstrap", token, home=home)  # noqa: E731
        check_both_wires(case, service, task_id, runs, phone, "after three Runs")
        resumed = resume_latest_on_disk(case, home, task_id, runs)
        if resumed:
            check_both_wires(case, service, task_id, resumed, phone, "after a Resume")
        check_resume_follows(case, service, home)
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_latest_run", body)
