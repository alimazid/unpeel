"""A stopped Run Session keeps its output (ADR 0006), end to end.

One script task prints a line naming its Run (`UNPEEL_SCHEDULE_RUN_ID`)
and runs twice via Run now. Covered: once the second Run stops the first
as it comes up, `unpeel logs` on the first Run's Session still prints its
line; the same after the second Run is stopped by hand with `unpeel stop`;
the MCP `sessions read_output` action reads it from inside another
Session; a Session that is not a Run still loses its output on Stop (an
empty `output.bin`, no retention marker); and both Runs' output survives a
Host restart and the exited-journal compaction pass. Retention removing a
Run Session's directory, output included, is `schedules_retention`.

What the Mac app reads (#36), on both session-row builders (`/mobile` as a
paired phone sees it, `host.sock` as the app does): the stopped Runs' rows
carry `keptOutput: true` and a tail read of `/mobile/output` returns the
Run's line; the user's stopped Session's row carries no `keptOutput`.
"""

import base64
import datetime
import json
import os
import re
import subprocess
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import (  # noqa: E402
    BINARY, CRATES, host_certificate_pin, host_sock_request, mobile_port, mobile_request, run,
    run_cli,
)

ZONE = "America/New_York"
SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
HOST_BIN = os.path.join(os.path.dirname(BINARY), "unpeel-host")
# `%s` keeps the asserted line out of any echo of the command itself.
SCRIPT = "printf 'run-%s\\n' \"$UNPEEL_SCHEDULE_RUN_ID\""
USER_COMMAND = "printf 'user-%s\\n' output-dropped; exec cat"
USER_LINE = "user-output-dropped"


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


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


def logs(home, session_id):
    return cli(home, "logs", session_id).stdout


def run_now(case, service, home, task_id, number):
    """Run now; the Run id and its Session once the Run is done."""
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    if not case.check(f"Run {number}: Run now is accepted",
                      started.returncode == 0 and run_id.startswith("run_"), started.stderr):
        return None, None
    done = service.wait_for(
        lambda: run_entry(home, task_id, run_id).get("status") == "done"
        and run_entry(home, task_id, run_id),
        timeout=45,
    ) or run_entry(home, task_id, run_id)
    case.check(f"Run {number}: recorded done", done.get("status") == "done", json.dumps(done))
    return run_id, done.get("session_id")


def check_superseded(case, service, home, first):
    run_id, session_id = first
    stopped = service.wait_for(lambda: state_of(home, session_id) == "exited", timeout=30)
    if not case.check("the second Run stops the first Run's idle Session", bool(stopped),
                      f"{session_id}: {state_of(home, session_id)}"):
        return
    # The stop's helper thread drops scrollback (when it does) only after
    # the exited manifest lands: give it time to, or this read races it.
    service.read_for(1.5)
    shown = logs(home, session_id)
    case.check("logs on the superseded Run's Session prints its line",
               f"run-{run_id}" in shown, shown[-400:])


def check_stopped_by_hand(case, home, second):
    run_id, session_id = second
    stopped = cli(home, "stop", session_id)
    if not case.check("unpeel stop stops the latest Run's Session",
                      stopped.returncode == 0 and state_of(home, session_id) == "exited",
                      stopped.stderr):
        return
    shown = logs(home, session_id)
    case.check("logs on the Run stopped by hand prints its line",
               f"run-{run_id}" in shown, shown[-400:])


def launch_user_session(case, service, home):
    launched = cli(home, "new", "--preset", "talk", "--project", "p")
    ids = SESSION_ID.findall(launched.stdout)
    if not case.check("a Session of the user's own starts", launched.returncode == 0 and bool(ids),
                      launched.stderr):
        return None
    printed = service.wait_for(lambda: USER_LINE in logs(home, ids[0]), timeout=20)
    case.check("the user's Session prints its line", bool(printed), logs(home, ids[0])[-400:])
    return ids[0]


def check_read_output(case, home, caller, first):
    run_id, session_id = first
    read = cli(home, "mcp", "sessions", "read_output", f"session_id={session_id}",
               env={"UNPEEL_SESSION_ID": caller})
    case.check("MCP sessions read_output returns the stopped Run's line",
               read.returncode == 0 and f"run-{run_id}" in read.stdout,
               (read.stdout + read.stderr)[-400:])


def check_user_stop_drops(case, home, session_id):
    stopped = cli(home, "stop", session_id)
    if not case.check("unpeel stop stops the user's Session", stopped.returncode == 0,
                      stopped.stderr):
        return
    output = home.path("app-sessions", session_id, "output.bin")
    retention = home.path("app-sessions", session_id, "output-retention.json")
    size = os.path.getsize(output) if os.path.exists(output) else None
    case.check("Stop still drops the output of a Session that is not a Run",
               size == 0 and not os.path.exists(retention),
               f"size={size} retention={os.path.exists(retention)}")


def wires(service, home, token):
    """`(name, read)` per session-row builder; `read(path, query)` answers
    `(status, json)`."""
    port = mobile_port(home)

    def phone(path, query):
        if not query:
            return mobile_request(port, path, token, home=home)
        pairs = "&".join(f"{key}={value}" for key, value in query.items())
        return mobile_request(port, f"{path}?{pairs}", token, home=home)

    def app(path, query):
        socket_path = (service.status() or {}).get("localSocket")
        if not socket_path or not os.path.exists(socket_path):
            return None, {"error": "no host.sock"}
        return host_sock_request(socket_path, path, query)

    return [("phone", phone), ("host.sock", app)]


def session_row(read, session_id):
    status, boot = read("/mobile/bootstrap", {})
    if status != 200:
        return None
    return next((row for row in boot.get("sessions", []) if row.get("id") == session_id), None)


def check_kept_output(case, service, home, token, stopped_run, stage):
    """The Mac app's view of a stopped Run: `keptOutput` on its row, and the
    line from a tail read of `/mobile/output` (no offset)."""
    run_id, session_id = stopped_run
    for name, read in wires(service, home, token):
        row = service.wait_for(
            lambda: (session_row(read, session_id) or {}).get("keptOutput") and True,
            timeout=15,
        )
        case.check(f"{stage}, {name}: the stopped Run's row has keptOutput", bool(row),
                   json.dumps(session_row(read, session_id))[:600])
        status, tail = read("/mobile/output", {"session_id": session_id, "limit": "196608"})
        shown = base64.b64decode(tail.get("dataBase64") or "").decode(errors="replace")
        case.check(f"{stage}, {name}: a /mobile/output tail read returns the Run's line",
                   status == 200 and f"run-{run_id}" in shown, f"{status} {shown[-300:]}")


def check_user_row_keeps_nothing(case, service, home, token, session_id):
    for name, read in wires(service, home, token):
        row = service.wait_for(
            lambda: (session_row(read, session_id) or {}).get("status") == "exited"
            and session_row(read, session_id),
            timeout=15,
        )
        case.check(f"{name}: the user's stopped Session's row has no keptOutput",
                   bool(row) and "keptOutput" not in row, json.dumps(row)[:600])


def compact_exited_journals(home):
    return subprocess.run(
        [HOST_BIN, "__compact_output_journals__"],
        capture_output=True, text=True, timeout=30, cwd=CRATES,
        env=dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1"),
    )


def check_after_restart(case, service, home, runs):
    service.close()
    restarted = case.serve(env={"TZ": ZONE})
    if not case.check("the Host restarts", bool(restarted.ready(timeout=25)), restarted.log()):
        return
    compacted = compact_exited_journals(home)
    case.check("the Host compacts stopped Sessions' output", compacted.returncode == 0,
               compacted.stderr)
    for number, (run_id, session_id) in enumerate(runs, start=1):
        shown = logs(home, session_id)
        case.check(f"after a Host restart and compaction, Run {number}'s line is kept",
                   f"run-{run_id}" in shown, shown[-400:])


def body(case):
    home = case.home
    home.project("p", "output", home.root)
    home.preset(label="script", command=SCRIPT, preset_id="script")
    home.preset(label="talk", command=USER_COMMAND, preset_id="talk")
    token = home.pair_device()
    home.reserve_mobile_port()
    service = case.serve(env={"TZ": ZONE})
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    pinned = service.wait_for(lambda: host_certificate_pin(home), timeout=20)
    if not case.check("the Host serves /mobile", mobile_port(home) is not None and bool(pinned),
                      service.log()[-1500:]):
        return
    try:
        added = cli(home, "schedules", "add", "Report", "--project", "p", "--preset", "script",
                    "--once", tomorrow())
        task_id = added.stdout.strip()
        if not case.check("add prints the task id",
                          added.returncode == 0 and task_id.startswith("sch_"), added.stderr):
            return
        first = run_now(case, service, home, task_id, 1)
        second = run_now(case, service, home, task_id, 2)
        if not case.check("both Runs started a Session", bool(first[1] and second[1]),
                          json.dumps([first, second])):
            return
        check_superseded(case, service, home, first)
        check_kept_output(case, service, home, token, first, "superseded")
        check_stopped_by_hand(case, home, second)
        check_kept_output(case, service, home, token, second, "stopped by hand")
        caller = launch_user_session(case, service, home)
        if caller:
            check_read_output(case, home, caller, first)
            check_user_stop_drops(case, home, caller)
            check_user_row_keeps_nothing(case, service, home, token, caller)
        check_after_restart(case, service, home, [first, second])
    finally:
        for session_id in list(home.manifests()):
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_run_output", body)
