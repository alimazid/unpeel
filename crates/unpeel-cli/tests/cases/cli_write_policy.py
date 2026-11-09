"""`unpeel send` from inside a hosted Session takes the MCP write policy.

Outside Unpeel the operator writes directly (cli.py proves that). Inside a
Session — an agent's subprocess, identified by UNPEEL_SESSION_ID — the same
verb is the MCP `send_text` action: the first write to another Session
blocks on the user's approval, an approved pair is remembered, and a denial
writes nothing.
"""

import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, mobile_request, run, run_cli, wait_running, TRUST_SESSION_ENV  # noqa: E402


def body(case):
    home = case.home
    home.project("p", "unpeel", "/tmp")
    home.preset(label="cat", command="cat")
    token = home.pair_device()
    phone_port = home.reserve_mobile_port()
    state = home.state()
    state["mcp_write_approvals"] = {}
    home.write_state(state)

    service = case.serve()
    ready = service.ready(timeout=15.0)
    if not case.check("serve starts", bool(ready), str(ready or service.log())):
        return

    ids = []
    for _ in range(2):
        started = run_cli(home, ["new", "--preset", "cat", "--project", "p"])
        ids.extend(word for word in started.stdout.split() if len(word) == 36 and word.count("-") == 4)
    if not case.check("two sessions start", len(ids) == 2 and all(wait_running(home, i) for i in ids), str(ids)):
        return
    caller, target = ids

    def send_from_caller(text):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=caller, **TRUST_SESSION_ENV)
        return subprocess.run(
            [BINARY, "send", target, text, "--enter"],
            capture_output=True, text=True, timeout=60, env=env, cwd=CRATES,
        )

    def screen(session_id):
        return run_cli(home, ["screen", session_id]).stdout

    def pending_approval():
        status, boot = mobile_request(phone_port, "/mobile/bootstrap", token)
        if status != 200:
            return {}
        return next((a for a in boot.get("pendingApprovals", []) if a.get("callerSessionID") == caller), {})

    def answer(approved):
        pending = pending_approval()
        return mobile_request(phone_port, "/mobile/approvals/answer", token, method="POST",
                              body={"id": pending["id"], "approved": approved})[0]

    # 1. The first write blocks until the user answers; nothing lands early.
    results = {}
    worker = threading.Thread(target=lambda: results.__setitem__("first", send_from_caller("first-write")))
    worker.start()
    pending = service.wait_for(pending_approval, timeout=15.0)
    case.check("a send from inside a Session raises a write approval", bool(pending) and pending.get("targetSessionID") == target, str(pending))
    time.sleep(1.0)
    case.check("nothing is written before the answer", "first-write" not in screen(target), screen(target)[-200:])
    case.check("the CLI is still blocked on the prompt", worker.is_alive())
    if pending:
        case.check("the Controller approves", answer(True) == 200)
    worker.join(timeout=30)
    first = results.get("first")
    case.check("the approved send succeeds", first is not None and first.returncode == 0, (first.stderr if first else "no result")[:200])
    case.check("the text reaches the target after approval",
               bool(service.wait_for(lambda: "first-write" in screen(target), timeout=10.0)), screen(target)[-200:])

    # 2. The approved pair is remembered: no prompt, immediate delivery.
    second = send_from_caller("second-write")
    case.check("an approved pair sends without a prompt", second.returncode == 0 and not pending_approval(), second.stderr[:200])
    case.check("the remembered pair delivers immediately",
               bool(service.wait_for(lambda: "second-write" in screen(target), timeout=10.0)), screen(target)[-200:])

    # 3. A denied write is refused and writes nothing.
    state = home.state()
    state["mcp_write_approvals"] = {}
    home.write_state(state)
    run_cli(home, ["settings", "set", "mcp_nonchild_write_access", "ask"])
    worker = threading.Thread(target=lambda: results.__setitem__("denied", send_from_caller("denied-write")))
    worker.start()
    pending = service.wait_for(pending_approval, timeout=15.0)
    if case.check("a cleared pair asks again", bool(pending), str(pending)):
        answer(False)
    worker.join(timeout=30)
    denied = results.get("denied")
    case.check("a denied send fails", denied is not None and denied.returncode != 0, (denied.stdout if denied else "")[:200])
    time.sleep(1.0)
    case.check("a denied send writes nothing", "denied-write" not in screen(target), screen(target)[-200:])

    # 4. A Session can never write into itself through this path.
    env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=caller, **TRUST_SESSION_ENV)
    own = subprocess.run([BINARY, "send", caller, "self", "--enter"], capture_output=True, text=True, timeout=30, env=env, cwd=CRATES)
    case.check("a Session cannot send into itself", own.returncode != 0, own.stderr[:200])

    for session_id in ids:
        run_cli(home, ["rm", session_id], timeout=30)


run("cli_write_policy", body)
