"""Screen reads mark suggested input.

Claude Code paints a proposed reply in its input box in SGR 2 (faint) with
the cursor parked on its first cell; as plain text it reads exactly like a
reply the user typed and left unsent. `sessions read_screen` and `inspect`
bracket it as `⟪suggested: …⟫` with a `suggested_input=` header line, and
leave typed input alone. Driven through `unpeel mcp`, the same dispatcher an
agent's MCP server uses, against sessions hosted by the real PTY core.
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running  # noqa: E402

# The prompt row as captured from a live Claude Code session: grey `❯` +
# NBSP, the suggestion faint, the cursor back on its first cell. Drawn on the
# bottom row (CUP clamps 999) so `inspect`'s bottom-rows tail covers it.
SUGGESTION = (
    r"printf '\033[2J\033[999;1H\033[38;2;153;153;153m\342\235\257\302\240\033[39m"
    r"\033[2mleave the epic assigned to me\033[22m\033[999;3H'; sleep 600"
)
TYPED = r"printf '\033[2J\033[999;1H\342\235\257\302\240fix the bug'; sleep 600"


def body(case):
    home = case.home
    home.project("p", "unpeel", "/tmp")
    home.preset(label="suggestion", command=SUGGESTION)
    home.preset(label="typed", command=TYPED)

    ids = {}
    for label in ("suggestion", "typed"):
        started = run_cli(home, ["new", "--preset", label, "--project", "p"])
        found = [word for word in started.stdout.split() if len(word) == 36 and word.count("-") == 4]
        if found:
            ids[label] = found[0]
    if not case.check("both sessions start", len(ids) == 2 and all(wait_running(home, i) for i in ids.values()), str(ids)):
        return

    def mcp(*words):
        # Each session reads the other; reads are open to any hosted caller.
        target = next((word.split("=", 1)[1] for word in words if word.startswith("session_id=")), "")
        caller = ids["typed"] if target == ids["suggestion"] else ids["suggestion"]
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=caller)
        return subprocess.run(
            [BINARY, "mcp", "sessions", *words],
            capture_output=True, text=True, timeout=60, env=env, cwd=CRATES,
        )

    def read_until(session_id, needle):
        result = mcp("read_screen", f"session_id={session_id}", "rows=3")
        for _ in range(40):
            if needle in result.stdout:
                break
            time.sleep(0.25)
            result = mcp("read_screen", f"session_id={session_id}", "rows=3")
        return result

    screen = read_until(ids["suggestion"], "leave the epic")
    out = screen.stdout
    case.check("read_screen brackets the suggestion", "❯ ⟪suggested: leave the epic assigned to me⟫" in out, out[:600])
    case.check("read_screen explains it in the header", 'suggested_input="leave the epic assigned to me"' in out and "Nobody typed it" in out, out[:600])

    inspected = mcp("inspect", f"session_id={ids['suggestion']}")
    case.check("inspect marks it in the screen tail", "⟪suggested: leave the epic assigned to me⟫" in inspected.stdout, inspected.stdout[-600:])
    case.check("inspect explains it", 'suggested_input="leave the epic assigned to me"' in inspected.stdout, inspected.stdout[-600:])

    waited = mcp("wait_for_text", f"session_id={ids['suggestion']}", "text=leave the epic", "timeout_ms=2000")
    case.check("wait_for_text still matches the plain text", waited.returncode == 0 and "⟪" not in waited.stdout, (waited.stdout or waited.stderr)[:300])

    typed = read_until(ids["typed"], "fix the bug")
    case.check("typed input is left unmarked", "❯ fix the bug" in typed.stdout and "⟪" not in typed.stdout and "suggested_input" not in typed.stdout, typed.stdout[:600])

    for session_id in ids.values():
        run_cli(home, ["rm", session_id], timeout=30)


run("suggested_input", body)
