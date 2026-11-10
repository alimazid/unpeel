"""The Host's health check (fork-only, #84), end to end through `unpeel serve`.

With `UNPEEL_HEALTH_SECONDS=1` the check runs every 5 s and its minute
limits are seconds (a missed fire after 10 s). A Router (a 7501 fixture,
marked directly in this private home's app-state) is the Super Agent, and a
stand-in platform adapter records every Mac notification. Covered:

* a skipped Run (an occurrence behind a Run in progress) reaches the Super
  Agent's Inbox as a Host report (`blocked`) and the Mac as an alert naming
  the Run in its way, once;
* a missed fire (a task whose Run log will not read, so the scheduler starts
  nothing and its next run passes) alerts no sooner than 10 s after it was
  due, once;
* with the app quit, a failed Run's own notice is kept, its health report
  still queues for the Super Agent, and a stopped Super Agent alerts the Mac
  only (nothing in its Inbox about itself); when an app connects, both kept
  notices are shown, once;
* a kept alert whose problem cleared before an app connects is dropped, not
  shown (the check runs before the kept notices go out);
* a Host restart alerts nothing again: the problems still stand, and the
  state is on disk.
"""

import datetime
import json
import os
import shlex
import subprocess
import sys
import time
import zoneinfo

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running, TRUST_SESSION_ENV  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402
from super_agent_alerts import FakeAdapter, write_fixture  # noqa: E402

ZONE = "America/New_York"
INTERVAL_S = 5
MISSED_FIRE_S = 10


def local_now():
    return datetime.datetime.now(zoneinfo.ZoneInfo(ZONE)).replace(microsecond=0)


def body(case):
    home = case.home
    folder = home.path("p")
    os.makedirs(folder)
    home.project("p", "Health", folder)
    environment = {"HOME": home.root, "SHELL": "/bin/bash", "TZ": ZONE,
                   "UNPEEL_HEALTH_SECONDS": "1"}
    os.makedirs(home.path("bin"), exist_ok=True)
    write_fixture(home.path("bin", "router-agent"), "Router turn done", 0.5)
    home.preset(label="router", command=shlex.quote(home.path("bin", "router-agent")),
                preset_id="router")
    home.preset(label="long", command="sleep 600", preset_id="long")
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="three", command="/bin/sh -c 'exit 3'", preset_id="three")

    def cli(*args):
        return run_cli(home, list(args), env=environment, timeout=45)

    def add(name, preset, at):
        added = cli("schedules", "add", name, "--project", "p", "--preset", preset,
                    "--once", at.strftime("%Y-%m-%dT%H:%M:%S"))
        task_id = added.stdout.strip()
        case.check(f"{name}: add prints the task id",
                   added.returncode == 0 and task_id.startswith("sch_"), added.stderr)
        return task_id

    def history(task_id):
        try:
            return json.loads(cli("schedules", "history", task_id, "--json").stdout)
        except ValueError:
            return []

    def inbox(router):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1",
                   UNPEEL_SESSION_ID=router, **TRUST_SESSION_ENV)
        done = subprocess.run([BINARY, "mcp", "sessions", "inbox"], capture_output=True,
                              text=True, timeout=60, env=env, cwd=CRATES)
        try:
            listing = json.loads(done.stdout)
        except ValueError:
            return []
        return listing.get("pending", []) + listing.get("delivered", [])

    def reports(router, about):
        return [item for item in inbox(router)
                if item.get("sender") == "host" and item.get("kind") == "report"
                and item.get("about") == about]

    def alerts(adapter, **match):
        return [n for n in adapter.calls_matching(**match) if n.get("kind") == "alert"]

    def health_state():
        return read_json(home.path("health", "state.json"))

    service = case.serve(env=environment)
    status = service.ready(timeout=25)
    if not case.check("isolated Host starts", bool(status), service.log()):
        return
    adapter = case.track(Adapter())
    code, registered = adapter.register(status.get("localSocket", ""))
    if not case.check("the fake adapter registers notification.deliver",
                      code == 200 and registered.get("ok") is True, f"{code} {registered}"):
        return

    started = cli("new", "--preset", "router", "--project", "p", "--cwd", folder)
    ids = [w for w in started.stdout.split() if len(w) == 36 and w.count("-") == 4]
    router = ids[0] if ids else ""
    if not case.check("the Router starts", bool(router) and wait_running(home, router),
                      started.stdout + started.stderr):
        return
    state = home.state()
    state["super_agent"] = {"session_id": router, "since": int(time.time() * 1000)}
    home.write_state(state)
    try:
        if not fixture_started(case, service, home.path("app-sessions", router)):
            return

        # 1. A skipped Run: Run now holds the task, its occurrence is skipped.
        nightly = add("Nightly", "long", local_now() + datetime.timedelta(seconds=10))
        run_id = cli("schedules", "run", nightly).stdout.strip()
        blocker = service.wait_for(lambda: next(
            (entry for entry in history(nightly)
             if entry.get("run_id") == run_id and entry.get("session_id")), None), timeout=20) or {}
        case.check("Run now starts a long Run", blocker.get("status") == "running",
                   json.dumps(history(nightly)))
        skipped = service.wait_for(lambda: [entry for entry in history(nightly)
                                            if entry.get("status") == "skipped"], timeout=30)
        case.check("its occurrence is skipped behind it", bool(skipped), json.dumps(history(nightly)))
        sent = service.wait_for(lambda: alerts(adapter, scheduleID=nightly), timeout=20) or []
        case.check("the skipped Run alerts the Mac, naming the Run in its way",
                   [(n.get("sessionID"), n.get("title")) for n in sent]
                   == [(blocker.get("session_id"), "Nightly")]
                   and "skipped its" in sent[0].get("body", "")
                   and run_id in sent[0].get("body", ""), json.dumps(sent))
        queued = service.wait_for(lambda: reports(router, nightly), timeout=10) or []
        case.check("and reaches the Super Agent's Inbox as a blocked Host report",
                   [(item.get("status"), item.get("priority")) for item in queued]
                   == [("blocked", "wake")] and "skipped its" in queued[0].get("summary", ""),
                   json.dumps(queued))

        # 2. A missed fire: the Run log will not read, so nothing starts.
        due = local_now() + datetime.timedelta(seconds=4)
        stuck = add("Stuck", "ok", due)
        os.makedirs(home.path("schedules", stuck, "runs.jsonl"), exist_ok=True)
        sent = service.wait_for(lambda: alerts(adapter, scheduleID=stuck),
                                timeout=MISSED_FIRE_S + 4 + 3 * INTERVAL_S) or []
        alerted_at = datetime.datetime.now(zoneinfo.ZoneInfo(ZONE))
        case.check("a missed fire alerts the Mac with no Session",
                   [(n.get("sessionID"), n.get("title")) for n in sent] == [("", "Stuck")]
                   and "no Run of it started" in sent[0].get("body", ""), json.dumps(sent))
        case.check("no sooner than its limit after it was due",
                   alerted_at >= due + datetime.timedelta(seconds=MISSED_FIRE_S),
                   f"{alerted_at.isoformat()} vs due {due.isoformat()}")
        case.check("the missed fire reaches the Super Agent's Inbox",
                   len(service.wait_for(lambda: reports(router, stuck), timeout=10) or []) == 1,
                   json.dumps(inbox(router))[:600])

        # Lasting problems alert once.
        service.read_for(2 * INTERVAL_S + 2)
        case.check("lasting problems alert once",
                   len(alerts(adapter, scheduleID=nightly)) == 1
                   and len(alerts(adapter, scheduleID=stuck)) == 1
                   and len(reports(router, nightly)) == 1 and len(reports(router, stuck)) == 1,
                   json.dumps(adapter.calls_matching())[:800])

        # 3. The app quits: a failed Run's notice and a stopped Super Agent's
        #    alert wait for it.
        adapter.close()
        service.read_for(1)
        three = add("Three", "three", local_now() + datetime.timedelta(days=1))
        failed_run = cli("schedules", "run", three).stdout.strip()
        failed = service.wait_for(lambda: next(
            (entry for entry in history(three)
             if entry.get("run_id") == failed_run and entry.get("status") == "failed"), None),
            timeout=30) or {}
        case.check("a Run fails while no app is connected", failed.get("exit_code") == 3,
                   json.dumps(history(three)))
        stopped = cli("stop", router)
        case.check("the Super Agent is stopped", stopped.returncode == 0, stopped.stderr)
        down = f"router_down:{router}"
        kept = service.wait_for(lambda: (
            health_state().get("problems", {}).get(down, {}).get("alerted")
            and len(health_state().get("kept", [])) == 2 and health_state().get("kept")),
            timeout=3 * INTERVAL_S) or []
        case.check("both notices are kept for an app: the failure, then the Super Agent's",
                   [(notice.get("problem"), notice.get("title")) for notice in kept]
                   == [(None, "Three"), (down, "Super Agent")], json.dumps(health_state()))
        case.check("the failure's health report still queues for the stopped Super Agent",
                   len(service.wait_for(lambda: reports(router, three), timeout=10) or []) == 1,
                   json.dumps(inbox(router))[:600])
        case.check("its own being down is nowhere in its Inbox", not reports(router, router),
                   json.dumps(inbox(router))[:600])

        # 4. An app connects: the kept notices are shown, once.
        connected = case.track(Adapter())
        code, _ = connected.register(service.status().get("localSocket", ""))
        case.check("an app connects again", code == 200)
        shown = service.wait_for(lambda: len(alerts(connected)) >= 2 and alerts(connected),
                                 timeout=10) or []
        case.check("the kept notices are shown in order",
                   [(n.get("sessionID"), n.get("scheduleID"), n.get("title")) for n in shown]
                   == [(failed.get("session_id"), three, "Three"), (router, None, "Super Agent")]
                   and shown[0].get("body") == "Failed: the command exited with status 3"
                   and "is not running" in shown[1].get("body", ""), json.dumps(shown))
        case.check("nothing is kept any more", not health_state().get("kept"),
                   json.dumps(health_state()))
        service.read_for(2 * INTERVAL_S + 2)
        case.check("and nothing repeats while the problems last", len(alerts(connected)) == 2,
                   json.dumps(alerts(connected)))

        # 5. A kept alert whose problem cleared is dropped, even when an app
        #    connects before the next check would have seen it clear.
        connected.close()

        def mark(session_id):
            state = home.state()
            state.pop("super_agent", None)
            if session_id:
                state["super_agent"] = {"session_id": session_id,
                                        "since": int(time.time() * 1000)}
            home.write_state(state)

        mark(None)
        case.check("unmarking the stopped Super Agent clears its problem",
                   bool(service.wait_for(lambda: down not in health_state().get("problems", {}),
                                         timeout=3 * INTERVAL_S)), json.dumps(health_state()))
        mark(router)
        kept = service.wait_for(lambda: [n for n in health_state().get("kept", [])
                                         if n.get("problem") == down], timeout=3 * INTERVAL_S)
        case.check("marked again while down, it alerts again, kept for an app", bool(kept),
                   json.dumps(health_state()))
        mark(None)
        cleared = case.track(Adapter())
        code, _ = cleared.register(service.status().get("localSocket", ""))
        case.check("an app connects right after the problem cleared", code == 200)
        service.read_for(2 * INTERVAL_S + 2)
        case.check("the cleared problem's alert is dropped, not shown", not alerts(cleared),
                   json.dumps(alerts(cleared)))
        case.check("and nothing is kept", not health_state().get("kept"),
                   json.dumps(health_state()))

        # 6. A Host restart alerts nothing again.
        cleared.close()
        service.close()
        service = case.serve(env=environment)
        status = service.ready(timeout=25)
        if not case.check("the Host starts again", bool(status), service.log()):
            return
        restarted = case.track(Adapter())
        code, _ = restarted.register(status.get("localSocket", ""))
        case.check("the app connects to it", code == 200)
        service.read_for(2 * INTERVAL_S + 2)
        case.check("the restarted Host alerts nothing again", not alerts(restarted),
                   json.dumps(alerts(restarted)))
        case.check("and queues no second report",
                   [len(reports(router, task)) for task in (nightly, stuck, three)] == [1, 1, 1],
                   json.dumps(inbox(router))[:800])
    finally:
        for session_id in list(home.manifests()):
            try:
                control(home, session_id, "q")
            except OSError:
                pass
            run_cli(home, ["rm", session_id], env=environment, timeout=45)


class Adapter(FakeAdapter):
    """`super_agent_alerts`' stand-in Mac app, matching notifications by any
    request field."""

    def calls_matching(self, **match):
        return [call["request"] for call in list(self.calls)
                if call.get("operation") == "notification.deliver"
                and all(call["request"].get(key) == value for key, value in match.items())]


if __name__ == "__main__":
    run("health_check", body)
