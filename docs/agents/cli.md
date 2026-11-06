<!-- Split out of the repo-root AGENTS.md (2026-08-31). The root AGENTS.md holds the map, hard rules, and invariants; this file is the full detail for its topic. -->

## Scriptable CLI

`crates/unpeel-cli/src/cli.rs` is the one-shot command dispatcher for the
`unpeel` binary. It is a frontend over shared Host/session contracts, not a
second state implementation. `claim_workspace_flag` runs before dispatch, so
every one-shot verb automatically targets the selected `UNPEEL_HOME` when
prefixed with `unpeel --workspace NAME`.

One-shot writes must use the sanctioned shared-state primitives:

- `unpeel_core::app_state::edit` for `app-state.json`: exclusive flock, raw
  `serde_json::Value` read-modify-write, unknown-key preservation, atomic
  rename, and `state_bus::announce(Change::AppState)`;
- the matching `session_ops` helper for Session markers/order/lifecycle;
- `state_bus::flush()` before process exit. The main dispatcher already does
  this after every handled one-shot command; never bypass that exit path for a
  new mutating verb.

Never deserialize `app-state.json` into `AppState` and serialize it back from a
CLI mutation. That typed round trip would drop fields owned by a newer app.
Never recover from a present-but-corrupt file by seeding defaults. Missing is a
fresh workspace; unreadable or malformed is an error.

### Workspace settings

`crates/unpeel-cli/src/settings_cli.rs` owns this grammar:

```text
unpeel settings list [--json]
unpeel settings get <key> [--json]
unpeel settings set <key> <value> [--json]
```

It deliberately exposes an allowlist, not arbitrary JSON paths:

| CLI key | Stored JSON | Set values | Effective fallback |
| --- | --- | --- | --- |
| `experimental_features.sessions_mcp` | nested boolean | `true`, `false` | `true` |
| `experimental_features.browser_mcp` | nested boolean | `true`, `false` | `true` |
| `browser_default_access` | string | `on`, `ask`, `off` | absent `on`; malformed `off` |
| `mcp_nonchild_write_access` | string | `ask`, `allow`, `deny` | `ask` |
| `theme` | string | `system`, `light`, `dark` | `system` |

Browser access reads use `BrowserAccess::from_state_str` semantics and fail
closed on malformed/non-string state. A nested experimental edit creates the
object only when absent; it refuses to replace a present non-object and keeps
unknown sibling gates. Values are validated before acquiring the write path,
so an unknown key/value leaves the file byte-for-byte untouched.

Human `get` prints the normalized value. JSON `list` is a key/value object;
JSON `get` and `set` return `{"key": ..., "value": ...}`. These shapes and
the parsed `SettingsCommand` separation are the future seam for dispatching
the same grammar through `settings.workspace.set`; local disk semantics are
the current implementation. Do not invent a CLI-only remote settings
protocol.

`experimental_features.sessions_mcp` and `.browser_mcp` are launch gates.
Changing them affects Sessions started or restarted afterward, not the
capability set captured by a running Session. Keep that warning in `unpeel
settings --help` and the website CLI page.

### Preset organization

`unpeel presets` mutates the same raw `presets` array through
`app_state::edit`:

```text
unpeel presets star|unstar <label|id>
unpeel presets enable|disable <label|id>
unpeel presets reorder <label|id> <position>
```

Selectors resolve an exact id first, then one exact label; duplicate labels
are rejected instead of changing an arbitrary row. Reorder positions are
1-based at the shell boundary and become a zero-based final array slot
internally, matching the Host protocol's `sortOrder` semantics. Array order is
the display order and the first preset for a CLI is that CLI's default. Star
is the stored `quick_launch` flag; enable is the compatibility `enabled` flag.
Every mutation is idempotent and preserves unknown fields on the row, sibling
rows, and the document.

The current native preset product remains present-or-deleted and normalizes
stored global rows to enabled; headless/Host consumers still honor the
compatibility flag. Do not silently remove the flag or reinterpret disable as
delete. Native convergence, if chosen, is a separate product change.

### Scheduled Tasks

`crates/unpeel-cli/src/schedules_cli.rs` owns `unpeel schedules`:

```text
unpeel schedules [list] [--json]
unpeel schedules add <name> --project <id|name> --preset <id|label> <trigger>
                     [--instructions <text>] [--no-notify]
unpeel schedules edit <id|name> [--name …] [--project …] [--preset …] [<trigger>]
                      [--instructions <text>] [--notify|--no-notify]
unpeel schedules pause|resume|run|history|rm <id|name>

<trigger>: --hourly <minute> | --daily <HH:MM[:SS]> | --weekdays <HH:MM[:SS]>
         | --weekly <day> <HH:MM[:SS]> | --once <YYYY-MM-DDTHH:MM[:SS]>
         | --cron '<min> <hour> <day> <month> <weekday>'
```

`--instructions` is accepted only for an Agent Preset — a preset whose command
names a catalog runtime that shows a readiness signal at launch (a `[screen]`
idle prompt or its own program status; hooks alone never count, since they are
an optional integration and report nothing ready at launch;
`agent_readiness::is_agent_command`) — and capped
at 256 KiB; any other preset is refused with the reason. `edit` checks new
instructions against the preset the task will have, removes them with
`--instructions ''`, and refuses a new preset that cannot take the
instructions the task keeps.

`add`, `edit`, `pause`, `resume` and `rm` edit the raw `schedules` array
through `app_state::edit` (unknown entries and fields pass through; an edit
goes through `unpeel_core::schedules::apply_edit`); the workspace worker
re-reads it every rescan and fires due tasks itself
(`unpeel_serve::schedules`). Every Trigger is stored in its canonical form
(times without zero seconds, a weekday's full lowercase name, a cron
expression single-spaced) after `trigger::Trigger::check`, the save-time
check any writer must run: it refuses out-of-range values, a past Once, and
a cron expression that is not exactly 5 fields or never comes due. Pause is
`enabled: false`; Resume, and a new Trigger, stamp `clock_reset_at_ms`, and
the due rule counts only occurrences after it, so nothing missed while
paused runs. `run` (Run now) goes to the live worker over the owner-only
`/_unpeel/schedules` control path, which refuses while a Run is in
progress, so it needs a running Host. `list` and `history` read the
per-task clock and Run log under `<UNPEEL_HOME>/schedules/<id>/`
(`unpeel_core::schedule_store`); `list`'s next run is
`trigger::next_run`, the instant the Host publishes. Every verb but `list`
and `history` refuses inside a Session, the detection `unpeel send` uses.
`rm` deletes the task and its history; its Run Sessions stay.

Triggers read the local wall clock (`unpeel_serve::schedules::clock`):
`system_zone()` resolves the zone on every call (`TZ`, else the
`/etc/localtime` link), so travel takes effect on the next sweep. A time a
spring-forward change skips comes due when the change ends; a repeated
time fires once, on its first pass — for every kind, Hourly and cron
included. Occurrences are compared as local date-times, so after a
westward trip the same local time does not fire twice.

### Unpeel Link enrollment

`crates/unpeel-cli/src/link_cli.rs` owns `unpeel link` — the scripted
headless spelling of the activation the app's Settings ▸ Remote offers
(originally also offered by the now-removed interactive TUI's Settings ▸
Remote):

```text
unpeel link enroll <key> [--json]
unpeel link status [--json]
unpeel link deactivate
```

Hard rules:

- **One activation implementation.** The CLI composes the exact
  `unpeel_core::license` request/commit primitives the app's Settings ▸
  Remote uses (`request_activation` → `commit_activation` →
  `request_relay_entitlement_for_key` →
  `commit_relay_entitlement_for_activation`), so the locked durable
  suppression record, activation-pending intermediate state, and
  authoritative-rejection semantics are shared byte-for-byte. Never fork a
  second activation path here.
- **Never a client-side gate on anything local.** Enrollment only adds Link
  (off-LAN relay) authority; local/LAN behavior must not consult it.
- Exit codes are script vocabulary: `0` success (for `status`: usable Link
  authority), `1` definitive failure (invalid key, rejection, suppressed),
  `2` transient/retryable. An `enroll` that exits `2` after "activation
  committed" left the durable `activation_pending` state; a retry or a
  running `unpeel serve` finishes it.
- A running serve needs no restart: its driver's Link maintenance observes
  the fresh key/entitlement on its next tick.
- `status` is read-only — it must not mint a Host identity or touch any Link
  file. `enroll` binds to `relay_uplink::ensure_host_id()` like every other
  Link consumer.

Evidence: `tests/cases/link_enroll.py` (shared fixtures in
`tests/link_fixtures.py`, also used by `link_lifecycle.py`).

### Host service packaging (`unpeel serve install`)

`crates/unpeel-serve/src/service_install.rs` implements
`unpeel serve install|uninstall|status`, rendered from the verbatim-usable
templates in `packaging/service/` (launchd LaunchAgent + systemd `--user`
units; the templates document the exact anchor lines install rewrites).
Scope follows the serve rule: no `UNPEEL_HOME` → machine unit; a registered
workspace home (recovered by `workspaces::current_scope()` after
`--workspace` re-homed the process) → scoped `--workspace NAME serve` unit;
an unregistered home is refused. Constraints:

- **per-user only** (LaunchAgent / `systemctl --user`), never root — the
  service owns `~/.unpeel`, the Keychain, and the per-user machine lease.
  Docs must carry the macOS auto-login and Linux `loginctl enable-linger`
  notes.
- `uninstall` stops the managed service and removes only the unit file;
  workspace data and running Session PTYs are untouched.
- `launchctl`/`systemctl` are resolved via `PATH` and the unit directories
  derive from `HOME`/`XDG_CONFIG_HOME`, so tests drive real flows through
  shims (`tests/cases/serve_install.py`) and never register a real service.
  `UNPEEL_SERVICE_MANAGER=launchd|systemd` overrides platform detection for
  tests only.
- `status` reports the unit + service-manager view and the existing lease
  truth (`service::is_running` / `driver::is_running_at`), exit 0 only while
  the Host service is actually running.

### Browser engine (`unpeel browser install`)

`crates/unpeel-cli/src/browser_cli.rs` — the one Browser MCP verb; every
decision lives in `unpeel_core::browser_engine` so the CLI, the worker's
start-time install, and the MCP server can never disagree:

```text
unpeel browser install [--check] [--json]
```

Installs (or confirms) the pinned `agent-browser` under
`~/.unpeel/browser/bin` after sha256 verification against
`protocol/browser-engine-v1.json`; `--check` only reports and never
downloads. Exit codes: 0 engine ready · 1 download/hash/unsupported failure ·
3 (`--check`) missing or stale · 4 engine ready but no Chrome/Chromium on
this Host (the text names the binaries looked for; Unpeel never installs a
browser). `--json` prints `{state, version, path, error?, browser: {path |
null, error?}}`. Sample (macOS):

```text
engine:  agent-browser 0.34.0 — ready
path:    /Users/me/.unpeel/browser/bin/agent-browser
browser: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
```

### The CLI as an MCP peer (`unpeel mcp` and friends)

Everything the unified `unpeel` MCP server can do, the CLI can do, through
the same in-process dispatcher (`unpeel_core::mcp_host::call_tool`): the
same caller identity (`UNPEEL_SESSION_ID`, or process ancestry), the same
per-call grants from the Session manifest, and the same cooperative write
policy with its approval prompt. An agent that prefers shell verbs over an
MCP client loses nothing.

```text
unpeel mcp                                   # the tools
unpeel mcp <tool>                            # that tool's help (the MCP help text)
unpeel mcp <tool> <action> [key=value ...] [--json '{...}']
unpeel browser open <url> | snapshot | click <target> | fill <target> <text>
              | type <target> <text> | press <key> | get <what> [target]
              | screenshot [--full] [--annotate] | scroll <dir> | wait [ms=…|selector=…]
unpeel artifacts publish <image>             # artifacts add_to_gallery
unpeel current                               # sessions current: you + pane neighbors
unpeel report <summary> [--status update|done|blocked] [--details TEXT]
unpeel worktree create <name> [--branch B] [--base REF] [--project ID]
unpeel agents <action> [key=value ...]       # occupants, transcripts, wait
unpeel skills <action> [key=value ...]
unpeel apps describe|search|context [key=value ...]
```

`key=value` values that parse as JSON (`true`, `42`, `["down","enter"]`,
`"quoted"`) are passed as JSON; anything else is a string. Exit 1 prints the
tool's own error text, exactly what an MCP client would see. Outside a hosted
Session the caller is unknown and most actions refuse, like the server.

**`unpeel send` / `unpeel keys` follow the write policy.** From a terminal
outside Unpeel they write straight to the Session socket (the operator is
the user). From inside a hosted Session — an agent's subprocess — they are
the MCP `send_text` / `send_keys` actions: the first write to another
Session blocks on the user's approval (desktop or phone), an approved pair is
remembered per the app-wide policy, a denial writes nothing, and a Session
can never write into itself. Inside a Session `keys` takes key names one per
word (`down enter`, `ctrl+c`); outside it keeps its raw escape sequence.
PTY proof: `cli_write_policy`.

### Agent integrations (`unpeel integrations`)

A preset launches its command in your login shell exactly as typed. What
makes a recognized agent report busy/idle/attention and reach the unified
`unpeel` MCP server is its **integration**: lifecycle hooks plus the MCP
shim registered in that CLI's own global configuration. It is installed
once per Host, explicitly, and never as a side effect of a launch:

```text
unpeel integrations [list] [--json]
unpeel integrations install <runtime> [--project DIR] [--json]
unpeel integrations install --all [--json]      # every installable runtime whose CLI is on PATH
```

`<runtime>` is the short name (`claude`, `codex`, `gemini`, …), the catalog
id, or the command. `list` shows `installed`, `installed (refreshing)` (the
Host will rewrite it for this build), `not installed`, or `detection only`
(Pi: nothing to install). Amp and GitHub Copilot read hooks per project;
`--project DIR` writes that project's file. A marker under
`~/.unpeel/integrations/` records the installing build; the workspace
worker re-runs installed integrations' installers after an upgrade so hook
scripts and `~/.unpeel/bin/unpeel-mcp` keep pointing at the running binary.
The integration is per user, like the provider configs it edits: markers,
hook scripts, and the shim live under the **machine home**
(`app_paths::machine_home()` — the real `~/.unpeel` whenever the active
`UNPEEL_HOME` is a workspace listed in the machine's registry
`~/.unpeel/profiles.json`; an unregistered `UNPEEL_HOME`, i.e. a blank
instance or a test, is its own machine home), so installing from any local
workspace installs for all of them and every workspace reports the same
status, with no environment plumbing. A remote Host has its own machine
home.
The Host verb is `integrations.install` (`POST /mobile/integrations/install`,
`{"runtimeID": …}`), and bootstrap's `availableAgents` rows carry
`integrationInstallable`/`integrationInstalled`, plus the package's `integrationSummary` / `integrationManualCommand` and the Host's `mcpShimPath`, for Settings ▸ Agents.

### Unpeel Apps (`unpeel apps`)

Official App discovery and installation are Host-owned, so the same commands
work in the default workspace, an isolated local workspace, and a remote
Linux/SSH Host:

```text
unpeel apps list [--json]
unpeel apps install <app-id> [--check] [--yes] [--json]
unpeel apps update [<app-id>] [--check] [--yes] [--json]   # reinstall Apps behind the registry version (--check: exit 3 = available)
unpeel apps link <app-id> <executable>       # dev mode: symlink a local build into the slot
unpeel apps unlink <app-id>                  # remove only such a link
unpeel open <path> [--with <app-id>] [--media-type <type>] [--json]
unpeel open git:working-tree [--with diffs] [--json]
unpeel open <resource-id> --kind <resource-kind> [--with <app-id>] [--json]
unpeel settings openers set <file:media-type|resource:kind> <editor|system|app:id>
```

The embedded `protocol/app-registry.json` is the allowlist. Managed copies
land under `~/.unpeel/apps/bin`; installation selects the Host platform,
requires the release archive's `.sha256` sidecar, extracts only the declared
binary, and atomically replaces it under a flock. `--check` reports exit 3
when the App is absent and never downloads. Bootstrap publishes the catalog,
installed subset, and typed opener map to capability-aware Controllers.
Direct installs prompt on an interactive terminal. Noninteractive automation
must pass `--yes`; without it the CLI fails closed. `--check` never prompts or
downloads.

`unpeel open` is the user-facing dispatcher. It normalizes the argument into
a typed resource, resolves a workspace preference or the registry's
`default_for`, offers to install a missing official App only on an interactive
terminal, and passes the resource as one shell-safe argument to the exact
resolved executable. Inside an Unpeel Session it uses the shared `app_open`
operation to create/reuse a companion pane. Outside a Session it launches the
same command as a new hosted App Session. Noninteractive calls never install
implicitly; the error names the exact `unpeel apps install` command.

Opener preferences and managed binaries are per workspace Host. This is what
makes the same flow work on isolated local workspaces and SSH/Linux Hosts: the
registry, file/resource, installation, and App process all live on the Host.
The Controller never copies or executes a remote App locally.

### Desktop-session service (`unpeel serve install --graphical`)

Linux only. Writes the `graphical-session.target`-bound variant of the
user unit (`packaging/service/unpeel-serve-graphical.service`) so the Host
runs inside the desktop session used by graphical tools; launchd refuses the
flag (the app owns the desktop daemon on macOS). `uninstall` and `status`
take no flag; `status` additionally prints `unit variant:`,
`graphical-session.target:` (`is-active`), and `desktop session:` — the
display plus session bus visible to the calling shell, or the missing
piece. Detail: `docs/agents/serve.md`.

### Gates

At minimum, CLI settings/preset changes run:

```sh
(cd crates && cargo test -p unpeel-cli settings_cli::tests)
(cd crates && cargo test -p unpeel-cli --test settings_command)
(cd crates && cargo test -p unpeel-cli)
```

The real-process case proves JSON output, validation-before-write, nested and
top-level unknown-field preservation, preset flags/order, and that the state
bus notification is delivered before the process exits. Changes that touch
workspace selection must also run the full `crates/unpeel-cli/tests/run.sh`
matrix because every command composes with `--workspace`.
