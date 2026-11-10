"""Fork-only (#81): a done agent Run keeps following its Session.

A Run is done at its agent's first idle, but its Session often works on.
Two fake agents (each a `claude` speaking OSC 7501, so the preset is an
Agent Preset) take their instructions and end their first turn with "Still
compiling in the background.":

* the busy one is driven on through its Session: a later turn moves the
  Run's end and snippet to its reply and the Run stays done; it then sends
  `sessions report` (from inside the Session, to the Session marked Super
  Agent) with status blocked, which lands on the Run record and in
  `list_schedule_runs`; a done report's turn ends the Run for good, and a
  turn after it changes nothing;
* the quiet one never reports and never works again: its Run stays as its
  first idle left it while its Session sits live, and after its agent
  exits.
"""

import base64
import datetime
import json
import os
import re
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, run, run_cli  # noqa: E402
from hook_cancellation import control, fixture_started  # noqa: E402

ZONE = "America/New_York"
SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
QUIT = "QUIT-FAKE-AGENT"
FIRST_REPLY = "Still compiling in the background."
LATER_REPLY = "Build 135 installed."
BLOCKED = "Waiting on the signing key"
FINAL = "Build 135 installed and verified"

FAKE_AGENT = r'''
import base64, json, os, subprocess, termios, time, tty
QUIT, UNPEEL, HOME, ROUTER = %(quit)r, %(unpeel)r, %(home)r, %(router)r
log_dir = os.path.join(HOME, "agent-logs")
os.makedirs(log_dir, exist_ok=True)
log_path = os.path.join(log_dir, os.environ.get("UNPEEL_SESSION_ID", "unknown") + ".jsonl")
def log(**entry):
    entry["t"] = time.time()
    with open(log_path, "a") as handle:
        handle.write(json.dumps(entry) + "\n")
tty.setraw(0, termios.TCSANOW)
def status(state, msg=None):
    pairs = "state=" + state + ":app=fake"
    if msg:
        pairs += ":msg=" + base64.b64encode(msg.encode()).decode()
    os.write(1, ("\x1b]7501;" + pairs + "\x1b\\").encode())
def report(state, summary):
    """`sessions report` from inside the Run Session: its ancestry is the caller."""
    body = json.dumps({"session_id": ROUTER, "status": state, "summary": summary})
    env = dict(os.environ, UNPEEL_HOME=HOME, UNPEEL_TEST="1")
    done = subprocess.run([UNPEEL, "mcp", "sessions", "report", "--json", body],
                          capture_output=True, text=True, env=env, timeout=40)
    log(event="report", status=state, code=done.returncode,
        out=done.stdout[-300:], err=done.stderr[-300:])
def turn(reply, reporting=None):
    log(event="turn", reply=reply)
    status("working", "Working on it")
    time.sleep(1.5)
    if reporting:
        report(*reporting)
        time.sleep(1.0)
    status("done", reply)
os.write(1, b"\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\r\n")
time.sleep(2)
status("idle")
log(event="ready")
TURNS = {
    b"AGAIN": (%(later)r, None),
    b"BLOCK": ("Paused for the key.", ("blocked", %(blocked)r)),
    b"FINISH": ("Reported done.", ("done", %(final)r)),
    b"LATER": ("After the final word.", None),
}
pending, prompted = b"", False
while True:
    data = os.read(0, 4096)
    if not data or QUIT.encode() in data:
        break
    pending += data
    if not prompted:
        end = pending.find(b"\x1b[201~")
        if end >= 0 and b"\r" in pending[end:]:
            prompted, pending = True, b""
            turn(%(first)r)
        continue
    for word, (reply, reporting) in TURNS.items():
        if word in pending:
            pending = b""
            turn(reply, reporting)
'''


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


def detail(result):
    return (result.stderr or result.stdout)[-500:]


def write_fake(home, kind, router):
    path = home.path("agents", kind, "claude")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_AGENT % {
            "quit": QUIT, "unpeel": BINARY, "home": home.root, "router": router,
            "first": FIRST_REPLY, "later": LATER_REPLY, "blocked": BLOCKED, "final": FINAL})
    os.chmod(path, 0o755)


def tomorrow():
    later = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) + datetime.timedelta(days=1)
    return later.strftime("%Y-%m-%dT%H:%M")


def run_entry(home, task_id, run_id):
    try:
        entries = json.loads(cli(home, "schedules", "history", task_id, "--json").stdout)
    except ValueError:
        return {}
    return next((entry for entry in entries if entry.get("run_id") == run_id), {})


def run_lines(home, task_id, run_id):
    try:
        with open(home.path("schedules", task_id, "runs.jsonl")) as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        return []
    return [line for line in lines if line.get("run_id") == run_id]


def agent_log(home, session_id):
    try:
        with open(home.path("agent-logs", f"{session_id}.jsonl")) as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        return []


def wait_entry(service, home, task_id, run_id, predicate, timeout=40):
    found = service.wait_for(lambda: predicate(run_entry(home, task_id, run_id))
                             and run_entry(home, task_id, run_id), timeout=timeout)
    return found or run_entry(home, task_id, run_id)


def start(case, service, home, kind):
    """Add the kind's task, Run it now, and wait for its first idle."""
    added = cli(home, "schedules", "add", kind.title(), "--project", "p", "--preset", kind,
                "--once", tomorrow(), "--instructions", "build and install the daily build")
    task_id = added.stdout.strip()
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    if not case.check(f"{kind}: the task is added and Run now starts a Run",
                      task_id.startswith("sch_") and run_id.startswith("run_"),
                      detail(added) + detail(started)):
        return task_id, run_id, ""
    entry = wait_entry(service, home, task_id, run_id, lambda entry: entry.get("session_id"))
    session_id = entry.get("session_id") or ""
    if session_id:
        fixture_started(case, service, home.path("app-sessions", session_id))
    return task_id, run_id, session_id


def check_first_idle(case, service, home, kind, task_id, run_id):
    done = wait_entry(service, home, task_id, run_id,
                      lambda entry: entry.get("status") in ("done", "failed", "needs_you"))
    case.check(f"{kind}: the Run is done at its agent's first idle, with that reply",
               done.get("status") == "done" and done.get("snippet") == FIRST_REPLY,
               json.dumps(done))
    return done


def drive(home, session_id, word):
    control(home, session_id, word + "\r")


def check_later_turn(case, service, home, task_id, run_id, session_id, first):
    drive(home, session_id, "AGAIN")
    later = wait_entry(service, home, task_id, run_id,
                       lambda entry: entry.get("snippet") == LATER_REPLY)
    case.check("busy: a later turn moves the Run's snippet to its reply",
               later.get("snippet") == LATER_REPLY, json.dumps(later))
    case.check("busy: and its end past the first idle; the Run stays done",
               later.get("status") == "done"
               and (later.get("ended_at_ms") or 0) > (first.get("ended_at_ms") or 0),
               json.dumps({"first": first, "later": later}))


def check_blocked_report(case, service, home, task_id, run_id, session_id, router):
    drive(home, session_id, "BLOCK")
    blocked = wait_entry(service, home, task_id, run_id,
                         lambda entry: (entry.get("report") or {}).get("status") == "blocked")
    sent = [entry for entry in agent_log(home, session_id) if entry.get("event") == "report"]
    case.check("busy: its blocked report from inside the Session is accepted",
               bool(sent) and sent[-1].get("code") == 0, json.dumps(sent)[-500:])
    report = blocked.get("report") or {}
    case.check("busy: the blocked report lands on the Run record; the Run stays done",
               report.get("status") == "blocked" and report.get("summary") == BLOCKED
               and blocked.get("status") == "done", json.dumps(blocked))
    listed = cli(home, "mcp", "workspace", "list_schedule_runs", f"schedule_id={task_id}",
                 env={"UNPEEL_SESSION_ID": router})
    try:
        runs = json.loads(listed.stdout).get("runs", [])
    except ValueError:
        runs = []
    row = next((row for row in runs if row.get("runID") == run_id), {})
    case.check("busy: list_schedule_runs shows the Run done with its blocked report",
               row.get("status") == "done"
               and (row.get("report") or {}).get("status") == "blocked"
               and (row.get("report") or {}).get("summary") == BLOCKED,
               detail(listed))


def check_final_word(case, service, home, task_id, run_id, session_id):
    drive(home, session_id, "FINISH")
    final = wait_entry(service, home, task_id, run_id,
                       lambda entry: (entry.get("report") or {}).get("status") == "done"
                       and entry.get("snippet") == "Reported done.")
    report = final.get("report") or {}
    case.check("busy: a done report lands, and the Run ends with the turn that sent it",
               report.get("summary") == FINAL and final.get("snippet") == "Reported done."
               and (final.get("ended_at_ms") or 0) >= (report.get("at_ms") or 1 << 62),
               json.dumps(final))
    lines = len(run_lines(home, task_id, run_id))
    drive(home, session_id, "LATER")
    service.wait_for(lambda: any(entry.get("reply") == "After the final word."
                                 for entry in agent_log(home, session_id)), timeout=15)
    service.read_for(5)
    after = run_entry(home, task_id, run_id)
    case.check("busy: after the done report's turn, a later turn changes nothing",
               after == final and len(run_lines(home, task_id, run_id)) == lines,
               json.dumps({"final": final, "after": after}))


def check_quiet(case, service, home, task_id, run_id, session_id, first):
    lines = len(run_lines(home, task_id, run_id))
    case.check("quiet: its Run is as its first idle left it while its Session sits live",
               run_entry(home, task_id, run_id) == first
               and home.manifests().get(session_id, {}).get("state") == "running",
               json.dumps(run_entry(home, task_id, run_id)))
    control(home, session_id, QUIT)
    service.wait_for(lambda: os.path.exists(home.path("app-sessions", session_id, "startup-exit")),
                     timeout=15)
    service.read_for(4)
    case.check("quiet: after its agent exits the Run is still done, nothing appended",
               run_entry(home, task_id, run_id) == first
               and len(run_lines(home, task_id, run_id)) == lines,
               json.dumps(run_lines(home, task_id, run_id))[-600:])


def body(case):
    home = case.home
    home.project("p", "runs", home.root)
    home.preset(label="cat", command="cat", preset_id="cat")
    for kind in ("busy", "quiet"):
        home.preset(label=kind, command=home.path("agents", kind, "claude"), preset_id=kind)
    service = case.serve(env={"HOME": home.root, "SHELL": "/bin/bash", "TZ": ZONE})
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    try:
        launched = cli(home, "new", "--preset", "cat", "--project", "p")
        ids = SESSION_ID.findall(launched.stdout)
        if not case.check("the Super Agent's Session starts", bool(ids), detail(launched)):
            return
        router = ids[0]
        state = home.state()
        state["super_agent"] = {"session_id": router, "since": int(time.time() * 1000)}
        home.write_state(state)
        for kind in ("busy", "quiet"):
            write_fake(home, kind, router)
        runs = {kind: start(case, service, home, kind) for kind in ("busy", "quiet")}
        if not all(session_id for _, _, session_id in runs.values()):
            return
        first = {kind: check_first_idle(case, service, home, kind, *runs[kind][:2])
                 for kind in ("busy", "quiet")}
        task_id, run_id, session_id = runs["busy"]
        check_later_turn(case, service, home, task_id, run_id, session_id, first["busy"])
        check_blocked_report(case, service, home, task_id, run_id, session_id, router)
        check_final_word(case, service, home, task_id, run_id, session_id)
        check_quiet(case, service, home, *runs["quiet"], first["quiet"])
    finally:
        for session_id in list(home.manifests()):
            try:
                control(home, session_id, QUIT)
            except OSError:
                pass
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_follow", body)
