"""The omp extension asks the Host before it speaks for a Session (#75).

OMP has no shell hooks: Unpeel's lifecycle reporter is an extension module
that OMP loads into its own process, so it posts `/hook/<UNPEEL_SESSION_ID>`
without the shell reporters' identity guard. It runs the same check (the
installing `unpeel-host __session_identity__`, ADR 0013) before it writes
`last-hook-event.json` or posts.

A fake `omp` runs in a Session with the installed OMP integration and loads
the installed extension with Bun, the way OMP does, once per event:

* from inside the Session its events move the Session, and the checker,
  asked directly, says yes;
* from a detached runner (double fork into a new session, so its parent is
  no longer the Session's tree) that keeps the Session's whole environment,
  an opening event leaves an idle Session idle and a Stop leaves a busy one
  busy, the durable marker stays as it was, the trace records each refusal,
  and the checker says no.

The real OMP is never run. Without Bun the case is skipped with a NOTE.
"""

import json
import os
import pwd
import re
import shlex
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, TRUST_SESSION_ENV, run, run_cli  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402
from session_identity_ancestry import UUID, marker, output_has  # noqa: E402

HOST = os.path.join(os.path.dirname(BINARY), "unpeel-host")

# Loads the installed extension and fires one OMP event, as OMP would.
DRIVER = r'''
const [extension, event] = process.argv.slice(2);
const omp = { HookSeen: "session_start", UserPromptSubmit: "before_agent_start", Stop: "agent_end" }[event];
const handlers = {};
(await import(extension)).default({ on: (name, handler) => { handlers[name] = handler; } });
const ctx = { sessionManager: { getSessionId: () => "omp-conversation", getSessionFile: () => undefined } };
await handlers[omp]({ type: omp, messages: [] }, ctx);
'''

FAKE_OMP = r'''
import json, os, subprocess, sys, time, tty

BUN, DRIVER, EXTENSION, HOST = "@BUN@", "@DRIVER@", "@EXTENSION@", "@HOST@"
OUT = os.path.join(os.environ["HOME"], "fake-omp")
FAKE_PID = os.getpid()
os.makedirs(OUT, exist_ok=True)
tty.setraw(0)


def fire(event):
    subprocess.run([BUN, DRIVER, EXTENSION, event], capture_output=True, timeout=60)


def checker():
    started = time.monotonic()
    done = subprocess.run([HOST, "__session_identity__"], capture_output=True, text=True,
                          timeout=30)
    return {"rc": done.returncode, "out": done.stdout.strip(),
            "ms": round((time.monotonic() - started) * 1000, 1)}


def write(name, result):
    with open(os.path.join(OUT, name + ".json"), "w") as handle:
        json.dump(result, handle)
    os.write(1, ("FAKE_DONE " + name + "\r\n").encode())


def own(event):
    fire(event)
    write("own-" + event, {"checker": checker()})


def detached(event):
    # Double fork into a new session: the runner's parent is no longer this
    # process, as for a process that outlived the Session's tree.
    middle = os.fork()
    if middle == 0:
        os.setsid()
        if os.fork() == 0:
            for _ in range(100):
                if os.getppid() not in (FAKE_PID, middle):
                    break
                time.sleep(0.05)
            try:
                parent = os.getppid()
                fire(event)
                write("detached-" + event, {
                    "checker": checker(), "parent": parent, "fake": FAKE_PID, "middle": middle,
                    "session": os.environ.get("UNPEEL_SESSION_ID")})
            finally:
                os._exit(0)
        os._exit(0)
    os.waitpid(middle, 0)


os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\r\n")
fire("UserPromptSubmit")
actions = {
    b"r": lambda: own("UserPromptSubmit"),
    b"s": lambda: own("Stop"),
    b"d": lambda: detached("UserPromptSubmit"),
    b"e": lambda: detached("Stop"),
}
while True:
    data = os.read(0, 4096)
    if not data:
        break
    for key in data:
        action = actions.get(bytes([key]))
        if action:
            action()
'''


def bun():
    found = shutil.which("bun")
    if found:
        return found
    # The case runs with a private HOME, so look in the account's own.
    fallback = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".bun", "bin", "bun")
    return fallback if os.access(fallback, os.X_OK) else None


def body(case):
    runtime = bun()
    if not runtime:
        case.note("Bun unavailable — skipped the omp extension identity check")
        return
    home = case.home
    home.project("p", "OMP", home.root)
    os.makedirs(home.path("bin"), exist_ok=True)
    extension = os.path.join(os.environ["PI_CODING_AGENT_DIR"], "extensions",
                             "unpeel-lifecycle.ts")
    driver = home.path("bin", "omp-driver.mjs")
    with open(driver, "w") as handle:
        handle.write(DRIVER)
    fake = home.path("bin", "omp")
    with open(fake, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_OMP.replace("@BUN@", runtime)
                     .replace("@DRIVER@", driver).replace("@EXTENSION@", extension)
                     .replace("@HOST@", HOST))
    os.chmod(fake, 0o755)
    environment = {"SHELL": "/bin/bash", **TRUST_SESSION_ENV}
    # The login shell rebuilds PATH, so launch the fake by its absolute path.
    home.preset(label="omp", preset_id="omp", command=shlex.quote(fake))
    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=20)), service.log()):
        return
    installed = run_cli(home, ["integrations", "install", "omp"], env=environment)
    case.check("the OMP integration installs into the private agent dir",
               installed.returncode == 0 and os.path.exists(extension), installed.stderr)
    try:
        with open(extension) as handle:
            source = handle.read()
    except OSError:
        source = ""
    case.check("the installed extension names the installing unpeel-host as its checker",
               f"const IDENTITY_CHECKER = {json.dumps(HOST)};" in source,
               next((line for line in source.splitlines() if "IDENTITY_CHECKER =" in line), ""))
    launched = run_cli(home, ["new", "--preset", "omp", "--project", "p", "--cwd", home.root],
                       env=environment)
    ids = re.findall(UUID, launched.stdout)
    if not case.check("the fake omp launches", launched.returncode == 0 and bool(ids),
                      launched.stderr):
        return
    session_id = ids[0]
    session_dir = home.path("app-sessions", session_id)
    trace = home.path("hooks", "trace.log")

    def activity():
        return read_json(home.path("activity-state.json")).get("sessions", {}).get(session_id, {})

    def expect(label, status, completed):
        return case.check(label, bool(service.wait_for(
            lambda: activity().get("raw_status") == status
            and activity().get("completed") is completed, timeout=20)), str(activity()))

    def stays(label, status, completed):
        service.read_for(3)
        current = activity()
        case.check(label, current.get("raw_status") == status
                   and current.get("completed") is completed, str(current))

    def act(key, name):
        before = output_has(session_dir, f"FAKE_DONE {name}".encode())
        control(home, session_id, key)
        done = service.wait_for(
            lambda: output_has(session_dir, f"FAKE_DONE {name}".encode()) > before, timeout=90)
        return read_json(home.path("fake-omp", name + ".json")) if done else {}

    def refusals():
        try:
            with open(trace) as handle:
                return sum(f"hook-refused session={session_id} reason=not-an-ancestor" in line
                           for line in handle)
        except OSError:
            return 0

    try:
        if not fixture_started(case, service, session_dir):
            return
        expect("the extension's opening event makes the Session busy", "busy", False)
        own = act("s", "own-Stop")
        expect("its Stop completes the turn", "idle", True)
        checked = own.get("checker", {})
        case.check("inside the Session the checker says yes",
                   checked.get("rc") == 0 and checked.get("out") == session_id, str(checked))
        case.note(f"identity check from inside the Session: {checked.get('ms')} ms")

        seed = marker(session_dir)
        case.check("the Session has a durable hook marker", seed is not None)
        opening = act("d", "detached-UserPromptSubmit")
        case.check("the detached runner's parent is outside the Session",
                   opening.get("parent") not in (None, opening.get("fake"), opening.get("middle")),
                   str({key: opening.get(key) for key in ("parent", "fake", "middle")}))
        case.check("the detached runner keeps the Session's exported id",
                   opening.get("session") == session_id, str(opening.get("session")))
        checked = opening.get("checker", {})
        case.check("outside the Session the checker refuses",
                   checked.get("rc") == 3 and checked.get("out") == "not-an-ancestor",
                   str(checked))
        stays("a detached runner's opening event leaves the Session idle", "idle", True)
        case.check("and leaves its durable marker untouched", marker(session_dir) == seed)

        act("r", "own-UserPromptSubmit")
        expect("the Session's own opening event still applies", "busy", False)
        seed = marker(session_dir)
        act("e", "detached-Stop")
        stays("a detached runner's Stop leaves the Session busy", "busy", False)
        case.check("and leaves its durable marker untouched", marker(session_dir) == seed)
        case.check("the trace records both refusals", refusals() == 2, str(refusals()))
        act("s", "own-Stop")
        expect("the Session's own Stop completes the turn", "idle", True)
    finally:
        run_cli(home, ["rm", session_id], env=environment, timeout=45)


if __name__ == "__main__":
    run("omp_hook_identity", body)
