"""An agent's send never lands on what the user is typing (#61).

`sessions send_text` / `send_keys`, and `unpeel send` from inside a Session,
ask the target's PTY core to refuse the write while the user typed in the
last 3 s (`typing`) or their unsent input is on the input line (`draft`);
nothing is written then. An empty box takes the send, a faint proposed reply
(suggested input) is no draft, and a select menu takes keys over a draft.
Driven through `unpeel mcp`, `unpeel send` and `unpeel keys`, the dispatcher
an agent's MCP server uses, against a session hosted by the real PTY core;
the user types on the attach stream (a terminal) and the control socket's
`Write` (the Mac app's controller writes). Since #65 a draft also ends when
the user erases every key of it, or when a program took the key and moved
on, even if the line kept for it was read before a redraw; a draft that
wraps, continues on a row of its own, or has output streaming above it
still refuses. Since #66 `sessions report` with no Host worker running (it
pastes at once, `delivery: immediate_legacy`) takes the same guard: an empty
box takes it, typing or a draft refuses it at once with nothing written.
Since #72 a menu counts only below a shown cursor: output that quotes a
menu's footer above the line disarms no draft, typed before or after it,
while a menu that hides the cursor under its footer still takes keys.
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
    the line (logged), a bracketed paste joins it, Alt+Enter starts a row in
    it. Ctrl+] paints a faint suggestion at the cursor while the line is
    empty; Ctrl+N opens a select menu under it, which takes keys until Enter.
    For #65: Ctrl+O makes the next submitting Enter wait 1.5 s before the
    line is redrawn; Ctrl+Y asks a one-key question below the line, which
    takes the next key without Enter and prompts again; Ctrl+B draws the line
    as a TUI does (rows of 40, continued indented) or as typed; Ctrl+P
    streams output above the line, each output row in two writes. For #72:
    Ctrl+T prints output above the line that quotes a menu; Ctrl+K opens a
    select menu that hides the cursor under its footer, where Codex leaves
    it, on a row that Down redraws."""
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + f'''
import os, time, tty
tty.setraw(0)
line, ghost, menu = "", False, False
slow_enter, one_key, box, rows_drawn = False, False, False, 0
def rows_of(text):
    rows = []
    for part in text.split("\\n"):
        width = 40 if box else max(len(part), 1)
        rows.extend(part[i:i + width] for i in range(0, max(len(part), 1), width))
    return rows
def back_to_line():
    return "\\x1b[%dF" % rows_drawn if rows_drawn else "\\r"
def draw():
    global rows_drawn
    rows = rows_of("> " + line)
    out = back_to_line() + "\\x1b[J" + "\\r\\n  ".join(rows)
    rows_drawn = len(rows) - 1
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
            os.write(1, b"\\x1b8\\x1b[?25h\\x1b7\\r\\n\\x1b[J\\x1b8")
        elif menu == "hidden" and data == b"\\x1b[B":
            os.write(1, b"\\r\\x1b[Kselected 2")
        continue
    if one_key:
        one_key, rows_drawn = False, 0
        log({submitted!r}, b"TOOK " + data + b"\\n")
        os.write(1, data + b"\\r\\ndeleted\\r\\n")
    elif data == b"\\x1d":
        ghost = True
    elif data == b"\\x0e":
        menu = "under"
        os.write(1, "\\x1b7\\r\\n  1. Yes\\r\\n  2. No\\r\\n\\u2191/\\u2193 to navigate \\u00b7 Enter to select\\x1b8".encode())
        continue
    elif data == b"\\x0b":
        menu = "hidden"
        os.write(1, "\\x1b7\\x1b[?25l\\r\\n\\u276f 1. Yes\\r\\n  2. No\\r\\nPress enter to confirm or esc to cancel\\r\\nselected 1".encode())
        continue
    elif data == b"\\x14":
        os.write(1, (back_to_line() + "\\x1b[J\\u23fa It printed:\\r\\n\\u276f 1. Yes\\r\\n  2. No\\r\\n"
                     + "Enter to select \\u00b7 \\u2191/\\u2193 to navigate \\u00b7 Esc to cancel\\r\\n").encode())
        rows_drawn = 0
    elif data == b"\\x0f":
        slow_enter = True
        continue
    elif data == b"\\x19":
        one_key = True
        os.write(1, b"\\r\\nDelete it? [y/n] ")
        continue
    elif data == b"\\x02":
        box = not box
    elif data == b"\\x10":
        for i in range(30):
            os.write(1, (back_to_line() + "\\x1b[Joutput " + str(i)).encode())
            time.sleep(0.02)
            os.write(1, b"\\r\\n")
            rows_drawn = 0
            draw()
            time.sleep(0.08)
        log({submitted!r}, b"STREAMED\\n")
        continue
    elif data.startswith(b"\\x1b[200~"):
        line += data[6:].split(b"\\x1b[201~")[0].decode("utf-8", "replace").replace("\\n", " ")
    elif data == b"\\x1b\\r":
        line += "\\n"
    elif data == b"\\r":
        if line:
            log({submitted!r}, ("SUBMITTED " + line.replace("\\n", "|") + "\\n").encode())
            if slow_enter:
                slow_enter = False
                time.sleep(1.5)
            os.write(1, b"\\r\\n")
            rows_drawn = 0
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

    def report(summary):
        return as_caller("mcp", "sessions", "report", f"session_id={agent}",
                         f"summary={summary}")

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
        done = report("report-into-an-empty-box")
        case.check("a report to an empty box with no Host worker is pasted at once",
                   done.returncode == 0 and '"immediate_legacy"' in done.stdout
                   and "unguarded" not in done.stdout
                   and until(lambda: "report-into-an-empty-box" in read(submitted)), said(done))

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
        done = report("report-while-typing")
        case.check("a report while the user types is refused as typing",
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
        # A refusal is final: the old paste retried a failed write for 20 s.
        started = time.time()
        done = report("report-onto-a-draft")
        took = time.time() - started
        case.check("a report onto the draft is refused at once, not retried",
                   done.returncode != 0 and "Not sent (draft)" in done.stderr and took < 5,
                   f"{took:.1f}s " + said(done))
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

        def refused_as_draft(done):
            return done.returncode != 0 and "Not sent (draft)" in done.stderr

        def delivered(done, text):
            return done.returncode == 0 and until(lambda: text in read(submitted))

        def submit_the_line(text):
            typed_on_attach(b"\r")
            return until(lambda: f"SUBMITTED {text}\n" in read(submitted))

        # 7. A key typed right after Enter, before the line is redrawn (#65):
        # the core keeps the line just sent as the one before the key. The
        # key is a draft; once erased, a send lands without another Enter.
        program("\x0f")
        typed_on_attach(b"sent-before-the-race")
        typed_on_attach(b"\r")
        typed_on_attach(b"x")
        case.check("the line is redrawn late with the raced key on it",
                   until(lambda: "SUBMITTED sent-before-the-race" in read(submitted))
                   and until(lambda: "> x" in screen(), timeout=5), screen()[-300:])
        time.sleep(QUIET)
        done = send_text("onto-the-raced-key")
        case.check("the raced key is a draft", refused_as_draft(done), said(done))
        typed_on_attach(b"\x7f")
        time.sleep(QUIET)
        done = send_text("after-erasing-the-raced-key")
        case.check("a send after the raced key is erased is delivered",
                   delivered(done, "after-erasing-the-raced-key"), said(done))

        # 8. A one-key prompt takes `y` without Enter, says so and prompts
        # again two rows down (#65): nothing of the user's is on the line.
        program("\x19")
        until(lambda: "Delete it? [y/n]" in screen(), timeout=5)
        typed_on_attach(b"y")
        case.check("the program took the key", until(lambda: "TOOK y" in read(submitted)),
                   read(submitted)[-200:])
        time.sleep(QUIET)
        done = send_text("after-the-one-key-prompt")
        case.check("a send after a one-key prompt took the key is delivered",
                   delivered(done, "after-the-one-key-prompt"), said(done))

        # 9. Drafts that leave the row they started on stay drafts: one the
        # terminal wraps, one on a row of its own (Alt+Enter), one a TUI
        # wraps into indented rows.
        long = "w" * 150 + "-wrapped"
        typed_on_attach(long.encode())
        time.sleep(QUIET)
        done = send_text("onto-a-wrapped-draft")
        case.check("a send onto a draft the terminal wraps is refused",
                   refused_as_draft(done), said(done))
        case.check("the wrapped draft is submitted", submit_the_line(long), read(submitted)[-300:])
        typed_on_attach(b"first row")
        typed_on_attach(b"\x1b\r")
        typed_on_attach(b"second row")
        time.sleep(QUIET)
        done = send_text("onto-a-second-row")
        case.check("a send onto a draft's second row is refused",
                   refused_as_draft(done), said(done))
        case.check("the two-row draft is submitted", submit_the_line("first row|second row"),
                   read(submitted)[-300:])
        program("\x02")
        boxed = "b" * 90 + "-boxed"
        typed_on_attach(boxed.encode())
        time.sleep(QUIET)
        done = send_text("onto-a-boxed-draft")
        case.check("a send onto a draft a TUI wraps is refused",
                   refused_as_draft(done), said(done))
        case.check("the boxed draft is submitted", submit_the_line(boxed), read(submitted)[-300:])
        program("\x02")

        # 10. Output streaming above a draft moves its line down a row at a
        # time, each output row drawn in two writes: no send lands meanwhile.
        typed_on_attach(b"streamed-over")
        time.sleep(QUIET)
        program("\x10")
        sends = []
        while "STREAMED" not in read(submitted) and len(sends) < 40:
            sends.append(send_text("while-output-streams"))
        sends.append(send_text("after-output-streamed"))
        case.check("every send while output streams above a draft is refused",
                   len(sends) > 3 and all(refused_as_draft(done) for done in sends),
                   f"{len(sends)} sends: " + "; ".join(said(done) for done in sends
                                                      if not refused_as_draft(done))[:400])
        case.check("none of them was written",
                   not any(text in read(log) for text in ("while-output-streams",
                                                          "after-output-streamed")),
                   read(log)[-200:])
        case.check("the streamed-over draft is submitted", submit_the_line("streamed-over"),
                   read(submitted)[-300:])

        # 11. Output quoting a menu above the line is no menu (#72): the
        # cursor is shown on the line, under its footer. A draft the quote is
        # printed above keeps refusing, and so does every send onto a draft
        # typed with the quote already on screen.
        def quote():
            shown = screen().count("Esc to cancel")
            program("\x14")
            return until(lambda: screen().count("Esc to cancel") > shown, timeout=5)

        typed_on_attach(b"quoted-over")
        case.check("the quote is drawn above a draft", quote(), screen()[-300:])
        time.sleep(QUIET)
        done = send_text("onto-a-draft-under-a-new-quote")
        case.check("a send onto a draft a quote is printed above is refused",
                   refused_as_draft(done), said(done))
        case.check("the quoted-over draft is submitted", submit_the_line("quoted-over"),
                   read(submitted)[-300:])
        case.check("the quote is drawn above the empty line", quote(), screen()[-300:])
        typed_on_attach(b"typed-under-a-quote")
        time.sleep(QUIET)
        for name, done in (("send_text", send_text("onto-a-quoted-draft")),
                           ("`unpeel send`", cli_send("cli-onto-a-quoted-draft")),
                           ("a report", report("report-onto-a-quoted-draft"))):
            case.check(f"{name} onto a draft typed under a quoted menu is refused",
                       refused_as_draft(done), said(done))
        done = send_keys("x")
        case.check("send_keys onto it is refused too",
                   done.returncode != 0 and "Not sent (draft)" in done.stderr, said(done))
        case.check("none of them was written",
                   "onto-a-quoted-draft" not in read(log) and not read(log).endswith("x"),
                   read(log)[-200:])
        case.check("the draft typed under a quote is submitted",
                   submit_the_line("typed-under-a-quote"), read(submitted)[-300:])

        # 12. A menu that hides the cursor under its footer still takes
        # keys (#72): Down there starts no draft, so the agent's Enter
        # answers it.
        program("\x0b")
        case.check("the menu with a hidden cursor is drawn",
                   until(lambda: "selected 1" in screen(), timeout=5), screen()[-300:])
        typed_on_attach(b"\x1b[B")
        case.check("Down moves its selection",
                   until(lambda: "selected 2" in screen(), timeout=5), screen()[-300:])
        time.sleep(QUIET)
        done = send_keys("enter")
        case.check("the agent's Enter answers a menu whose cursor is hidden",
                   done.returncode == 0
                   and until(lambda: read(submitted).count("CHOSE") == 2), said(done))
    finally:
        for session_id in (agent, caller):
            if session_id:
                run_cli(home, ["rm", session_id], timeout=30)


run("send_text_draft_guard", body)
