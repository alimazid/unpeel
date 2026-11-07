# CLI + Host service tests

End-to-end coverage for `unpeel`: each case drives the **real binaries**
(`unpeel serve`, the one-shot verbs, `unpeel-host`) against a **private
`UNPEEL_HOME`**, and asserts on what lands on disk, what the Host publishes
over `/mobile`, `host.sock`, and the relay, and what a script sees.

```sh
./run.sh                  # everything (~10 min on a development Mac)
./run.sh pairing state    # cases whose name contains a filter
./run.sh -v compat_serve  # stream a case's own output
UNPEEL_TUI_SKIP_BUILD=1 ./run.sh   # skip the cargo build
```

`cargo test -p unpeel-cli` runs the unit tests and the in-process
`serve`/`settings` integration tests. The suites here are opt-in from cargo:

```sh
UNPEEL_TUI_PTY_TESTS=1 cargo test -p unpeel-cli --test pty_suites
```

(The `UNPEEL_TUI_*` variable names predate the removal of the terminal UI
and are kept so existing scripts and CI keep working: `UNPEEL_TUI_BINARY`,
`UNPEEL_TUI_SKIP_BUILD`, `UNPEEL_TUI_TEST_BASE`, `UNPEEL_TUI_TEST_HOME`,
`UNPEEL_TUI_PTY_TESTS`.)

## Why it is built this way

**Fixtures are per-case and built from scratch.** Cases used to share one
`UNPEEL_HOME` and mutate each other's state, which produced both false passes
and false failures depending on run order. `Case` creates and destroys its
own home, and the runner sweeps any hosted process or PTY core a case leaves
behind before deleting it.

**Assertions poll.** Hosts spawn, the worker rescans at 1 s, the relay
connects asynchronously. `Serve.wait_for(predicate)` and
`Pty.expect(...)` poll until the condition holds, so a slow machine is slow
rather than red.

**The home path must be short.** A hosted session binds
`<home>/app-sessions/<uuid>/session.sock`; `sockaddr_un` caps the path near
104 bytes. macOS `TMPDIR` alone is ~49, which silently breaks every host
spawn. The runner uses `/tmp/ut-<case>` and the harness refuses a home that
would overflow. Never run two `run.sh` invocations concurrently on one
machine: cases bind ports and spawn hosted processes.

## Writing a case

```python
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import run, run_cli

def body(case):
    home = case.home
    home.project("p", "unpeel", "/tmp")
    home.session("s1", label="a session", project_id="p", running=True)

    service = case.serve()
    case.check("the Host comes up", bool(service.ready()))
    listed = run_cli(home, ["ls"])
    case.check("the session is listed", "a session" in listed.stdout)

run("my-case", body)
```

Useful pieces:

| | |
|---|---|
| `case.serve(env=…)` | a foreground scoped `unpeel serve` (`ready`, `wait_for`, `read_for`, `status`, `log`, `close`) |
| `run_cli(home, [...])` | the one-shot CLI against the same home |
| `case.pty(args=("pair",))` | a real PTY for verbs that draw (the pairing QR); `expect`, `send`, `grid` |
| `case.app()` | a mock desktop app: owns a port, answers `/mcp/*`, records `calls`; `fail_routes=` simulates an **older** app |
| `case.host(id)` | a fake session host on the control socket — records writes, resizes, and agent-restart generations |
| `home.session(...)` | a hosted-session dir; `running=True` parks a real pid and binds a socket |
| `home.marker(...)` | shared markers (`title.json`, `read.json`, `project-override.json`; a legacy `archived.json` to exercise the upgrade migration) |
| `home.pair_device()` / `home.reserve_mobile_port()` | a paired phone token and the published phone endpoint |
| `mobile_request(port, path, token)` | an authenticated `/mobile/*` call over TLS, pinned to the Host certificate the way a phone pins (`host_certificate_pin(home)`); `plaintext_mobile_request` is the cleartext shape the Host must refuse with 426 |
| `McpClient(home, session_id)` | a `unpeel-host __mcp__` child speaking JSON-RPC for one caller Session (`tool_names`, `call`, `McpClient.text`) |

Name checks as the behaviour a user would recognise ("stop leaves the session
listed as stopped"), not the mechanism. Pass a `detail` argument — it is
printed only when the check fails.

## What is covered

| case | what it protects |
|---|---|
| `standalone` | `unpeel serve` is a complete persistent Host with no app: verbs, restart, lease |
| `mobile` | bootstrap, output, organization (incl. an older phone's `archived` patch), the legacy-archive upgrade migration, polite-guest port rules for a paired phone |
| `pairing` | QR + pairing against the **shipped Swift crypto**, `unpeel pair` through the worker |
| `approvals` | MCP approvals owned by the Host, answerable from a phone |
| `host_launch_conformance` | native and headless launchers enter the same canonical Host runtime (71 conformance cases) |
| `cli` | headless verbs, including live agent-only restart vs stopped terminal Resume |
| `browser_spawn` | Browser MCP engine launch from a Session |
| `ctrlc_fallback` | Ctrl-C into a fresh preset Session lands in the fallback shell |
| `startup_exit` | a launch command's exit status (0, 3, 128 + signal, a quit agent) lands in `startup-exit` before the fallback shell |
| `schedules` | Scheduled Tasks on script presets: Run now records done / failed with the exit code, a Once task fires on its own with no app and disables itself, overlap is skipped without the skip replacing the live Run (it still blocks Run now and its finish lands), verbs refuse inside a Session |
| `schedules_agents` | Scheduled Tasks on Agent Presets: instructions typed once the agent is ready (several lines arrive as one submission); screen-tier and OSC 7501 fakes reach done with their snippet, a question needs you (Run now refused) until answered, a never-ready agent fails to start, a task without instructions is done once its agent is ready; done again with a stand-in native app owning notification edges; `add`/`edit --instructions` refused for a non-agent preset |
| `schedules_retention` | Run Sessions after a Run: each Run's start stops the previous Run's idle Session, the latest stays live, Runs never push the user's own stopped Sessions out of a Project, each task keeps its newest 5 stopped Run Sessions and removes the oldest with its directory (kept output included), deleting the task leaves them |
| `schedules_latest_run` | PROJECTS lists only each task's latest Run: after three Runs, both session-row builders (`/mobile/bootstrap` for a paired phone, and over `host.sock` for the Mac app) mark every Run Session with `scheduleID`, the latest Run's `superseded: false` and the older two `true`, the user's rows with neither; Runs never push the user's stopped rows off either wire |
| `schedules_run_output` | A stopped Run Session keeps its output (ADR 0006): `unpeel logs` prints a script Run's line once the next Run stops it, after `unpeel stop`, and after a Host restart plus the exited-journal compaction pass; MCP `sessions read_output` reads it; a Session that is not a Run still stops with an empty `output.bin` |
| `schedules_edit` | every Trigger kind (hourly, daily, weekdays, weekly, once, cron) stored canonically with its next run published; invalid cron and impossible times refused at save time; `edit` changes each field and passes unknown ones through; `pause` stops firing, `resume` restarts the clock with no catch-up, then a weekly task fires on its own; verbs refuse inside a Session |
| `schedules_mcp` | Scheduled Tasks over the MCP `workspace` tool from inside a Session: `list_schedules` shows definition, next run and last Run; `list_schedule_runs` is newest first with status, times, late and snippet, and honours `limit`; help documents both, the four writes and `schedules add` are refused for a Session that is not the Super Agent, and Create & remove cannot close a Run Session |
| `super_agent_schedules` | The Super Agent manages Scheduled Tasks over the MCP `workspace` tool against a live Host: create (preset label resolved, Trigger stored canonically, the answer carries the next run), Agent Preset instructions saved paused, the Host's refusal codes (`not_agent_preset`, `trigger_in_past`) save nothing, edit renames and moves the Trigger, pause/resume, Run now finishes, delete keeps the Run Session; the worker pings the state bus once it publishes a moved next run; any other Session is refused every write (MCP and CLI) while the Super Agent may use `unpeel schedules`; with the Host stopped a write changes nothing |
| `schedules_routes` | Scheduled Tasks over `/mobile`: bootstrap advertises `schedule.list` / `schedule.runs` and a moving `schedulesRevision`; the list shows next run and last Run, history is newest first; a recorded Run pings the state bus (`schedules`); both routes read the files on disk |
| `schedules_writes` | Scheduled Tasks written by a Controller over `/mobile` and the local socket: bootstrap advertises `schedule.create` / `.edit` / `.delete` / `.run` and flags Agent Presets; a created task is stored with its Trigger in stored form and fires at its time; edit, pause and resume round-trip; Run now is refused (409) while a Run is in progress; delete keeps the Run Session; a past Once, instructions on a script preset or an unknown task are refused and nothing is saved |
| `schedules_run_refusals` | Run now's refusals keep their own reason on every wire: a task whose `runs.jsonl` will not read is refused by `unpeel schedules run` with the Host's "cannot tell whether a Run … is in progress" message, by `POST /mobile/schedules/run` as 500 `run_log_unreadable` naming the task, and by the Super Agent's MCP `run_schedule` with that code; a Run already queued, and one really in progress, still answer 409 `run_in_progress` on the CLI and the route |
| `pty_core_*` | the shared PTY core: parity, adoption, in-place handoff |
| `serve_install` | `unpeel serve install|uninstall|status` unit rendering (shim-tested) |
| `state_bus` | cross-frontend sync: pings land immediately, writes announce |
| `link_enroll` / `link_lifecycle` / `link_token_rotation` | scripted Link enrollment; the live-serve refresh/reject/race ladder; relay credential rotation |
| `relay_conformance` | the Host's relay uplink against the shipped known-answer vectors |
| `full_disk` | a Session on a 4 MiB volume that fills up: the child is reaped (no zombie), the exited manifest lands once space returns, `rm` works (SKIPPED without hdiutil / passwordless tmpfs) |
| `compat_state` | **upgrade safety**: unmodelled keys, legacy/future manifests, corrupt files, through the Host and the CLI |
| `compat_bridge` | **version skew**: this CLI/Host beside an older app that 404s new routes |
| `compat_serve` | **version skew**: the shipped 0.4.3 `unpeel` beside this tree's binaries over one home, both directions |
| `compat_schedules` | **upgrade safety**: app-state without `schedules` loads; an unknown Trigger kind or damaged task never fires and never costs the rest of the file |

The `compat_*` cases exist because users update the app and the CLI
independently. Treat a failure there as "this would break someone's
install", not as a test needing adjustment. `compat_serve` needs the pinned
archive: it is cached under `~/Library/Caches/unpeel-matrix/<version>/`
(sha256 pinned in the case), `UNPEEL_MATRIX_COMPAT_ARCHIVE=<path>` overrides
for offline/CI runs, and when neither is available the case prints a
`NOTE … SKIPPED` line rather than passing silently.
