"""Scheduled Tasks on Agent Presets, end to end through `unpeel serve`.

A task with instructions launches its preset exactly as typed, waits for the
agent's first readiness signal, types the instructions, and follows the Run
through the Host's own activity rows. Four fake agents (each a `claude`, so
the preset is an Agent Preset; no integration is installed, so no hooks)
enable bracketed paste like real agents and record every byte they get:

* a screen-tier agent draws Claude's idle prompt, a spinner, then its idle
  prompt under a reply: the Run is done, with the reply as its snippet;
* an OSC 7501 agent reports idle, working, then done with a summary: the Run
  is done with that summary;
* an agent that stops at a question (7501 `blocked`): the Run needs you, Run
  now is refused while it does, and answering it finishes the Run;
* an agent that never becomes ready: the Run fails to start, nothing is
  typed, and its Session is left open.

The instructions run over several lines and must reach the agent as one
submission: one bracketed paste, then Enter. A task on an Agent Preset with
no instructions is done once its agent is ready, with nothing typed. Then a
stand-in native app takes over notification edges and the screen-tier agent
runs again: rescan never counts a screen-tier edge as finished in either
mode, yet the Run is done, so the Runs follow the rows. `add` and `edit
--instructions` are refused for a preset that is not an agent.
"""

import datetime
import json
import os
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402
from hook_cancellation import control, fixture_started  # noqa: E402

ZONE = "America/New_York"
INSTRUCTIONS = "run the morning briefing\nthen file the notes:\n\n- calendar\n- reviews"
PASTE_START = "\x1b[200~"
QUIT = "QUIT-FAKE-AGENT"
# The test Host's readiness budget (`UNPEEL_AGENT_READY_TIMEOUT_MS`, honoured
# only under UNPEEL_TEST=1). Production waits 120 s.
READY_TIMEOUT_MS = 15_000

FAKE_AGENT = r'''
import base64, json, os, termios, time, tty
KIND = %(kind)r
QUIT = %(quit)r
READY_AFTER = 3.0
log_dir = os.path.join(os.environ["HOME"], "agent-logs")
os.makedirs(log_dir, exist_ok=True)
log_path = os.path.join(log_dir, os.environ.get("UNPEEL_SESSION_ID", "unknown") + ".jsonl")
def log(**entry):
    entry["t"] = time.time()
    with open(log_path, "a") as handle:
        handle.write(json.dumps(entry) + "\n")
tty.setraw(0, termios.TCSANOW)
def screen(text):
    os.write(1, ("\x1b[2J\x1b[H" + text.replace("\n", "\r\n")).encode())
def report(state, msg=None):
    pairs = "state=" + state + ":app=fake"
    if msg:
        pairs += ":msg=" + base64.b64encode(msg.encode()).decode()
    os.write(1, ("\x1b]7501;" + pairs + "\x1b\\").encode())
def prompt_box(above):
    return "Claude Code\n\n" + above + "────\n❯\n────\n  ? for shortcuts"
def echo(text):
    lines = text.split("\n")
    return "❯ " + "\n  ".join(lines) + "\n\n"
# Like a real agent TUI: ask for bracketed paste, so pasted newlines are text.
os.write(1, b"\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\r\n")
screen("Claude Code\n\nStarting up")
time.sleep(READY_AFTER)
if KIND == "screen":
    screen(prompt_box("✻ Welcome back\n"))
elif KIND in ("program", "question"):
    report("idle")
if KIND != "never":
    log(event="ready")
answered = False
def submit(text, raw):
    """One Enter outside a paste: the composer's text is submitted."""
    global answered
    log(event="submit", text=text, raw=raw)
    if KIND == "screen":
        screen(prompt_box(echo(text) + "✻ Levitating… (2s · esc to interrupt)\n"))
        time.sleep(4)
        screen(prompt_box(echo(text) + "⏺ Morning briefing ready: 3 meetings, 2 reviews.\n\n✻ Brewed for 4s\n"))
    elif KIND == "program":
        report("working", "Reading the calendar")
        time.sleep(3)
        report("done", "Briefing sent to the team")
    elif KIND == "question" and not answered:
        report("working", "Reading the calendar")
        time.sleep(2)
        report("blocked", "Send it to the whole team?")
        answered = True
    elif KIND == "question":
        report("working", "Sending")
        time.sleep(2)
        report("done", "Sent after your answer")
pending, composer, raw, pasting = b"", b"", b"", False
while True:
    data = os.read(0, 4096)
    if not data or data == QUIT.encode():
        break
    raw += data
    pending += data
    while pending:
        if pasting:
            end = pending.find(b"\x1b[201~")
            if end < 0:
                composer, pending = composer + pending, b""
                break
            composer, pending, pasting = composer + pending[:end], pending[end + 6:], False
            continue
        start, enter = pending.find(b"\x1b[200~"), pending.find(b"\r")
        if start >= 0 and (enter < 0 or start < enter):
            composer, pending, pasting = composer + pending[:start], pending[start + 6:], True
            continue
        if enter < 0:
            composer, pending = composer + pending, b""
            break
        text = (composer + pending[:enter]).decode("utf-8", "replace")
        composer, pending = b"", pending[enter + 1:]
        # A second Enter on an empty composer submits nothing, as in a real agent.
        if text.strip():
            submit(text, raw.decode("utf-8", "replace"))
            raw = b""
'''


def write_fake(home, kind):
    folder = home.path("agents", kind)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "claude")
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_AGENT % {"kind": kind, "quit": QUIT})
    os.chmod(path, 0o755)
    return path


def fake_log(home, session_id):
    try:
        with open(home.path("agent-logs", f"{session_id}.jsonl")) as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        return []


def first(entries, event):
    return next((entry for entry in entries if entry["event"] == event), None)


def submissions(entries):
    return [entry for entry in entries if entry["event"] == "submit"]


def cli(home, *args, env=None):
    return run_cli(home, list(args), env=dict({"TZ": ZONE}, **(env or {})), timeout=45)


def tomorrow():
    later = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)) + datetime.timedelta(days=1)
    return later.strftime("%Y-%m-%dT%H:%M")


def history(home, task_id):
    try:
        return json.loads(cli(home, "schedules", "history", task_id, "--json").stdout)
    except ValueError:
        return []


def listed(home, task_id):
    try:
        tasks = json.loads(cli(home, "schedules", "list", "--json").stdout or "[]")
    except ValueError:
        return {}
    return next((task for task in tasks if task.get("id") == task_id), {})


def run_entry(home, task_id, run_id):
    return next((entry for entry in history(home, task_id) if entry.get("run_id") == run_id), {})


def phases(home, task_id, run_id):
    """Every line the Host appended for the Run, oldest first."""
    try:
        with open(home.path("schedules", task_id, "runs.jsonl")) as handle:
            lines = [json.loads(line) for line in handle if line.strip()]
    except (OSError, ValueError):
        return []
    return [(line.get("status"), line.get("phase")) for line in lines if line.get("run_id") == run_id]


def wait_status(service, home, task_id, run_id, statuses, timeout):
    found = service.wait_for(
        lambda: run_entry(home, task_id, run_id).get("status") in statuses
        and run_entry(home, task_id, run_id),
        timeout=timeout,
    )
    return found or run_entry(home, task_id, run_id)


def add_task(case, home, name, preset, instructions=INSTRUCTIONS):
    extra = ["--instructions", instructions] if instructions is not None else []
    added = cli(home, "schedules", "add", name, "--project", "p", "--preset", preset,
                "--once", tomorrow(), *extra)
    task_id = added.stdout.strip()
    case.check(f"{name}: add accepts the task", added.returncode == 0 and task_id.startswith("sch_"),
               added.stderr)
    return task_id


def run_now(case, home, name, task_id):
    started = cli(home, "schedules", "run", task_id)
    run_id = started.stdout.strip()
    case.check(f"{name}: Run now answers with a Run id",
               started.returncode == 0 and run_id.startswith("run_"), started.stderr)
    return run_id


def check_refusals(case, home):
    refused = cli(home, "schedules", "add", "Script", "--project", "p", "--preset", "ok",
                  "--once", tomorrow(), "--instructions", INSTRUCTIONS)
    case.check("add: instructions on a preset that is not an agent are refused",
               refused.returncode != 0 and "not an Agent Preset" in refused.stderr,
               refused.stderr or refused.stdout)
    huge = cli(home, "schedules", "add", "Huge", "--project", "p", "--preset", "screen",
               "--once", tomorrow(), "--instructions", "x" * (256 * 1024 + 1))
    case.check("add: instructions over 256 KiB are refused",
               huge.returncode != 0 and "256 KiB" in huge.stderr, huge.stderr[:200])
    names = [task.get("name") for task in home.state().get("schedules", [])]
    case.check("neither refused task was saved", "Script" not in names and "Huge" not in names,
               str(names))


def check_edit(case, home):
    task_id = add_task(case, home, "Editable", "screen", instructions=None)
    edited = cli(home, "schedules", "edit", task_id, "--instructions", "summarize the inbox")
    case.check("edit: sets instructions on an Agent Preset task",
               edited.returncode == 0
               and listed(home, task_id).get("instructions") == "summarize the inbox",
               edited.stderr or json.dumps(listed(home, task_id)))
    huge = cli(home, "schedules", "edit", task_id, "--instructions", "x" * (256 * 1024 + 1))
    case.check("edit: instructions over 256 KiB are refused",
               huge.returncode != 0 and "256 KiB" in huge.stderr, huge.stderr[:200])
    to_script = cli(home, "schedules", "edit", task_id, "--preset", "ok")
    case.check("edit: a preset that cannot take the task's instructions is refused",
               to_script.returncode != 0 and "not an Agent Preset" in to_script.stderr
               and listed(home, task_id).get("preset_id") == "screen", to_script.stderr)
    removed = cli(home, "schedules", "edit", task_id, "--instructions", "")
    case.check("edit: --instructions '' removes them",
               removed.returncode == 0 and listed(home, task_id).get("instructions") is None,
               removed.stderr)
    script_id = add_task(case, home, "Plain script", "ok", instructions=None)
    refused = cli(home, "schedules", "edit", script_id, "--instructions", "brief me")
    case.check("edit: instructions on a preset that is not an agent are refused",
               refused.returncode != 0 and "not an Agent Preset" in refused.stderr
               and listed(home, script_id).get("instructions") is None, refused.stderr)
    cli(home, "schedules", "rm", task_id)
    cli(home, "schedules", "rm", script_id)


def check_typed_once(case, home, label, session_id):
    """The instructions reach the agent as one submission, after it is ready."""
    entries = fake_log(home, session_id)
    sent, ready = submissions(entries), first(entries, "ready")
    case.check(f"{label}: the instructions were typed once the agent was ready",
               bool(sent) and bool(ready) and sent[0]["t"] >= ready["t"], str(entries)[:400])
    case.check(f"{label}: all their lines arrive as one submission, by bracketed paste",
               bool(sent) and sent[0]["text"] == INSTRUCTIONS and PASTE_START in sent[0]["raw"],
               json.dumps(sent)[:400])
    return sent


def check_done(case, service, home, label, task_id, run_id, snippet):
    done = wait_status(service, home, task_id, run_id, ("done", "failed", "failed_to_start",
                                                        "needs_you"), timeout=60)
    case.check(f"{label}: the Run is done", done.get("status") == "done", json.dumps(done))
    case.check(f"{label}: the Run log stores its snippet",
               (done.get("snippet") or "").startswith(snippet), json.dumps(done))
    seen = [phase for _, phase in phases(home, task_id, run_id)]
    ordered = [phase for phase in ("launching", "prompted", "working") if phase in seen]
    case.check(f"{label}: it went launching, prompted, working, done",
               ordered == ["launching", "prompted", "working"]
               and seen.index("prompted") < seen.index("working"), str(phases(home, task_id, run_id)))
    session_id = done.get("session_id") or ""
    sent = check_typed_once(case, home, label, session_id)
    case.check(f"{label}: nothing else was submitted", len(sent) == 1, json.dumps(sent)[:400])
    return session_id


def check_needs_you(case, service, home, task_id, run_id):
    asked = wait_status(service, home, task_id, run_id, ("needs_you", "done", "failed"), timeout=60)
    case.check("question: the Run needs you", asked.get("status") == "needs_you", json.dumps(asked))
    refused = cli(home, "schedules", "run", task_id)
    case.check("question: Run now is refused while it needs you",
               refused.returncode != 0 and "in progress" in refused.stderr, refused.stderr)
    service.read_for(3)
    case.check("question: needs you has no timeout and nothing is killed",
               run_entry(home, task_id, run_id).get("status") == "needs_you"
               and home.manifests().get(asked.get("session_id") or "", {}).get("state") == "running",
               json.dumps(run_entry(home, task_id, run_id)))
    control(home, asked.get("session_id"), "1\r")
    done = wait_status(service, home, task_id, run_id, ("done", "failed"), timeout=30)
    case.check("question: answering it lets a later done edge finish the Run",
               done.get("status") == "done" and done.get("snippet") == "Sent after your answer",
               json.dumps(done))
    check_typed_once(case, home, "question", asked.get("session_id") or "")


def check_never_ready(case, service, home, task_id, run_id):
    never = wait_status(service, home, task_id, run_id, ("failed_to_start", "failed", "done"),
                        timeout=READY_TIMEOUT_MS / 1000 + 30)
    case.check("never ready: the Run fails to start", never.get("status") == "failed_to_start",
               json.dumps(never))
    session_id = never.get("session_id") or ""
    case.check("never ready: its Session is left open",
               home.manifests().get(session_id, {}).get("state") == "running")
    case.check("never ready: nothing was typed", not submissions(fake_log(home, session_id)),
               str(fake_log(home, session_id)))


def check_without_instructions(case, service, home, task_id, run_id):
    done = wait_status(service, home, task_id, run_id, ("done", "failed", "failed_to_start"),
                       timeout=30)
    case.check("no instructions: the Run is done once the agent is ready",
               done.get("status") == "done" and done.get("snippet") is None
               and done.get("prompted_at_ms") is None, json.dumps(done))
    session_id = done.get("session_id") or ""
    entries = fake_log(home, session_id)
    ready = first(entries, "ready")
    case.check("no instructions: it finished after the agent's readiness signal",
               bool(ready) and done.get("ended_at_ms", 0) / 1000 >= ready["t"] - 0.5, str(entries))
    service.read_for(1.5)
    case.check("no instructions: nothing was typed and its Session stays live for the user",
               not submissions(fake_log(home, session_id))
               and home.manifests().get(session_id, {}).get("state") == "running",
               str(fake_log(home, session_id)))


def check_native_owner(case, service, home, task_id):
    app = case.app()
    owned = service.wait_for(lambda: service.status().get("nativeAppOwnsControllers") is True,
                             timeout=30)
    if not case.check("a stand-in native app takes over notification edges", bool(owned),
                      json.dumps(service.status())[:300]):
        return
    run_id = run_now(case, home, "screen (native app present)", task_id)
    check_done(case, service, home, "screen (native app present)", task_id, run_id,
               "Morning briefing ready")
    app.close()


def body(case):
    home = case.home
    home.project("p", "agents", home.root)
    home.preset(label="ok", command="true", preset_id="ok")
    for kind in ("screen", "program", "question", "never"):
        home.preset(label=kind, command=write_fake(home, kind), preset_id=kind)
    environment = {
        "HOME": home.root,
        "SHELL": "/bin/bash",
        "TZ": ZONE,
        "UNPEEL_AGENT_READY_TIMEOUT_MS": str(READY_TIMEOUT_MS),
    }
    service = case.serve(env=environment)
    if not case.check("the Host starts with no app", bool(service.ready(timeout=25)), service.log()):
        return
    try:
        check_refusals(case, home)
        check_edit(case, home)
        tasks = {kind: add_task(case, home, kind.title(), kind)
                 for kind in ("screen", "program", "question", "never")}
        tasks["bare"] = add_task(case, home, "Bare", "screen", instructions=None)
        case.check("list shows a task's instructions, lines and all",
                   listed(home, tasks["screen"]).get("instructions") == INSTRUCTIONS,
                   json.dumps(listed(home, tasks["screen"]))[:300])
        runs = {kind: run_now(case, home, kind, task_id) for kind, task_id in tasks.items()}
        for kind, run_id in runs.items():
            entry = wait_status(service, home, tasks[kind], run_id, ("running", "done", "failed",
                                                                     "failed_to_start", "needs_you"),
                                timeout=30)
            if entry.get("session_id"):
                fixture_started(case, service, home.path("app-sessions", entry["session_id"]))
        check_done(case, service, home, "screen", tasks["screen"], runs["screen"],
                   "Morning briefing ready: 3 meetings, 2 reviews.")
        check_done(case, service, home, "program", tasks["program"], runs["program"],
                   "Briefing sent to the team")
        check_without_instructions(case, service, home, tasks["bare"], runs["bare"])
        check_needs_you(case, service, home, tasks["question"], runs["question"])
        check_never_ready(case, service, home, tasks["never"], runs["never"])
        check_native_owner(case, service, home, tasks["screen"])
    finally:
        for session_id in list(home.manifests()):
            try:
                control(home, session_id, QUIT)
            except OSError:
                pass
            cli(home, "rm", session_id)
        time.sleep(0.5)


run("schedules_agents", body)
