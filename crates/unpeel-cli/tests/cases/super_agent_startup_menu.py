"""A Worker's first task never answers a startup menu (fork-only, #55).

A fake `codex` (no integration installed, so only the screen tier speaks)
opens on Codex's update menu, drawn as Codex 0.167 draws it: its selected
row starts with the `›` that Codex's `[screen]` rules read as the idle
prompt, and its footer is "enter continue · esc skip". Enter there means
"Update now": the fake logs it and exits to the fallback shell, as Codex
does after `npm install -g`.

The Router starts a Worker on it with a first task. The Host must see the
menu, so the task is held (`attention`) and no Enter reaches it. Once the
menu is answered with Skip, the composer comes up and the task is pasted
and submitted there. A second Worker whose menu is answered with Update now
exits to the shell before delivery: its task stays queued and is never
pasted into the shell.
"""

import json
import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import BINARY, CRATES, run, run_cli, wait_running  # noqa: E402
from hook_cancellation import control, fixture_started, read_json  # noqa: E402

HEADER = "[unpeel inbox for id:"
TASK = "Please fix the login form."
ACCEPTED = "UPDATE-ACCEPTED"
SUBMITTED = "TASK-SUBMITTED"
# Debounce (2 s) + the best-guess quiet window (10 s) + a rescan or two: a
# paste the menu would have taken lands well inside this.
HOLD_WINDOW = 20
# Each Worker's project, named for the answer its menu gets.
WHO = {"q": "Skip", "r": "Update now"}


def write_fixture(path):
    """Codex's update menu, then its composer. Logs every byte to
    `stdin.log` in its working directory and its own events to
    `events.log`."""
    package = os.path.join(os.path.dirname(CRATES), "runtimes", "codex")
    with open(os.path.join(package, "fixtures", "update-menu.txt")) as handle:
        menu = handle.read()
    with open(path, "w") as handle:
        handle.write(f"#!{sys.executable}\nMENU = {menu!r}\n" + '''
import os, time, tty
tty.setraw(0)
here = os.getcwd()
def event(word):
    with open(os.path.join(here, "events.log"), "a") as out:
        out.write(word + "\\n")
def screen(text):
    os.write(1, ("\\x1b[2J\\x1b[H" + text.replace("\\n", "\\r\\n")).encode())
def composer(above=""):
    return ">_ OpenAI Codex (v0.167.0)\\n\\n" + above + "\\u203a Ask Codex to do anything\\n\\n  ? for shortcuts"
os.write(1, b"\\x1b[?2004h")
os.write(1, b"HOOK_FIXTURE_PROCESS_STARTED\\r\\n")
screen(MENU)
on_menu, pasting, text = True, False, b""
while True:
    data = os.read(0, 4096)
    if not data or data == b"q":
        break
    with open(os.path.join(here, "stdin.log"), "ab") as out:
        out.write(data)
    if on_menu:
        # Like Codex's picker: pasted text is ignored, keys choose.
        if b"\\x1b[200~" in data:
            pasting = True
        if pasting:
            if b"\\x1b[201~" not in data:
                continue
            pasting = False
            data = data.split(b"\\x1b[201~", 1)[1]
        if data.startswith(b"\\r") or data.startswith(b"1"):
            event("''' + ACCEPTED + '''")
            screen("Updating Codex via `npm install -g @openai/codex`...\\n")
            os.write(1, b"\\r\\n")
            break
        if data.startswith(b"2") or data == b"\\x1b":
            on_menu = False
            event("SKIPPED")
            screen(composer())
        continue
    text += data
    if b"\\r" in text:
        typed = text.split(b"\\r", 1)[0].replace(b"\\x1b[200~", b"").replace(b"\\x1b[201~", b"")
        text = b""
        if typed.strip():
            event("''' + SUBMITTED + '''")
            screen(composer("\\u203a " + typed.decode("utf-8", "replace")[:60] + "\\n\\n"
                            + "\\u2022 Working (0s \\u2022 esc to interrupt)\\n\\n"))
            time.sleep(2)
            screen(composer("\\u2022 Done.\\n\\n"))
''')
    os.chmod(path, 0o755)


def body(case):
    home = case.home
    folders = {name: home.path(name) for name in ("p", "q", "r")}
    for folder in folders.values():
        os.makedirs(folder)
    home.project("p", "Router's", folders["p"])
    home.project("q", "Skips", folders["q"])
    home.project("r", "Updates", folders["r"])
    environment = {"HOME": home.root, "SHELL": "/bin/bash"}
    os.makedirs(home.path("bin"), exist_ok=True)
    fake = home.path("bin", "codex")
    write_fixture(fake)
    home.preset(label="codex", command=shlex.quote(fake), preset_id="codex")
    home.preset(label="cat", command="cat", preset_id="cat")

    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=25)), service.log()):
        return
    started = run_cli(home, ["new", "--preset", "cat", "--project", "p",
                             "--cwd", folders["p"]], env=environment)
    router = next((w for w in started.stdout.split() if len(w) == 36 and w.count("-") == 4), "")
    if not case.check("the Router starts", bool(router) and wait_running(home, router),
                      started.stdout + started.stderr):
        return
    state = home.state()
    state["super_agent"] = {"session_id": router, "since": 0}
    home.write_state(state)

    def mcp(session_id, action, args):
        env = dict(os.environ, UNPEEL_HOME=home.root, UNPEEL_TEST="1", UNPEEL_SESSION_ID=session_id)
        done = subprocess.run([BINARY, "mcp", "sessions", action, "--json", json.dumps(args)],
                              capture_output=True, text=True, timeout=60, env=env, cwd=CRATES)
        try:
            return json.loads(done.stdout), done
        except ValueError:
            return {}, done

    def read(project, name):
        try:
            with open(os.path.join(folders[project], name), "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def inbox(session_id):
        return mcp(session_id, "inbox", {})[0]

    def output(session_id):
        try:
            with open(home.path("app-sessions", session_id, "output.bin"), "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def manifest(session_id):
        return read_json(home.path("app-sessions", session_id, "manifest.json"))

    def runtime_id(session_id):
        runtime = manifest(session_id).get("runtime") or {}
        return (runtime.get("currentObservation") or {}).get("id", "")

    def start_worker(project):
        created, done = mcp(router, "create", {
            "preset": "codex", "project_id": project, "label": f"worker {project}",
            "task": "login bug", "text": TASK})
        worker = created.get("session_id", "")
        case.check(f"{WHO[project]}: the Router starts a Worker with its first task queued",
                   bool(worker) and bool(created.get("task_item_id")),
                   (done.stdout + done.stderr)[:400])
        return worker

    def held_at_menu(worker, project):
        case.check(f"{WHO[project]}: the fake is recognized as Codex",
                   bool(service.wait_for(lambda: "codex" in runtime_id(worker), timeout=15)),
                   str(manifest(worker).get("runtime")))
        case.check(f"{WHO[project]}: the Host sees the update menu",
                   bool(service.wait_for(lambda: manifest(worker).get("menu_prompt_active") is True,
                                         timeout=15)),
                   str({k: manifest(worker).get(k) for k in ("menu_prompt_active", "screen_activity")}))
        service.read_for(HOLD_WINDOW)
        case.check(f"{WHO[project]}: no Enter reached the menu", ACCEPTED not in read(project, "events.log"),
                   read(project, "events.log") + repr(read(project, "stdin.log")[-300:]))
        case.check(f"{WHO[project]}: nothing was typed into it", read(project, "stdin.log") == "",
                   repr(read(project, "stdin.log")[-300:]))
        listing = inbox(worker)
        case.check(f"{WHO[project]}: the task stays queued, held for the menu",
                   len(listing.get("pending", [])) == 1 and listing.get("hold") == "attention",
                   str(listing)[:400])

    workers = []
    try:
        # 1. The menu holds the first task; Skip brings the composer up and
        # the task is pasted and submitted there.
        skips = start_worker("q")
        workers.append(skips)
        if not skips or not fixture_started(case, service, home.path("app-sessions", skips)):
            return
        held_at_menu(skips, "q")
        control(home, skips, "2", origin="program")
        case.check("Skip: Skip brings the composer up",
                   bool(service.wait_for(lambda: "SKIPPED" in read("q", "events.log"), timeout=10)),
                   read("q", "events.log"))
        case.check("Skip: the task is pasted and submitted at the composer",
                   bool(service.wait_for(lambda: SUBMITTED in read("q", "events.log"), timeout=40))
                   and f"{HEADER}{skips}" in read("q", "stdin.log") and TASK in read("q", "stdin.log"),
                   read("q", "events.log") + repr(read("q", "stdin.log")[-300:]))
        case.check("Skip: the update was never accepted", ACCEPTED not in read("q", "events.log"),
                   read("q", "events.log"))
        case.check("Skip: the task is delivered",
                   bool(service.wait_for(lambda: not inbox(skips).get("pending"), timeout=10)),
                   str(inbox(skips))[:400])

        # 2. Update now exits to the shell before delivery: the task stays
        # queued and the shell never gets it.
        updates = start_worker("r")
        workers.append(updates)
        if not updates or not fixture_started(case, service, home.path("app-sessions", updates)):
            return
        held_at_menu(updates, "r")
        control(home, updates, "\r", origin="program")
        case.check("Update now: Update now exits the agent",
                   bool(service.wait_for(lambda: ACCEPTED in read("r", "events.log"), timeout=10)),
                   read("r", "events.log"))
        exited_at = len(output(updates))
        case.check("Update now: the fallback shell takes over",
                   bool(service.wait_for(
                       lambda: manifest(updates).get("state") == "running"
                       and not runtime_id(updates), timeout=15)),
                   str(manifest(updates).get("runtime")))
        service.read_for(HOLD_WINDOW)
        after = output(updates)[exited_at:]
        case.check("Update now: nothing of the task reached the shell",
                   HEADER not in after and TASK not in after, repr(after[-400:]))
        listing = inbox(updates)
        case.check("Update now: the task stays queued, held for no agent",
                   len(listing.get("pending", [])) == 1
                   and listing.get("hold") == "no_agent_authority",
                   str(listing)[:400])
    finally:
        for session_id in [router, *workers]:
            if session_id and os.path.isdir(home.path("app-sessions", session_id)):
                try:
                    control(home, session_id, "q")
                except OSError:
                    pass
                run_cli(home, ["rm", session_id], env=environment, timeout=45)


run("super_agent_startup_menu", body)
