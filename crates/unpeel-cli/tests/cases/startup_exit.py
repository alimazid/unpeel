"""A Session's launch command records its exit status in ``startup-exit``.

The Host runs ``$SHELL -l -i -c '<startup script>'``: the preset's command,
then an exec of the fallback login shell. Before that exec the script writes
the command's ``$?`` to ``app-sessions/<id>/startup-exit`` (temporary file,
then rename), so the Host can tell the command exited and how. Checked
against the real binaries for a clean exit, ``exit 3``, a command killed by
Ctrl-C (128 + SIGINT), and an interactive program the user quits; each time
the Session must keep running in its fallback shell.
"""

import json
import os
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run  # noqa: E402

CTRL_C = "\u0003"

# A stand-in for an interactive agent: draws a prompt, waits for the user,
# and quits with its own status when told to.
FAKE_AGENT = """#!/bin/sh
printf 'fake-agent> '
while read -r line; do
  if [ "$line" = "/quit" ]; then
    exit 5
  fi
  printf 'fake-agent> '
done
exit 9
"""


def control(home, session_id, request):
    path = home.path("app-sessions", session_id, "session.sock")
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(5)
        client.connect(path)
        client.sendall((json.dumps(request) + "\n").encode())
        return client.recv(4096)


def new_session(home, preset_id):
    started = subprocess.run(
        [BINARY, "new", "--preset", preset_id, "--project", "p"],
        capture_output=True,
        text=True,
        timeout=45,
        env=dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_PTY_CORE="0"),
        cwd=CRATES,
    )
    for token in started.stdout.split():
        if len(token) == 36 and token.count("-") == 4:
            return token, started
    return "", started


def record_path(home, session_id):
    return home.path("app-sessions", session_id, "startup-exit")


def wait_for_record(home, session_id, timeout=45):
    path = record_path(home, session_id)
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            with open(path) as handle:
                return handle.read()
        except FileNotFoundError:
            time.sleep(0.2)
    return None


def child_named(pid, name):
    out = subprocess.run(
        ["pgrep", "-P", str(pid), "-f", name], capture_output=True, text=True
    )
    return out.stdout.split()


def wait_for_child(home, session_id, name, timeout=60):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        pid = home.manifests().get(session_id, {}).get("pid")
        if pid and child_named(pid, name):
            return pid
        time.sleep(0.25)
    return None


def check_recorded(case, home, label, session_id, expected):
    recorded = wait_for_record(home, session_id)
    case.check(
        f"{label}: the exit status is recorded as {expected}",
        recorded is not None and recorded.strip() == expected,
        repr(recorded),
    )
    leftovers = sorted(
        name
        for name in os.listdir(home.path("app-sessions", session_id))
        if name.startswith("startup-exit")
    )
    case.check(
        f"{label}: the record was renamed into place",
        leftovers == ["startup-exit"],
        str(leftovers),
    )
    # The fallback shell takes over the PTY: the Session keeps running and
    # its manifest exit code (the PTY child's) stays unset.
    time.sleep(1.5)
    manifest = home.manifests().get(session_id, {})
    case.check(
        f"{label}: the Session keeps running in its fallback shell",
        manifest.get("state") == "running" and manifest.get("exit_code") is None,
        str({"state": manifest.get("state"), "exit_code": manifest.get("exit_code")}),
    )
    reply = control(home, session_id, {"type": "ping"})
    case.check(f"{label}: the Host still answers", b'"ok":true' in reply, reply[:120])
    with open(home.path("app-sessions", session_id, "output.bin"), "rb") as handle:
        output = handle.read()
    case.check(
        f"{label}: recording prints nothing to the terminal",
        b"startup-exit" not in output and b"__unpeel" not in output,
        output[-200:],
    )


def check_command(case, home, label, preset_id, expected):
    session_id, started = new_session(home, preset_id)
    case.check(f"{label}: new starts a Session", bool(session_id), started.stderr[:200])
    if not session_id:
        return
    check_recorded(case, home, label, session_id, expected)
    control(home, session_id, {"type": "kill"})


def check_interrupted(case, home):
    label = "Ctrl-C"
    session_id, started = new_session(home, "sleep")
    case.check(f"{label}: new starts a Session", bool(session_id), started.stderr[:200])
    if not session_id:
        return
    shell_pid = wait_for_child(home, session_id, "sleep")
    case.check(f"{label}: the command runs under the wrapper shell", bool(shell_pid))
    case.check(
        f"{label}: nothing is recorded while the command runs",
        not os.path.exists(record_path(home, session_id)),
    )
    if not shell_pid:
        return
    control(home, session_id, {"type": "write", "data": CTRL_C})
    check_recorded(case, home, label, session_id, "130")
    control(home, session_id, {"type": "kill"})


def check_quit_agent(case, home, agent_path):
    label = "quit agent"
    session_id, started = new_session(home, "agent")
    case.check(f"{label}: new starts a Session", bool(session_id), started.stderr[:200])
    if not session_id:
        return
    shell_pid = wait_for_child(home, session_id, agent_path)
    case.check(f"{label}: the agent is running", bool(shell_pid))
    if not shell_pid:
        return
    time.sleep(0.5)
    reply = control(home, session_id, {"type": "write", "data": "/quit\r"})
    case.check(f"{label}: the quit is typed", b'"ok":true' in reply, reply[:120])
    check_recorded(case, home, label, session_id, "5")
    control(home, session_id, {"type": "kill"})


def body(case):
    home = case.home
    agent_path = home.path("fake-agent")
    with open(agent_path, "w") as handle:
        handle.write(FAKE_AGENT)
    os.chmod(agent_path, 0o755)

    home.project("p", "unpeel", "/tmp")
    home.preset(label="ok", command="true", preset_id="ok")
    home.preset(label="three", command="/bin/sh -c 'exit 3'", preset_id="three")
    home.preset(label="sleep", command="sleep 120", preset_id="sleep")
    home.preset(label="agent", command=agent_path, preset_id="agent")

    check_command(case, home, "exit 0", "ok", "0")
    check_command(case, home, "exit 3", "three", "3")
    check_interrupted(case, home)
    check_quit_agent(case, home, agent_path)


if __name__ == "__main__":
    run("startup_exit", body)
