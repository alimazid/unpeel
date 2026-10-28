"""Successful hooks produce unread results beneath an idle program report."""

import json
import os
import re
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402


def body(case):
    home = case.home
    home.project("p", "hooks", home.root)
    environment = {"HOME": home.root, "SHELL": "/bin/bash"}
    os.makedirs(home.path("bin"), exist_ok=True)
    fake = home.path("bin", "codex")
    with open(fake, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + '''
import json, os, subprocess, tty
tty.setraw(0)
def hook(event):
    with open(os.path.join(os.environ["HOME"], ".codex/hooks.json")) as handle:
        registrations = json.load(handle)["hooks"][event]
    for entry in registrations:
        for command in entry["hooks"]:
            subprocess.run(command["command"], shell=True, executable="/bin/bash",
                           input=json.dumps({"hook_event_name": event}), text=True, check=True)
print("HOOK_FIXTURE_PROCESS_STARTED", flush=True)
os.write(1, b"\\x1b]7501;state=idle:app=codex\\x07")
hook("UserPromptSubmit")
while True:
    data = os.read(0, 4096)
    if not data: break
    if data == b"s": hook("Stop")
    elif data == b"\\x1b": hook("Interrupt")
    elif data == b"w": os.write(1, b"\\x1b]7501;state=working:app=codex\\x07")
    elif data == b"i": os.write(1, b"\\x1b]7501;state=idle:app=codex\\x07")
    elif data == b"b": os.write(1, b"\\x1b]7501;state=blocked:app=codex\\x07")
    elif b"\\r" in data: hook("UserPromptSubmit")
''')
    os.chmod(fake, 0o755)
    environment["PATH"] = home.path("bin") + os.pathsep + os.environ["PATH"]
    home.preset(label="codex-program", command=shlex.quote(fake), preset_id="codex-program")
    service = case.serve(env=environment)
    ready = service.ready(timeout=25)
    if not case.check("isolated Host starts", bool(ready), service.log()):
        return
    # The fake reads ~/.codex/hooks.json, which only the explicitly installed
    # Codex integration writes; a launch never touches provider config.
    installed = run_cli(home, ["integrations", "install", "codex"], env=environment)
    case.check("the Codex integration installs into the private HOME", installed.returncode == 0, installed.stderr)
    launched = run_cli(home, ["new", "--preset", "codex-program", "--project", "p"], env=environment)
    ids = re.findall(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", launched.stdout)
    if not case.check("Codex fixture launches in a real PTY", launched.returncode == 0 and bool(ids), launched.stderr):
        return
    session_id = ids[0]
    session_dir = home.path("app-sessions", session_id)

    def activity():
        return read_json(home.path("activity-state.json")).get("sessions", {}).get(session_id, {})

    def finished_count():
        try:
            with open(home.path("activity-log.jsonl")) as handle:
                return sum(json.loads(line).get("kind") == "finished"
                           and json.loads(line).get("session_id") == session_id for line in handle)
        except FileNotFoundError:
            return 0

    def expect(label, status="idle", completed=False):
        return case.check(label, bool(service.wait_for(lambda:
            activity().get("raw_status") == status
            and activity().get("activity_source") == "program"
            and activity().get("completed") is completed)), str(activity()))

    def expect_finished(count):
        case.check(f"exactly {count} finished events", bool(service.wait_for(
            lambda: finished_count() == count)), str(finished_count()))

    try:
        if not fixture_started(case, service, session_dir):
            return
        expect("program idle retains status authority over an opening hook")
        control(home, session_id, "s")
        expect("Stop confirms completion beneath program idle", completed=True)
        case.check("unobserved completion becomes the blue unread dot",
                   bool(service.wait_for(lambda: activity().get("unread") is True)), str(activity()))
        expect_finished(1)
        control(home, session_id, "s")
        service.read_for(1.2)
        expect_finished(1)

        service.close()
        service = case.serve(env=environment)
        case.check("Host restarts with the same PTY", bool(service.ready(timeout=25)))
        expect("completion survives Host restart", completed=True)
        service.read_for(1.2)
        expect_finished(1)

        control(home, session_id, "next prompt\r")
        expect("next turn clears completion without changing program idle")
        control(home, session_id, "s")
        expect("another idle-to-idle completion is recognized", completed=True)
        expect_finished(2)

        control(home, session_id, "next prompt\r")
        expect("next opening clears completion")
        control(home, session_id, "\x1b")
        expect("Interrupt is not completion")
        control(home, session_id, "s")
        service.read_for(1.2)
        expect("late Stop after cancellation is suppressed")
        expect_finished(2)

        control(home, session_id, "next prompt\r")
        control(home, session_id, "w")
        expect("program working wins", status="busy")
        control(home, session_id, "s")
        service.read_for(1.2)
        expect("Stop cannot complete a working program", status="busy")
        expect_finished(2)
        control(home, session_id, "b")
        expect("program blocked wins", status="attention")
        control(home, session_id, "s")
        service.read_for(1.2)
        expect("Stop cannot complete a blocked program", status="attention")
        expect_finished(2)
        control(home, session_id, "i")
        expect("a newer idle report does not reuse an old Stop")
        service.read_for(1.2)
        expect_finished(2)
    finally:
        run_cli(home, ["rm", session_id], env=environment, timeout=45)


if __name__ == "__main__":
    run("codex_program_completion", body)
