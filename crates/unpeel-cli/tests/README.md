# CLI + Host service tests

End-to-end coverage for `unpeel`: each case drives the **real binaries**
(`unpeel serve`, the one-shot verbs, `unpeel-host`) against a **private
`UNPEEL_HOME`**, and asserts on what lands on disk, what the Host publishes
over `/mobile`, `host.sock`, and the relay, and what a script sees.

```sh
./run.sh                  # everything (~10 min on a development Mac)
./run.sh pairing state    # cases whose name contains a filter
./run.sh -v compat_serve  # stream a case's own output
./run.sh -j 3             # up to 3 of this run's cases at once
UNPEEL_TUI_SKIP_BUILD=1 ./run.sh   # skip the cargo build
```

Any number of runs may share a machine (one per worktree, say) with no
outside lock. Each case first takes one of `UNPEEL_TUI_SLOTS` machine-wide
slots (default 4, at most 9) under `/tmp/unpeel-pty-matrix.slots/`; a case
that finds them all busy waits, and its line says `(waited Ns for a slot)`.
A slot is a `flock`, so a run that dies frees its slot with no cleanup.
`UNPEEL_TUI_SLOTS` is the machine's load knob: every run on the machine
should use the same value. `-j` (or `UNPEEL_TUI_JOBS`, default 1) only lets
one run hold several slots at once.

`cargo test -p unpeel-cli` runs the unit tests and the in-process
`serve`/`settings` integration tests. The suites here are opt-in from cargo:

```sh
UNPEEL_TUI_PTY_TESTS=1 cargo test -p unpeel-cli --test pty_suites
```

(The `UNPEEL_TUI_*` variable names predate the removal of the terminal UI
and are kept so existing scripts and CI keep working: `UNPEEL_TUI_BINARY`,
`UNPEEL_TUI_SKIP_BUILD`, `UNPEEL_TUI_TEST_BASE`, `UNPEEL_TUI_TEST_HOME`,
`UNPEEL_TUI_PTY_TESTS`. The runner's newer knobs share the prefix:
`UNPEEL_TUI_SLOTS`, `UNPEEL_TUI_JOBS`, and `UNPEEL_TUI_SLOT_DIR`, which
moves the slots, and the homes with them, only for the runner's own
self-test, `scripts/verify-matrix-runner.sh`. That self-test may run beside a
real matrix.)

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
spawn. The runner names each home after its slot, `/tmp/s<slot>-<case>`
(one digit, as short as the old `/tmp/ut-<case>`), and the harness refuses a
home that would overflow. `host_launch_conformance`'s sub-homes are already
one byte under the limit, so `UNPEEL_TUI_TEST_BASE` (homes become
`<base>-<case>`) must stay as short as `/tmp/u1`, and the caller then owns
keeping it unique; leave it unset unless you need a fixed path. A private
`UNPEEL_TUI_SLOT_DIR` holds its homes, so it must be as short as the
self-test's `/tmp/mr.XXXXXX/slots`.

**Concurrent runs cannot meet.** A slot is held by one live case at a time
and names that case's home, so no two live cases share a home, and every
sweep (the runner's and `Case.finish()`'s) only touches processes bound to
one home: by argv, by `UNPEEL_HOME`, or by an open file under it, matched at
a path boundary so `/tmp/s1-cli` never claims `/tmp/s1-cli_write_policy`.
A case that takes slot N also clears every home named for slot N, which a
run that died may have left. So the homes belong to the slot directory: a
private one (`UNPEEL_TUI_SLOT_DIR`) keeps its homes inside itself, where no
run on the machine's slots ever looks.
Ports are never fixed. Hosts and fixtures bind `:0` and keep the socket;
the one port that has to be released and bound again later (the phone
endpoint, `reserve_mobile_port`) is a random free port below every OS
ephemeral range, so no `:0` bind anywhere on the machine can take it; only
another case drawing the same number from 20000–29999 in the same moment
could.

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
| `run_cli(home, [...])` | the one-shot CLI against the same home; an `UNPEEL_SESSION_ID` in `env=` acts as that Session through `TRUST_SESSION_ENV`, the test switch that trusts an exported id on a private home (ADR 0013), which never reaches a Session's own processes |
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
| `host_gateway_churn` | closed Controller connections release thread stacks while an existing Controller stays connected and can create sessions |
| `cli` | headless verbs, including live agent-only restart vs stopped terminal Resume |
| `browser_spawn` | Browser MCP engine launch from a Session |
| `ctrlc_fallback` | Ctrl-C into a fresh preset Session lands in the fallback shell |
| `startup_exit` | a launch command's exit status (0, 3, 128 + signal, a quit agent) lands in `startup-exit` before the fallback shell |
| `schedules` | Scheduled Tasks on script presets: Run now records done / failed with the exit code, a Once task fires on its own with no app and disables itself, overlap is skipped without the skip replacing the live Run (it still blocks Run now and its finish lands), verbs refuse inside a Session |
| `schedules_agents` | Scheduled Tasks on Agent Presets: instructions typed once the agent is ready (several lines arrive as one submission); screen-tier and OSC 7501 fakes reach done with their snippet, a question needs you (Run now refused) until answered, a never-ready agent fails to start, a task without instructions is done once its agent is ready; done again with a stand-in native app owning notification edges; `add`/`edit --instructions` refused for a non-agent preset |
| `schedules_follow` | A done agent Run keeps following its Session (#81): two OSC 7501 fakes are done at their first idle; the busy one's later turn moves the Run's end and snippet with the status still done, its `sessions report` blocked from inside the Session lands on the Run record and in `list_schedule_runs` (with `needsAttention`), a done report's turn ends it for good (a later turn changes nothing); the quiet one, which never reports, stays as its first idle left it while its Session sits live, and its agent's exit adds only a `session_ended` line |
| `schedules_retention` | Run Sessions after a Run: each Run's start stops the previous Run's idle Session, the latest stays live, Runs never push the user's own stopped Sessions out of a Project, each task keeps its newest 5 stopped Run Sessions and removes the oldest with its directory (kept output included), deleting the task leaves them |
| `schedules_latest_run` | PROJECTS lists only each task's latest Run: after three Runs, both session-row builders (`/mobile/bootstrap` for a paired phone, and over `host.sock` for the Mac app) mark every Run Session with `scheduleID`, the latest Run's `superseded: false` and the older two `true`, the user's rows with neither; Runs never push the user's stopped rows off either wire; `unpeel ls` (text and `--json`) leaves the superseded Runs out, `ls --all` lists them marked, a pinned older Run is listed, and `logs` / `schedules history` still reach one; the same after a Resume replaces the latest Run |
| `schedules_run_output` | A stopped Run Session keeps its output (ADR 0006): `unpeel logs` prints a script Run's line once the next Run stops it, after `unpeel stop`, and after a Host restart plus the exited-journal compaction pass; MCP `sessions read_output` reads it; a Session that is not a Run still stops with an empty `output.bin` |
| `schedules_edit` | every Trigger kind (hourly, daily, weekdays, weekly, once, cron) stored canonically with its next run published; invalid cron and impossible times refused at save time; `edit` changes each field and passes unknown ones through; `pause` stops firing, `resume` restarts the clock with no catch-up, then a weekly task fires on its own; a Once task that paused itself after its Run still edits (its stored time sent back included), saves a new past time while paused, and resumes only with a new time; an enabled task whose Once passed with no Host edits with its stored time sent back, but a new past time is refused; a Project with no folder is refused for a script preset and an Agent Preset; verbs refuse inside a Session |
| `schedules_mcp` | Scheduled Tasks over the MCP `workspace` tool from inside a Session: `list_schedules` shows definition, next run and last Run; `list_schedule_runs` is newest first with status, times, late and snippet, and honours `limit`; help documents both, the four writes and `schedules add` are refused for a Session that is not the Super Agent, and Create & remove cannot close a Run Session |
| `super_agent_schedules` | The Super Agent manages Scheduled Tasks over the MCP `workspace` tool against a live Host: create (preset label resolved, Trigger stored canonically, the answer carries the next run), Agent Preset instructions saved paused, the Host's refusal codes (`not_agent_preset`, `trigger_in_past`) save nothing, edit renames and moves the Trigger, pause/resume, Run now finishes, delete keeps the Run Session; the worker pings the state bus once it publishes a moved next run; any other Session is refused every write (MCP and CLI) while the Super Agent may use `unpeel schedules`; with the Host stopped a write changes nothing |
| `super_agent_run_reports` | A Scheduled Task's Run reports to the Super Agent unasked (ADR 0010): with the write policy at its default Ask and no Controller, the live Run Session of a task the Super Agent created on a fake Agent Preset and started with `run_schedule` `report`s to the Session marked Super Agent and is queued at once, from the Run Session, as a report; the user's own Session's report still waits on the approval prompt and reaches no Inbox |
| `super_agent_address` | A Run reports to the Super Agent by its address (#82): with the write policy at its default Ask and no Controller, a live Run of a task the user started on a fake Agent Preset `report`s to `session_id: "super_agent"`, over MCP and with `unpeel report --to super_agent`, and is queued at once in the Super Agent's Inbox, from the Run, as a report, the result naming the resolved id; `sessions list` marks only the Super Agent's row `super_agent: true`; the user's own Session's report to the address still waits on the approval prompt and reaches no Inbox; after the Super Agent is stopped and resumed under a new id the same call reaches the new one, and the list marks it; before any Super Agent is marked, and once it is removed, the call fails at once with "No Super Agent" |
| `super_agent_compaction` | The Host compacts a Super Agent Worker whose context is full (#64, ADR 0012): a fake `claude` Worker writes a Claude Code transcript under the private `$HOME/.claude/projects/`; when its task's turn ends at 41% of `claude-opus-5-5`'s 1M window the Host types `/compact` and Enter as keys, the Router gets the Worker's `finished` notice and a ride-along `compacted` notice naming the percent and the setting, and the compaction's own turn (working, then done) reaches neither the Router nor the user; a turn ending at 30%, or any turn with `supervisor_compact_percent` 0, is left alone; set to 50, a 55% turn is compacted again |
| `super_agent_compact_runtimes` | The Host compacts Codex and Codewhale Workers too (#68, ADR 0012): a fake `codex` launched by absolute path with `--no-daemon` writes a rollout under the private `$HOME/.codex/sessions/`; when its task's turn ends at 131,234 tokens of `gpt-5.6-sol`'s usable 258,400 the Host types `/compact` and Enter, and the Router gets the `finished` notice and a ride-along `compacted` notice at Codex's own 48% (the 12,000-token baseline left out); the compaction's own turn reaches nobody, and a turn at 105,000 (41% of the window, 38% past the baseline) is left alone. A fake `codewhale` fires the installed integration's hooks and saves its session under `$CODEWHALE_HOME/sessions/`; at 41% by Codewhale's own estimate the Host types `/compact`, and since its compaction reports no busy (one `turn_end` with `model_backed: false`) the Router hears nothing about it and the Host traces that it never started; a 30% turn is left alone. With `UNPEEL_CODEWHALE_TEST_BINARY` the Codewhale Worker is the real TUI against a local stub model at `supervisor_compact_percent` 25: its task's paste opens no message pager (#78), and the real compaction makes room with the same silence |
| `super_agent_startup_menu` | A Worker's first task never answers a startup menu (#55): a fake `codex` (screen tier only) opens on Codex's update picker, whose selected `›` row its screen rules read as the idle prompt and whose Enter means "Update now"; the Host sees the menu, so the task is held `attention` and nothing is typed; once the menu is answered with Skip the task is pasted and submitted at the composer; a second Worker answered with Update now exits to the shell before delivery, and its task stays queued (`no_agent_authority`), never pasted into the shell; since #69 a person's Skip (a write with no `origin`) also brings the task to the composer, while a person who then types into the composer without sending keeps it queued (`draft`) with nothing pasted on that line, and once the program clears that line by itself the task stays held until the Router's `send_keys` Enter, then lands; since #72 that person's composer comes up under output quoting a menu, and the draft typed there still holds the task `draft` once the quote goes |
| `super_agent_inbox_promotion` | A ride-along Inbox item is promoted by age (#83): with `UNPEEL_INBOX_RIDE_ALONG_PROMOTE_MS` at 6 s, a lone `progress` report to an idle 7501 agent is held `ride_along`, then pasted once it has waited 6 s and never before; on a busy agent it is held `ride_along` until promoted, then `busy` like a wake item; a Host restart publishes `busy` again, never `ride_along` (the age is the item's stored queue time), and the item goes out once the agent is idle |
| `health_check` | The Host's health check (#84), with `UNPEEL_HEALTH_SECONDS=1` (every 5 s, minutes as seconds) and a stand-in adapter: an occurrence skipped behind a Run now Run reaches the Super Agent's Inbox as a blocked Host report and the Mac as an alert naming the Run in its way; a task whose Run log is a directory misses its fire and alerts no sooner than 10 s after it was due; both alert once; with the app quit a failed Run's notice and a stopped Super Agent's alert are kept (its own being down never enters its Inbox, the failure's report still does) and shown in order, once, when an app connects; a kept alert whose problem cleared (the mark removed) just before an app connects is dropped, not shown; a Host restart alerts nothing again |
| `send_text_draft_guard` | An agent's send never lands on what the user is typing (#61, ADR 0011): through `unpeel mcp` `send_text`/`send_keys`, `unpeel send` and `unpeel keys` from inside a Session, an empty box takes the send; keys typed on the attach stream in the last 3 s refuse it as `typing` and a paused draft as `draft`, with nothing written; a select menu over the draft takes keys while the draft keeps refusing sends; once the user clears the box, and with a faint suggested reply on it, sends land again; since #65 also once the user erases a key typed before the line was redrawn after Enter, or a one-key prompt took the key and prompted again, while a draft the terminal wraps, one on a second row, one a TUI wraps, and one with output streaming above it (each output row in two writes) keep refusing; since #66 `sessions report` with no Host worker running lands in the empty box and is refused at once as `typing` or `draft`; since #72 output that quotes a menu above the line disarms no draft (typed before the quote or under it, every send and the report are refused), while a menu that hides the cursor under its footer still takes the user's Down and the agent's Enter |
| `session_identity_ancestry` | Only a Session's own processes speak for it (#70, #71, #74, ADRs 0013/0014): a fake `codex` with the installed integration gets its tools, a working `unpeel` CLI and its hooks, also from a child in a new POSIX session and after a Host restart; a gate the fake starts with `setsid` (the Python MCP SDK's shape) still gets the tools, but one started by a `setsid` helper that is still the fake's child (Codex's shared daemon while its starter lives, #74, ADR 0014) gets none; a detached runner that keeps the Session's whole exported environment fires the same hooks, gate and CLI call and moves no activity, writes no `last-hook-event.json`, gets no tools and is refused, with `hook-refused` in the trace |
| `omp_hook_identity` | The omp extension asks the installing `unpeel-host` before it speaks for a Session (#75, ADR 0013): a fake `omp` loads the installed extension with Bun, the way OMP does; its events move the Session from inside it, and a detached runner that keeps the Session's environment moves no activity, writes no `last-hook-event.json` and leaves `hook-refused` in the trace (SKIPPED without Bun) |
| `paste_enters` | A paste is followed by the Enters its runtime declares (#78): fakes named `codewhale`, `codex` and `claude`, launched by absolute path and recognized as those runtimes, get one Enter (Codewhale) or two (Codex, Claude Code) after both an agent's `send_text` and the Inbox's paste; with `UNPEEL_CODEWHALE_TEST_BINARY` the real Codewhale against a local stub model answers both and opens no message pager |
| `codex_mcp_tools` | A Codex Session gets the Unpeel tools only through its supported launch (#54): a fake `codex` starts the `[mcp_servers.unpeel]` server the installed integration registered, with Codex's cut-down MCP environment; run from the suggested preset (`--no-daemon`) the server is its child and the tools act as that Session; started detached like Codex's shared daemon, the gate lists no tools and refuses a call |
| `schedules_routes` | Scheduled Tasks over `/mobile`: bootstrap advertises `schedule.list` / `schedule.runs` and a moving `schedulesRevision`; the list shows next run and last Run, history is newest first; a recorded Run pings the state bus (`schedules`); both routes read the files on disk |
| `schedules_writes` | Scheduled Tasks written by a Controller over `/mobile` and the local socket: bootstrap advertises `schedule.create` / `.edit` / `.delete` / `.run` and flags Agent Presets; a created task is stored with its Trigger in stored form and fires at its time; edit, pause and resume round-trip; Run now is refused (409) while a Run is in progress; delete keeps the Run Session; a past Once on an enabled task, instructions on a script preset, a Project with no folder (script or Agent Preset, `project_missing`) or an unknown task are refused and nothing is saved; a paused task saves a past Once, edits with its stored Trigger sent back, and its resume is refused (`trigger_in_past`, "give it a new time") |
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
