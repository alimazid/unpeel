"""A Codex Session gets the Unpeel tools only through its supported launch (#54).

Codex 0.156+ attaches every interactive launch to a shared background
app-server daemon unless `--no-daemon` is on the command line, and that
daemon starts MCP servers outside any Session. A fake Codex runs the
`[mcp_servers.unpeel]` command the installed integration registered, the
way the real one does (codex-rs/rmcp-client: environment cut down to
DEFAULT_ENV_VARS, newline-delimited JSON-RPC on stdio):

* with `--no-daemon` (the suggested preset, taken from the runtime package)
  the server is its direct child, as under Codex's embedded app-server, so
  the gate finds the Session through process ancestry and serves its tools;
* without it the server is started detached, its parent no longer in the
  Session, as under the daemon, and the gate must fail closed.

The real Codex is never run here.
"""

import json
import os
import re
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import REPO, McpClient, run, run_cli  # noqa: E402
from hook_cancellation import control, read_json  # noqa: E402

UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"

FAKE_CODEX = '''
import json, os, select, subprocess, sys, time

# codex-rs/rmcp-client/src/utils.rs DEFAULT_ENV_VARS (unix), rust-v0.167.0.
DEFAULT_ENV_VARS = ["HOME", "LOGNAME", "PATH", "SHELL", "USER", "__CF_USER_TEXT_ENCODING",
                    "LANG", "LC_ALL", "TERM", "TMPDIR", "TZ"]

def registration():
    path = os.path.join(os.environ["HOME"], ".codex", "config.toml")
    table, server = None, {}
    for line in open(path).read().splitlines():
        line = line.strip()
        if line.startswith("["):
            table = line
        elif table == "[mcp_servers.unpeel]" and " = " in line:
            key, value = line.split(" = ", 1)
            server[key] = json.loads(value)
    return server

def start_embedded(argv, env):
    child = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    return child.pid, child.stdin.fileno(), child.stdout.fileno()

def start_detached(argv, env):
    # Double fork into a new session: the server's parent becomes launchd,
    # as for a server the shared daemon starts.
    to_server, from_server, report = os.pipe(), os.pipe(), os.pipe()
    middle = os.fork()
    if middle == 0:
        os.setsid()
        server = os.fork()
        if server == 0:
            os.dup2(to_server[0], 0)
            os.dup2(from_server[1], 1)
            os.execve(argv[0], argv, env)
        os.write(report[1], str(server).encode())
        os._exit(0)
    os.waitpid(middle, 0)
    pid = int(os.read(report[0], 32))
    for fd in (to_server[0], from_server[1], report[0], report[1]):
        os.close(fd)
    return pid, to_server[1], from_server[0]

def converse(write_fd, read_fd):
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "fake-codex", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
            "name": "sessions", "arguments": {"action": "current"}}},
    ]
    os.write(write_fd, "".join(json.dumps(r) + "\\n" for r in requests).encode())
    responses, buffered, deadline = {}, b"", time.time() + 30
    while 3 not in responses and time.time() < deadline:
        ready, _, _ = select.select([read_fd], [], [], 1)
        if not ready:
            continue
        chunk = os.read(read_fd, 65536)
        if not chunk:
            break
        buffered += chunk
        while b"\\n" in buffered:
            line, buffered = buffered.split(b"\\n", 1)
            if line.strip():
                message = json.loads(line)
                responses[message.get("id")] = message
    os.close(write_fd)
    os.close(read_fd)
    return responses

def parent_of(pid):
    out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(out.strip()) if out.strip() else None

def wait_gone(pid):
    for _ in range(100):
        if subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode != 0:
            return True
        time.sleep(0.1)
    return False

mode = "embedded" if "--no-daemon" in sys.argv[1:] else "daemon"
server = registration()
argv = [server["command"]] + server.get("args", [])
env = {name: os.environ[name] for name in DEFAULT_ENV_VARS if name in os.environ}
pid, write_fd, read_fd = (start_embedded if mode == "embedded" else start_detached)(argv, env)
parent = parent_of(pid)
responses = converse(write_fd, read_fd)
if mode == "embedded":
    os.waitpid(pid, 0)
result = {
    "mode": mode,
    "argv": sys.argv[1:],
    "server_parent": parent,
    "self_pid": os.getpid(),
    "tools": [tool.get("name") for tool in
              responses.get(2, {}).get("result", {}).get("tools", [])],
    "current": responses.get(3, {}),
    "server_exited": wait_gone(pid),
}
os.makedirs(os.path.join(os.environ["HOME"], "fake-codex"), exist_ok=True)
with open(os.path.join(os.environ["HOME"], "fake-codex", mode + ".json"), "w") as handle:
    json.dump(result, handle)
print("FAKE_CODEX_DONE " + mode, flush=True)
'''


def suggested_codex_command():
    """The `codex` preset command the runtime package ships."""
    with open(os.path.join(REPO, "runtimes", "codex", "runtime.toml")) as handle:
        descriptor = handle.read()
    preset = descriptor.split("[[suggested_presets]]", 1)[1]
    return json.loads(re.search(r'^command = (".*")$', preset, re.MULTILINE).group(1))


def output_has(session_dir, needle):
    try:
        with open(os.path.join(session_dir, "output.bin"), "rb") as output:
            return needle in output.read()
    except OSError:
        return False


def body(case):
    home = case.home
    home.project("p", "Codex", home.root)
    os.makedirs(home.path("bin"), exist_ok=True)
    fake = home.path("bin", "codex")
    with open(fake, "w") as handle:
        handle.write(f"#!{sys.executable}\n" + FAKE_CODEX)
    os.chmod(fake, 0o755)
    # Codex hands its MCP servers HOME but not UNPEEL_HOME, so the gate finds
    # the Unpeel home at ~/.unpeel, as in a real install.
    os.symlink(home.root, home.path(".unpeel"))
    environment = {"SHELL": "/bin/bash"}
    suggested = suggested_codex_command()
    case.check("the suggested Codex preset runs without the shared daemon",
               suggested.split()[:2] == ["codex", "--no-daemon"], suggested)
    # The login shell rebuilds PATH, so `codex` could resolve to an installed
    # Codex. Run the preset's arguments with the fake's absolute path instead.
    arguments = suggested.split()[1:]
    home.preset(label="codex", preset_id="codex",
                command=shlex.join([fake] + arguments))
    service = case.serve(env=environment)
    if not case.check("isolated Host starts", bool(service.ready(timeout=20)), service.log()):
        return
    installed = run_cli(home, ["integrations", "install", "codex"], env=environment)
    case.check("the Codex integration installs into the private HOME",
               installed.returncode == 0, installed.stderr)
    config = open(home.path(".codex", "config.toml")).read()
    case.check("[mcp_servers.unpeel] runs the shim and forwards no Unpeel variable",
               "[mcp_servers.unpeel]" in config and "unpeel-mcp" in config
               and "UNPEEL_" not in config, config)
    launched = run_cli(home, ["new", "--preset", "codex", "--project", "p", "--cwd", home.root],
                       env=environment)
    ids = re.findall(UUID, launched.stdout)
    if not case.check("Codex launches from its preset", launched.returncode == 0 and bool(ids),
                      launched.stderr):
        return
    session_id = ids[0]
    session_dir = home.path("app-sessions", session_id)
    try:
        embedded_done = bool(service.wait_for(
            lambda: output_has(session_dir, b"FAKE_CODEX_DONE embedded"), timeout=90))
        embedded = read_json(home.path("fake-codex", "embedded.json"))
        if not case.check("the preset's Codex starts the registered MCP server", embedded_done,
                          run_cli(home, ["screen", session_id], env=environment).stdout):
            return
        case.check("the --no-daemon server is a child of the Session's Codex",
                   embedded.get("server_parent") == embedded.get("self_pid"), str(embedded))
        tools = embedded.get("tools", [])
        case.check("the gate serves the Unpeel tools to the Session's Codex",
                   "sessions" in tools and "agents" in tools, str(tools))
        case.check("the tools act as this Session",
                   session_id in McpClient.text(embedded.get("current", {})), str(embedded.get("current")))

        # The same Codex without the flag, as Codex's daemon would start it.
        without_flag = [word for word in arguments if word != "--no-daemon"]
        control(home, session_id, shlex.join([fake] + without_flag) + "\r")
        daemon_done = bool(service.wait_for(
            lambda: output_has(session_dir, b"FAKE_CODEX_DONE daemon"), timeout=60))
        daemon = read_json(home.path("fake-codex", "daemon.json"))
        if not case.check("the daemon-style launch starts the registered MCP server", daemon_done,
                          run_cli(home, ["screen", session_id], env=environment).stdout):
            return
        case.check("the daemon-style server runs outside the Session",
                   daemon.get("server_parent") == 1, str(daemon))
        case.check("outside the Session the gate lists no tools",
                   daemon.get("tools") == [], str(daemon.get("tools")))
        current = daemon.get("current", {})
        case.check("outside the Session a tool call is refused",
                   "error" in current and session_id not in json.dumps(current), str(current))
        case.check("both MCP servers exit when Codex closes them",
                   embedded.get("server_exited") is True and daemon.get("server_exited") is True,
                   f"{embedded.get('server_exited')} {daemon.get('server_exited')}")
    finally:
        run_cli(home, ["rm", session_id], env=environment, timeout=45)


run("codex_mcp_tools", body)
