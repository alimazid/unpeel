"""An agent's send never lands on what the user is typing (#61).

`sessions send_text` / `send_keys`, and `unpeel send` from inside a Session,
ask the target's PTY core to refuse the write while the user typed in the
last 3 s (`typing`) or their unsent input is on the input line (`draft`);
nothing is written then. An empty box takes the send, a faint proposed reply
(suggested input) is no draft, and a select menu takes keys over a draft.
Driven through `unpeel mcp`, `unpeel send` and `unpeel keys`, the dispatcher
an agent's MCP server uses, against a session hosted by the real PTY core;
the user types on the attach stream (a terminal) and the control socket's
`Write` (the Mac app's controller writes).
"""

import json
import os
import shlex
import socket
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running  # noqa: E402
from hook_cancellation import control, read_json  # noqa: E402

# Past the guard's 3 s "is typing" window.
QUIET = 3.5
GHOST = "leave the epic assigned to me"


def write_fixture(path, log, submitted):
    """An input box: `> ` and what was typed, backspace erases, Enter submits
    the line (logged), a bracketed paste joins it. Ctrl+] paints a faint
    suggestion at the cursor while the line is empty; Ctrl+N opens a select
    menu under it, which takes keys until Enter."""
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + f'''
import os, tty
tty.setraw(0)
line, ghost, menu = "", False, False
def draw():
    out = "\\r\\x1b[2K> " + line
    if ghost and not line:
        out += "\\x1b[2m{GHOST}\\x1b[22m\\r\\x1b[2C"
    os.write(1, out.encode())
def log(path, data):
    with open(path, "ab") as out:
        out.write(data)
os.write(1, b"\\x1b[?2004hFIXTURE_STARTED\\r\\n")
draw()
while True:
    data = os.read(0, 65536)
    if not data:
        break
    log({log!r}, data)
    if menu:
        if b"\\r" in data:
            menu = False
            log({submitted!r}, b"CHOSE\\n")
            os.write(1, b"\\x1b7\\r\\n\\x1b[J\\x1b8")
        continue
    if data == b"\\x1d":
        ghost = True
    elif data == b"\\x0e":
        menu = True
        os.write(1, "\\x1b7\\r\\n  1. Yes\\r\\n  2. No\\r\\n\\u2191/\\u2193 to navigate \\u00b7 Enter to select\\x1b8".encode())
        continue
    elif data.startswith(b"\\x1b[200~"):
        line += data[6:].split(b"\\x1b[201~")[0].decode("utf-8", "replace").replace("\\n", " ")
    elif data == b"\\r":
        if line:
            log({submitted!r}, ("SUBMITTED " + line + "\\n").encode())
            os.write(1, b"\\r\\n")
        line = ""
    elif data.strip(b"\\x7f") == b"":
        line = line[:len(line) - len(data)]
    else:
        line += data.decode("utf-8", "replace")
    draw()
''')
    os.chmod(path, 0o755)


def body(case):
    home = case.home
    home.project("p", "unpeel", "/tmp")
    state = home.state()
    # No Controller answers approval prompts here.
    state["mcp_nonchild_write_access"] = "allow"
    home.write_state(state)
    os.makedirs(home.path("bin"), exist_ok=True)
    log, submitted = home.path("stdin.log"), home.path("submitted.log")
    program = home.path("bin", "input-box")
    write_fixture(program, log, submitted)
    home.preset(label="box", command=shlex.quote(program), preset_id="box")
    home.preset(label="cat", command="cat", preset_id="cat")

    def launch(preset):
        started = run_cli(home, ["new", "--preset", preset, "--project", "p"])
        ids = [w for w in started.stdout.split() if len(w) == 36 and w.count("-") == 4]
        return ids[0] if ids else ""

    agent, caller = launch("box"), launch("cat")
    if not case.check("both sessions start",
                      all((agent, caller)) and all(wait_running(home, i) for i in (agent, caller)),
                      str((agent, caller))):
        return

    def as_caller(*words):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=caller)
        return subprocess.run([BINARY, *words], capture_output=True, text=True, timeout=60,
                              env=env, cwd=CRATES)

    def send_text(text):
        return as_caller("mcp", "sessions", "send_text", f"session_id={agent}", f"text={text}")

    def send_keys(*keys):
        return as_caller("mcp", "sessions", "send_keys", f"session_id={agent}",
                         "keys=" + json.dumps(list(keys)))

    def cli_send(text):
        return as_caller("send", agent, text, "--enter")

    def cli_keys(*keys):
        return as_caller("keys", agent, *keys)

    def typed(data):
        # No `origin`: the user's keys, as the Mac app's controller writes them.
        return control(home, agent, data)

    def typed_on_attach(data):
        # The user's keys from a terminal: one attach stream input frame.
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(home.path("app-sessions", agent, "session.sock"))
            client.sendall(b'{"type":"stream_input"}\n')
            client.recv(1)
            client.sendall(struct.pack(">I", len(data)) + data)
            time.sleep(0.3)

    def program(data):
        return control(home, agent, data, origin="program")

    def read(path):
        try:
            with open(path, "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def screen():
        done = as_caller("mcp", "sessions", "read_screen", f"session_id={agent}")
        return done.stdout

    def until(predicate, timeout=10.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return True
            time.sleep(0.2)
        return False

    def said(done):
        return (done.stdout + done.stderr).strip()[:400]

    try:
        if not case.check("the input box is drawn",
                          until(lambda: "FIXTURE_STARTED" in read(home.path("app-sessions", agent, "output.bin"))),
                          read(home.path("app-sessions", agent, "output.bin"))[-200:]):
            return

        case.check("the core advertises the guard",
                   read_json(home.path("app-sessions", agent, "manifest.json")).get("draft_guard") is True)

        # 1. An empty box takes the send, from either surface.
        done = send_text("into-an-empty-box")
        case.check("a send to an empty box is delivered",
                   done.returncode == 0 and "Sent " in done.stdout and "unguarded" not in done.stdout
                   and until(lambda: "into-an-empty-box" in read(submitted)), said(done))
        done = cli_send("cli-into-an-empty-box")
        case.check("`unpeel send` to an empty box is delivered",
                   done.returncode == 0
                   and until(lambda: "cli-into-an-empty-box" in read(submitted)), said(done))

        # 2. The user is typing: refused, nothing written.
        # Whole ms, as the PTY core stamps it.
        before = int(time.time() * 1000)
        typed_on_attach(b"abc")
        done = cli_send("while-typing")
        case.check("`unpeel send` while the user types is refused as typing",
                   done.returncode != 0 and "Not sent (typing)" in done.stderr, said(done))
        done = send_text("mcp-while-typing")
        case.check("send_text while the user types is refused as typing",
                   done.returncode != 0 and "Not sent (typing)" in done.stderr, said(done))
        case.check("nothing of it was written", "while-typing" not in read(log), read(log)[-200:])
        case.check("the typing is stamped as current",
                   until(lambda: (read_json(home.path("app-sessions", agent, "manifest.json"))
                                  .get("last_input_at") or 0) >= before, timeout=5),
                   str(read_json(home.path("app-sessions", agent, "manifest.json")).get("last_input_at")))

        # 3. They paused on it: still their draft.
        time.sleep(QUIET)
        done = send_text("onto-a-draft")
        case.check("a send onto a paused draft is refused as a draft",
                   done.returncode != 0 and "Not sent (draft)" in done.stderr
                   and "read_screen" in done.stderr, said(done))
        done = cli_send("cli-onto-a-draft")
        case.check("`unpeel send` onto the draft is refused too",
                   done.returncode != 0 and "Not sent (draft)" in done.stderr, said(done))
        done = send_keys("x")
        case.check("send_keys onto the draft is refused too",
                   done.returncode != 0 and "Sent 0 of 1 keys" in done.stderr
                   and "Not sent (draft)" in done.stderr, said(done))
        case.check("none was written",
                   "onto-a-draft" not in read(log) and not read(log).endswith("x"), read(log)[-200:])
        case.check("the draft is untouched", "> abc" in screen(), screen()[-300:])

        # 4. A select menu over the draft takes the keys; the draft stays.
        program("\x0e")
        until(lambda: "to navigate" in screen(), timeout=5)
        done = cli_keys("down", "enter")
        case.check("`unpeel keys` answers a menu over a draft",
                   done.returncode == 0 and "Sent 2 keys" in done.stdout
                   and until(lambda: "CHOSE" in read(submitted)), said(done))
        done = send_text("after-the-menu")
        case.check("the draft under the menu still refuses a send",
                   done.returncode != 0 and "Not sent (draft)" in done.stderr, said(done))

        # 5. Cleared: the box takes the send again.
        typed("\x7f\x7f\x7f")
        time.sleep(QUIET)
        done = send_text("after-clearing")
        case.check("a send after the user clears the box is delivered",
                   done.returncode == 0 and until(lambda: "after-clearing" in read(submitted)),
                   said(done))

        # 6. A suggested reply on the line is no draft, even after the user
        # typed over it and erased it.
        program("\x1d")
        case.check("the suggestion is drawn", until(lambda: "⟪suggested:" in screen(), timeout=5),
                   screen()[-300:])
        typed("z")
        time.sleep(0.3)
        typed("\x7f")
        time.sleep(QUIET)
        case.check("the suggestion is back", "⟪suggested:" in screen(), screen()[-300:])
        done = cli_send("over-a-suggestion")
        case.check("`unpeel send` over a suggested reply is delivered",
                   done.returncode == 0 and until(lambda: "over-a-suggestion" in read(submitted)),
                   said(done))
    finally:
        for session_id in (agent, caller):
            if session_id:
                run_cli(home, ["rm", session_id], timeout=30)


run("send_text_draft_guard", body)
