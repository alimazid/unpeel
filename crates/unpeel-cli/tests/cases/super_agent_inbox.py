"""Super Agent Inbox delivery (fork-only).

While the Host worker runs, `sessions report` queues into the target's
Inbox instead of typing. A program that speaks OSC 7501 and enables
bracketed paste gets everything queued as ONE paste once it is idle and
quiet; a half-typed prompt holds the paste until the user clears it (#38);
a `progress` report alone never pastes; and a plain `cat` session is held
(no agent authority) and drains by pulling with `sessions inbox`. Without a
Host worker, `report` pastes at once and says so.
"""

import time

import json
import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running, TRUST_SESSION_ENV  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402

HEADER = "[unpeel inbox for id:"


def write_fixture(home, path, log):
    """A 7501 program with bracketed paste: idle at its prompt, it logs
    stdin, echoes typed text (backspace erases), goes working for a moment
    when a paste is submitted, and obeys `w` (working) / `i` (idle) / `q`
    (quit) control writes."""
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + f'''
import os, select, time, tty
tty.setraw(0)
def report(state):
    os.write(1, b"\\x1b]7501;state=" + state.encode() + b":app=inbox\\x1b\\\\")
os.write(1, b"\\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\\r\\n> ")
report("idle")
pasted = False
busy_until = None
while True:
    wait = None if busy_until is None else max(0.0, busy_until - time.time())
    ready, _, _ = select.select([0], [], [], wait)
    if not ready:
        report("idle")
        busy_until = None
        continue
    data = os.read(0, 65536)
    if not data or data == b"q":
        break
    with open({log!r}, "ab") as out:
        out.write(data)
    if data == b"w":
        report("working")
    elif data == b"i":
        report("idle")
    else:
        if b"\\x1b" not in data and b"\\r" not in data:
            os.write(1, data.replace(b"\\x7f", b"\\b \\b"))
        pasted = pasted or b"\\x1b[200~" in data
        if pasted and b"\\r" in data:
            pasted = False
            report("working")
            busy_until = time.time() + 1.5
''')
    os.chmod(path, 0o755)


def body(case):
    home = case.home
    home.project("p", "inbox", home.root)
    state = home.state()
    # No Controller answers approval prompts here.
    state["mcp_nonchild_write_access"] = "allow"
    home.write_state(state)
    environment = {"HOME": home.root, "SHELL": "/bin/bash"}
    os.makedirs(home.path("bin"), exist_ok=True)
    log = home.path("stdin.log")
    program = home.path("bin", "inbox-agent")
    write_fixture(home, program, log)
    home.preset(label="agent", command=shlex.quote(program), preset_id="agent")
    home.preset(label="cat", command="cat", preset_id="cat")

    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=25)), service.log()):
        return

    def launch(preset):
        started = run_cli(home, ["new", "--preset", preset, "--project", "p"], env=environment)
        ids = [w for w in started.stdout.split() if len(w) == 36 and w.count("-") == 4]
        return ids[0] if ids else ""

    agent, caller, cat = launch("agent"), launch("cat"), launch("cat")
    ids = [agent, caller, cat]
    if not case.check("three sessions start", all(ids) and all(wait_running(home, i) for i in ids),
                      str(ids)):
        return
    if not fixture_started(case, service, home.path("app-sessions", agent)):
        return

    def mcp(session_id, action, *words):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id, **TRUST_SESSION_ENV)
        done = subprocess.run([BINARY, "mcp", "sessions", action, *words],
                              capture_output=True, text=True, timeout=60, env=env, cwd=CRATES)
        try:
            return json.loads(done.stdout), done
        except ValueError:
            return {}, done

    def inbox(session_id):
        return mcp(session_id, "inbox")[0]

    def activity():
        return read_json(home.path("activity-state.json")).get("sessions", {}).get(agent, {})

    def published(raw_status):
        return lambda: activity().get("raw_status") == raw_status \
            and activity().get("activity_source") == "program"

    def manifest():
        return read_json(home.path("app-sessions", agent, "manifest.json"))

    def signal(data):
        # The harness's own control writes: not a person typing.
        return control(home, agent, data, origin="program")

    def pasted():
        try:
            with open(log, "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    try:
        case.check("the agent is idle from its own report",
                   bool(service.wait_for(published("idle"), timeout=15)), str(activity()))
        case.check("the agent's terminal has bracketed paste on",
                   bool(service.wait_for(
                       lambda: 2004 in ((manifest().get("terminal_modes") or {}).get("set") or []),
                       timeout=10)), str(manifest().get("terminal_modes")))

        # 1. Two reports while the agent is busy: queued, nothing typed.
        signal("w")
        case.check("the agent turns busy", bool(service.wait_for(published("busy"), timeout=10)),
                   str(activity()))
        first, done = mcp(caller, "report", f"session_id={agent}", "summary=first summary",
                          "status=done")
        case.check("a report to a busy agent is queued", first.get("queued") is True
                   and first.get("delivery") == "when_idle" and first.get("pending") == 1,
                   (done.stdout + done.stderr)[:300])
        second, done = mcp(caller, "report", f"session_id={agent}", "summary=second summary",
                           "status=done")
        case.check("a second report queues behind it", second.get("pending") == 2,
                   (done.stdout + done.stderr)[:300])
        service.read_for(3)
        case.check("nothing is pasted while the agent is busy", HEADER not in pasted(), pasted()[-300:])
        held = inbox(agent)
        case.check("the agent's Inbox lists both, held while busy",
                   [item.get("summary") for item in held.get("pending", [])]
                   == ["first summary", "second summary"] and held.get("hold") == "busy", str(held)[:400])

        # 2. Idle: exactly one paste with both, in order; then confirmed.
        signal("i")
        case.check("the batch is pasted once the agent is idle",
                   bool(service.wait_for(lambda: HEADER in pasted(), timeout=20)), pasted()[-300:])
        text = pasted()
        case.check("exactly one paste carries both reports in order",
                   text.count(HEADER) == 1 and f"{HEADER}{agent}" in text
                   and 0 <= text.find("first summary") < text.find("second summary"), text[-600:])
        case.check("the paste is bracketed", "\x1b[200~" in text and "\x1b[201~" in text, repr(text[-200:]))
        case.check("the agent's turn confirms the delivery",
                   bool(service.wait_for(lambda: inbox(agent).get("pending") == [], timeout=15)),
                   str(inbox(agent))[:400])
        case.check("both items are kept as delivered", len(inbox(agent).get("delivered", [])) == 2)

        # 3. A half-typed prompt holds the paste until it is cleared (#38).
        service.wait_for(published("idle"), timeout=10)
        control(home, agent, "abc")
        case.check("a person's typing is stamped",
                   bool(service.wait_for(lambda: manifest().get("last_input_at"), timeout=5)),
                   str(manifest())[:300])
        typed_at = manifest().get("last_input_at") or 0
        refused = control(home, agent, "", origin="program", unless_typed_since=typed_at)
        case.check("a guarded write after the typing is refused",
                   refused.get("ok") is False and "typed" in (refused.get("error") or ""),
                   str(refused))
        accepted = control(home, agent, "", origin="program",
                           unless_typed_since=int(time.time() * 1000) + 60_000)
        case.check("a guarded write before any typing goes through", accepted.get("ok") is True,
                   str(accepted))
        case.check("program writes are not typing",
                   manifest().get("last_input_at") == typed_at, str(manifest().get("last_input_at")))
        before = pasted().count(HEADER)
        typing, done = mcp(caller, "report", f"session_id={agent}", "summary=while typing",
                           "status=done")
        case.check("a report while the user types is queued", typing.get("queued") is True,
                   (done.stdout + done.stderr)[:300])
        service.read_for(5)
        case.check("nothing is pasted onto a half-typed prompt",
                   pasted().count(HEADER) == before, pasted()[-300:])
        case.check("the Inbox holds it as a draft", inbox(agent).get("hold") == "draft",
                   str(inbox(agent))[:300])
        control(home, agent, "\x7f\x7f\x7f")
        case.check("once the line is cleared the batch is pasted",
                   bool(service.wait_for(lambda: pasted().count(HEADER) > before, timeout=15)),
                   pasted()[-300:])
        service.read_for(5)
        case.check("exactly once", pasted().count(HEADER) == before + 1, pasted()[-600:])
        case.check("its turn confirms it",
                   bool(service.wait_for(lambda: inbox(agent).get("pending") == [], timeout=15)),
                   str(inbox(agent))[:400])

        # 4. A progress report alone never pastes.
        service.wait_for(published("idle"), timeout=10)
        progress, done = mcp(caller, "report", f"session_id={agent}", "summary=progress only",
                             "status=progress")
        case.check("a progress report rides along", progress.get("queued") is True
                   and progress.get("delivery") == "held:ride_along", (done.stdout + done.stderr)[:300])
        service.read_for(8)
        case.check("a progress report alone never pastes", pasted().count(HEADER) == 2,
                   pasted()[-300:])
        case.check("it waits as a ride-along item",
                   bool(service.wait_for(lambda: inbox(agent).get("hold") == "ride_along", timeout=5)),
                   str(inbox(agent))[:300])

        # 5. A plain `cat` is held and pulls its own Inbox.
        queued, done = mcp(caller, "report", f"session_id={cat}", "summary=for the cat",
                           "status=done", "details=the full text")
        case.check("a report to cat is queued", queued.get("queued") is True,
                   (done.stdout + done.stderr)[:300])
        case.check("cat's Inbox is held for lack of an agent",
                   bool(service.wait_for(lambda: inbox(cat).get("hold") == "no_agent_authority",
                                         timeout=10)), str(inbox(cat))[:300])
        item_id = queued.get("item_id", "")
        item = mcp(cat, "inbox", f"item_id={item_id}")[0].get("item", {})
        case.check("cat reads the full item", item.get("summary") == "for the cat"
                   and "the full text" in item.get("body", ""), str(item)[:300])
        acked = mcp(cat, "inbox", f"ack_through={item_id}")[0]
        case.check("cat acks it in pull mode", acked.get("acked") == 1 and acked.get("pending") == 0,
                   str(acked))
        refused = mcp(cat, "inbox", f"session_id={agent}")[1]
        case.check("an Inbox is readable only by its own session",
                   refused.returncode != 0 and "own Inbox" in refused.stderr, refused.stderr[:200])
        screen = run_cli(home, ["screen", cat]).stdout
        case.check("nothing was typed into cat", HEADER not in screen and "for the cat" not in screen,
                   screen[-300:])

        # 6. Without a Host worker, report pastes at once and says so.
        service.close()
        legacy, done = mcp(caller, "report", f"session_id={cat}", "summary=typed at once")
        case.check("without a Host the report is pasted immediately",
                   legacy.get("queued") is False and legacy.get("delivery") == "immediate_legacy",
                   (done.stdout + done.stderr)[:300])
    finally:
        try:
            signal("q")
        except OSError:
            pass
        for session_id in ids:
            if session_id:
                run_cli(home, ["rm", session_id], env=environment, timeout=45)


if __name__ == "__main__":
    run("super_agent_inbox", body)
