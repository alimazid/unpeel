"""Ride-along Inbox items are promoted by age (fork-only, #83).

A `progress` report alone rides along, but once it has waited the promotion
age (15 minutes, shortened here through the test-only
`UNPEEL_INBOX_RIDE_ALONG_PROMOTE_MS`) it starts a delivery as if it were a
wake item: never before that age, then as one paste. A promoted item waits
on a busy agent like a wake item, and the age counts from its stored queue
time, so a Host restart does not hold it as ride-along again. A report
queued beside a promoted item is told it goes out `when_idle` (#85).
"""

import json
import os
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running, TRUST_SESSION_ENV  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402
from super_agent_inbox import HEADER, write_fixture  # noqa: E402

PROMOTE_MS = 6_000


def body(case):
    home = case.home
    home.project("p", "inbox", home.root)
    state = home.state()
    # No Controller answers approval prompts here.
    state["mcp_nonchild_write_access"] = "allow"
    home.write_state(state)
    environment = {"HOME": home.root, "SHELL": "/bin/bash",
                   "UNPEEL_INBOX_RIDE_ALONG_PROMOTE_MS": str(PROMOTE_MS)}
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

    agent, caller = launch("agent"), launch("cat")
    ids = [agent, caller]
    if not case.check("two sessions start", all(ids) and all(wait_running(home, i) for i in ids),
                      str(ids)):
        return
    if not fixture_started(case, service, home.path("app-sessions", agent)):
        return

    def mcp(session_id, action, *words):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id,
                   **TRUST_SESSION_ENV)
        done = subprocess.run([BINARY, "mcp", "sessions", action, *words],
                              capture_output=True, text=True, timeout=60, env=env, cwd=CRATES)
        try:
            return json.loads(done.stdout), done
        except ValueError:
            return {}, done

    def inbox():
        return mcp(agent, "inbox")[0]

    def hold():
        return read_json(home.path("session-inboxes", agent, "hold.json"))

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

    def progress(summary):
        return mcp(caller, "report", f"session_id={agent}", f"summary={summary}",
                   "status=progress")

    def queued_at(item_id):
        # The item's stored queue time: the clock the drain promotes by.
        return next((item.get("at") for item in inbox().get("pending", [])
                     if item.get("id") == item_id), None)

    try:
        case.check("the agent is idle from its own report",
                   bool(service.wait_for(published("idle"), timeout=15)), str(activity()))
        case.check("the agent's terminal has bracketed paste on",
                   bool(service.wait_for(
                       lambda: 2004 in ((manifest().get("terminal_modes") or {}).get("set") or []),
                       timeout=10)), str(manifest().get("terminal_modes")))

        # 1. Idle: a lone progress report rides along, then goes out once
        #    it has waited the promotion age. The screen is quiet first, so
        #    the hold shows `ride_along`, not `quiet`, while it is young.
        service.wait_for(
            lambda: time.time() * 1000 - (manifest().get("screen_changed_at") or 0) >= 3_500,
            timeout=10)
        queued, done = progress("halfway there")
        case.check("a progress report rides along", queued.get("queued") is True
                   and queued.get("delivery") == "held:ride_along", (done.stdout + done.stderr)[:300])
        stored_at = queued_at(queued.get("item_id")) or 0
        case.check("it is held as a ride-along item while it is young",
                   bool(service.wait_for(lambda: hold().get("reason") == "ride_along", timeout=5))
                   and HEADER not in pasted(), str(hold()))
        # The paste landed after the last look that did not find it.
        last_absent = [0.0]

        def paste_landed():
            if HEADER in pasted():
                return True
            last_absent[0] = time.time() * 1000
            return False
        case.check("the promoted item is pasted once it is old enough",
                   bool(service.wait_for(paste_landed, timeout=PROMOTE_MS / 1000 + 20)),
                   pasted()[-300:])
        age_unpasted = last_absent[0] - stored_at
        case.check("never before the promotion age",
                   stored_at > 0 and age_unpasted >= PROMOTE_MS - 500, f"{age_unpasted:.0f} ms")
        text = pasted()
        case.check("one paste carries it", text.count(HEADER) == 1 and "halfway there" in text,
                   text[-600:])
        case.check("the agent's turn confirms the delivery",
                   bool(service.wait_for(lambda: inbox().get("pending") == [], timeout=15)),
                   str(inbox())[:400])

        # 2. Busy: once promoted, the item waits on the agent like a wake
        #    item does, and a Host restart does not take that back.
        service.wait_for(published("idle"), timeout=10)
        signal("w")
        case.check("the agent turns busy", bool(service.wait_for(published("busy"), timeout=10)),
                   str(activity()))
        queued = progress("still going")[0]
        stored_at = queued_at(queued.get("item_id")) or 0
        case.check("a young item on a busy agent is held as ride-along",
                   bool(service.wait_for(lambda: hold().get("reason") == "ride_along", timeout=5)),
                   str(hold()))
        queued, done = progress("young too")
        case.check("a report beside a young item is told it rides along",
                   queued.get("delivery") == "held:ride_along", (done.stdout + done.stderr)[:300])
        case.check("once promoted it is held for the busy agent",
                   bool(service.wait_for(lambda: hold().get("reason") == "busy",
                                         timeout=PROMOTE_MS / 1000 + 10)), str(hold()))
        # #85: a report queued into the promoted batch goes out with it.
        queued, done = progress("after promotion")
        case.check("a report beside a promoted item is told it goes out when idle",
                   queued.get("delivery") == "when_idle", (done.stdout + done.stderr)[:300])
        # A hold's `since` is when the drain first held for that reason.
        promoted_after = (hold().get("since") or 0) - stored_at
        case.check("promoted no earlier than its age",
                   stored_at > 0 and promoted_after >= PROMOTE_MS, f"{promoted_after} ms")
        case.check("nothing is pasted while the agent is busy", pasted().count(HEADER) == 1,
                   pasted()[-300:])

        before_restart = hold().get("since")
        service.close()
        service = case.serve(env=environment)
        if not case.check("the Host starts again", bool(service.ready(timeout=25)), service.log()):
            return
        # Every hold the new Host publishes: a clock that started over would
        # hold the item as ride-along for another promotion age first.
        seen = []

        def held_busy_again():
            current = hold()
            if current.get("since") == before_restart:
                return False
            if current.get("reason") not in seen:
                seen.append(current.get("reason"))
            return current.get("reason") == "busy"
        case.check("the restarted Host holds it for the busy agent, never as ride-along",
                   bool(service.wait_for(held_busy_again, timeout=15)) and "ride_along" not in seen,
                   f"{seen} {hold()}")
        signal("i")
        case.check("idle again, the promoted item is pasted",
                   bool(service.wait_for(lambda: pasted().count(HEADER) == 2, timeout=20)),
                   pasted()[-300:])
        last = pasted().split(HEADER)[-1]
        case.check("it carries the promoted batch",
                   all(summary in last for summary in ["still going", "young too",
                                                       "after promotion"]), pasted()[-900:])
        case.check("and its turn confirms it",
                   bool(service.wait_for(lambda: inbox().get("pending") == [], timeout=15)),
                   str(inbox())[:400])
    finally:
        try:
            signal("q")
        except OSError:
            pass
        for session_id in ids:
            if session_id:
                run_cli(home, ["rm", session_id], env=environment, timeout=45)


if __name__ == "__main__":
    run("super_agent_inbox_promotion", body)
