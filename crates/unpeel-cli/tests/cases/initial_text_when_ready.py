"""`session.create` with `initialTextWhen: "agentReady"` types the initial
text only once the agent is really ready for input.

Three fake agents start at once on one Host, each logging (with its own
clock) when it became ready and every byte it received:

* a fake `claude` (no integration installed) that shows a loading screen,
  then draws Claude's real idle prompt: the screen tier releases the text;
* a plain program that reports `OSC 7501` idle after a delay: the program
  status tier releases the text;
* a program that never becomes ready: nothing is typed, even though the Host
  reads the Running Session as "idle" by default, and the outcome is
  recorded as a readiness timeout.

A fourth fake `claude` created without the field shows today's default:
the text is typed as soon as the Session's socket exists, before the prompt.
"""

import json
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import mobile_request, run, run_cli  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402

TEXT = "run the morning briefing"
READY_DELAY_SECONDS = 4
# The test Host's readiness budget (`UNPEEL_AGENT_READY_TIMEOUT_MS`, honoured
# only under UNPEEL_TEST=1). Production waits 120 s.
READY_TIMEOUT_MS = 30_000
QUIT = "QUIT-FAKE-AGENT"

FAKE_AGENT = r'''
import json, os, select, termios, time, tty
KIND = %(kind)r
DELAY = %(delay)r
QUIT = %(quit)r
log_dir = os.path.join(os.environ["HOME"], "ready-logs")
os.makedirs(log_dir, exist_ok=True)
log_path = os.path.join(log_dir, os.environ.get("UNPEEL_SESSION_ID", "unknown") + ".jsonl")
def log(**entry):
    entry["t"] = time.time()
    with open(log_path, "a") as handle:
        handle.write(json.dumps(entry) + "\n")
# TCSANOW keeps input that arrived before the agent started (the default
# create path can type that early); TCSAFLUSH would silently drop it.
tty.setraw(0, termios.TCSANOW)
def screen(text):
    os.write(1, ("\x1b[2J\x1b[H" + text.replace("\n", "\r\n")).encode())
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\r\n")
screen("Claude Code\n\nStarting up")
ready_at = None if DELAY is None else time.time() + DELAY
while True:
    timeout = None if ready_at is None else max(0.0, ready_at - time.time())
    readable, _, _ = select.select([0], [], [], timeout)
    if not readable:
        if KIND == "screen":
            screen("Claude Code\n\n✻ Welcome back\n────\n❯\n────\n  ? for shortcuts")
        else:
            os.write(1, b"\x1b]7501;state=idle:app=reporter\x1b\\")
        log(event="ready")
        ready_at = None
        continue
    data = os.read(0, 4096)
    if not data or data == QUIT.encode():
        break
    log(event="input", data=data.decode("utf-8", "replace"))
'''


def write_fake(home, name, kind, delay):
    path = home.path("bin", name)
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_AGENT % {
            "kind": kind, "delay": delay, "quit": QUIT,
        })
    os.chmod(path, 0o755)
    return shlex.quote(path)


def fake_log(home, session_id):
    try:
        with open(home.path("ready-logs", f"{session_id}.jsonl")) as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        return []


def first(entries, event):
    return next((entry for entry in entries if entry["event"] == event), None)


def outcome(home, session_id):
    return read_json(home.path("app-sessions", session_id, "initial-text.json"))


def body(case):
    home = case.home
    home.project("p", "ready", home.root)
    environment = {
        "HOME": home.root,
        "SHELL": "/bin/bash",
        "PATH": home.path("bin") + os.pathsep + os.environ["PATH"],
        "UNPEEL_AGENT_READY_TIMEOUT_MS": str(READY_TIMEOUT_MS),
    }
    os.makedirs(home.path("bin"), exist_ok=True)
    claude = write_fake(home, "claude", "screen", READY_DELAY_SECONDS)
    reporter = write_fake(home, "reporter", "program", READY_DELAY_SECONDS)
    sleeper = write_fake(home, "sleeper", "never", None)
    token = home.pair_device()
    port = home.reserve_mobile_port()
    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=25)), service.log()):
        return
    listed = run_cli(home, ["integrations", "list", "--json"], env=environment)
    rows = json.loads(listed.stdout or "[]")
    case.check("no Claude integration is installed in the private HOME (screen tier only)",
               any(row["runtime"] == "claude" and not row["installed"] for row in rows),
               listed.stdout[:200])

    def create(command, when):
        request = {
            "projectID": "p",
            "command": command,
            "initialText": TEXT,
            "initialTextSubmitMode": "pasteAndSubmit",
        }
        if when:
            request["initialTextWhen"] = when
        status, created = mobile_request(port, "/mobile/sessions", token, method="POST",
                                         body=request, timeout=15)
        return status, created.get("sessionID")

    created = {
        "screen": create(claude, "agentReady"),
        "program": create(reporter, "agentReady"),
        "never": create(sleeper, "agentReady"),
        "attached": create(claude, None),
    }
    case.check("every create returns its receipt at once",
               all(status == 200 and sid for status, sid in created.values()), str(created))
    ids = {name: sid for name, (_, sid) in created.items() if sid}
    try:
        for name, sid in ids.items():
            if not fixture_started(case, service, home.path("app-sessions", sid)):
                return
        never = ids.get("never")

        def activity(sid):
            return read_json(home.path("activity-state.json")).get("sessions", {}).get(sid, {})

        case.check("a never-ready agent is waited on, not typed into",
                   bool(service.wait_for(lambda: outcome(home, never).get("state") == "waiting",
                                         timeout=15)), str(outcome(home, never)))
        case.check("while the Host reads its Running Session as the default idle",
                   bool(service.wait_for(lambda: activity(never).get("raw_status") == "idle",
                                         timeout=15)), str(activity(never)))

        for name, signal in (("screen", "screen"), ("program", "program")):
            sid = ids.get(name)
            typed = service.wait_for(lambda: first(fake_log(home, sid), "input"), timeout=45)
            entries = fake_log(home, sid)
            ready = first(entries, "ready")
            case.check(f"{name}: the text is typed only after the agent is ready",
                       bool(typed) and bool(ready) and typed["t"] >= ready["t"]
                       and typed["data"] == TEXT + "\r", str(entries))
            recorded = service.wait_for(
                lambda: outcome(home, sid) if outcome(home, sid).get("state") == "delivered" else None,
                timeout=10)
            case.check(f"{name}: the outcome names the {signal} tier",
                       bool(recorded) and recorded.get("signal") == signal
                       and recorded.get("when") == "agent_ready", str(outcome(home, sid)))

        attached = ids.get("attached")
        typed = service.wait_for(lambda: first(fake_log(home, attached), "input"), timeout=30)
        entries = fake_log(home, attached)
        ready = first(entries, "ready")
        case.check("default (attached): the text is typed as soon as the socket exists",
                   bool(typed) and (ready is None or typed["t"] < ready["t"]), str(entries))
        case.check("default (attached): the outcome is delivered with no readiness tier",
                   outcome(home, attached).get("state") == "delivered"
                   and outcome(home, attached).get("when") == "attached"
                   and "signal" not in outcome(home, attached), str(outcome(home, attached)))

        timed_out = service.wait_for(
            lambda: outcome(home, never).get("state") == "readiness_timeout",
            timeout=READY_TIMEOUT_MS / 1000 + 20)
        case.check("never ready: the outcome is a readiness timeout",
                   bool(timed_out), str(outcome(home, never)))
        service.read_for(1.0)
        case.check("never ready: nothing was typed", first(fake_log(home, never), "input") is None,
                   str(fake_log(home, never)))
    finally:
        for sid in ids.values():
            try:
                control(home, sid, QUIT)
            except OSError:
                pass
            run_cli(home, ["rm", sid], env=environment, timeout=45)


run("initial_text_when_ready", body)
