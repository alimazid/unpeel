# Built-in agent runtimes

Each directory in this folder is one built-in agent runtime package. The Rust
build discovers `runtime.toml` files automatically, validates them, and emits
the compiled registry. Adding a package must not require adding its name to a
central provider list.

This is a source contribution boundary: a new or changed runtime ships in a
new Unpeel build. Downloadable third-party adapters are not supported yet.

## Package layout

```text
runtimes/<slug>/
├── runtime.toml          # identity, detection, lifecycle policy, [screen] rules
├── adapter/
│   ├── setup.rs          # optional: `pub fn install()` — hooks + MCP shim registration
│   ├── resume.rs         # optional: `ADAPTER` — resume/fresh recipes from hook-captured ids
│   ├── transcript.rs     # optional: transcript discovery and parsing
│   └── tests.rs          # optional: the package's own conformance tests
├── assets/
│   ├── icon.svg          # optional client-embedded runtime mark
│   └── hooks/            # optional hook scripts and plugins
└── fixtures/             # add provider-owned fixtures as behavior grows
```

There is no hand-written module file: `unpeel-core/build.rs` generates the
package module from what exists on disk (`setup::install`, `resume::ADAPTER`,
`tests.rs`) plus the descriptor's flags. A runtime with only `runtime.toml`
is already a complete package — detection gives it identity and tint, and
`[screen]` rules give it busy/idle without any Rust.

**Launching is provider-neutral.** A preset runs its command in the user's
login shell exactly as typed, with only Unpeel's generic session environment
exported. An adapter never rewrites the command, wraps the executable, mints
a conversation id, or edits provider configuration at launch. Everything
provider-specific is the runtime's **integration** — the `setup.rs`
installer that registers lifecycle hooks and the Unpeel MCP shim
(`integrations::install::write_mcp_shim`) in the provider's own global
configuration — which the user installs explicitly
(`unpeel integrations install <runtime>`, or Install integration on Settings ▸ Agents) and
the Host keeps current after upgrades.

Provider-neutral enforcement remains in `unpeel-core`: PTY ownership,
PID/start-time checks, hook ingress and generation ordering, locked/atomic
file writes, MCP authorization, transcript path validation and read bounds,
activity arbitration, notifications, and the Host/Controller protocol.
Runtime adapters return plans or normalized data; they do not weaken those
boundaries.

## Descriptor

`runtime.toml` is the source of truth for metadata and declared capabilities.
The schema is strict: unknown fields, duplicate identities or aliases, an
invalid directory/slug pair, and inconsistent lifecycle/capability claims
fail the build.

Important fields:

- `id`: stable reverse-DNS identity. Never derive this from a display label.
- `slug`: source package directory name.
- `legacy_slug`: compatibility identity used by existing manifests and wire
  fields. Keep it stable during the catalog migration.
- `adapter`: optional reviewed compiled adapter (`builtin:<legacy_slug>`).
- `legacy_order`: compatibility ordering for built-ins and seeded presets.
- `platforms`: Host targets where the runtime can be launched. Descriptors and
  icons remain available to every Controller for cross-Host presentation, but
  adapter code, local setup scans, and seeded presets are compiled/exposed
  only on the declared targets.
- `display`, `install`, and `suggested_presets`: generated into client-safe
  metadata so Mac, iOS, and headless serve do not grow new provider tables. `display.kind`
  is the presentation family (`agent`, `app`, `editor`, `terminal`; default
  `agent`) so a markdown-editor or Unpeel App CLI gets the right generic logo
  without a client special case. A custom `display.icon_asset` must be a
  package-local SVG below `assets/` and declare `icon_source` plus
  `icon_license`. Icons default to template rendering; set
  `icon_template = false` only when authored fills must be preserved.
  `display.window_padding_x` is the Ghostty side inset in points (0–48,
  default 0 = edge-to-edge). Agent runtimes currently use 8 by convention;
  full-bleed TUIs such as Grok and OpenCode omit it.
- `detection`: conservative command/process aliases, package path signatures,
  and optional home-relative executable search paths.
- `install.command`: the fresh-install recipe. An optional `install.update_command`
  overrides it for an existing installation. The Host selects the recipe using
  its executable inventory and publishes it as `availableAgents[].installCommand`.
  Update recipes remain Host-owned; the generated client catalog contains only
  the fresh-install command. Use a shell maintenance invocation (for example,
  `command agent update`) so an updater does not start a managed agent session.
- `environment.strip_inherited`: provider identity/session variables that a
  nested Unpeel Host must remove before opening a new terminal.
- `updates`: optional read-only release lookup (`version_args`, `latest_url`,
  optional JSON pointer or version delimiters). Checks run lazily on the Host
  when Agents or Plugins is visible, never during bootstrap. Unknown versions and
  failed lookups do not claim an update. These recipes are not generated into
  the client catalog.
- `usage.stores`: optional bounded, home-relative session-file patterns used
  only to rank an existing user's agents during first-run preset seeding.
- `lifecycle`: source, authority, fallback, reliability claims, and the
  controller-side output semantics used to restore hook state
  (`anchor_start_event_to_output` and `attention_clears_on_output`). These
  flags default to `true`; declare only runtime-specific exceptions.
  `escape_cancels_turn = true` opts the runtime into the Host's Escape
  cancellation fence (only where Escape is a verified interrupt that fires
  no Stop hook). The legacy `distrust_stops_while_output_grows` field is
  accepted but ignored: output never reopens a settled turn.
  `authority = "none"` must use `fallback = "none"`: raw output changes
  remain telemetry and never start animated Busy. `fallback = "screen"`
  requires a `[screen]` section — `working` substrings the agent shows near
  the bottom of its screen while a turn runs (a spinner line, "esc to
  interrupt") and `idle_prompt` prefixes of its input prompt line — which
  the Host applies while the Session has no hook latch (integration not
  installed); hooks always win once they latch, and screen verdicts never
  send completion notifications.
- `approvals`: optional `bypass_flags`, the arguments that turn off the
  runtime's approval prompts (`--yolo`; an option and its value as two
  words, `--permission-mode bypassPermissions`; an `--option=value`
  spelling as its own entry). The Host publishes `bypassesApprovals` on
  every preset row from them, so a Controller warns that a Scheduled Task's
  Runs ask no one, without parsing a command itself.
- `integration`: user-facing copy for Settings ▸ Agents ▸ Install integration
  agents — `summary` says which of the provider's own files the installer
  edits; optional `manual_command` is the provider's documented way to
  register the MCP shim by hand (`{shim}` is replaced with its path);
  optional `legacy_evidence` lists files under the Unpeel home (the hook
  script, a plugin marker) that only a pre-0.7 launch-time install wrote, so
  the Host can adopt that install as an integration on upgrade.
- `capabilities`: only behavior actually implemented by the adapter.

Current capabilities are `lifecycle_hooks`, `resume`, `restart_agent`,
`mcp_sessions`, `mcp_browser`, `mcp_computer`, `transcript`, and
`notify_when_done`.

`restart_agent` is the v1 source-schema spelling retained for built-in package
compatibility. It enables the user-facing **Resume Agent** recipe only after a
managed runtime returns to its owned shell; it never authorizes interrupting an
active runtime.

## Adding a runtime

The recipe is five files, each optional after the first:

1. `runtime.toml` — id, slug, label, detection aliases, lifecycle policy. Add
   `[screen]` rules (`lifecycle.fallback = "screen"`) if the agent draws a
   recognizable status line and prompt; that alone gives busy/idle. Copy the
   closest existing descriptor and keep aliases exact; add false-positive
   tests for generic executable names.
2. `adapter/setup.rs` — `pub fn install() -> Result<(), String>`: write the
   hook script under `~/.unpeel/hooks/`, register it in the provider's own
   global hook config, and register the MCP shim
   (`crate::integrations::install::write_mcp_shim()`) through the
   provider's persistent MCP mechanism. Use the shared primitives in
   `hook_assets` (`read_mergeable_json_object`, `write_file_atomic`,
   `write_executable_script`). Declare `lifecycle_hooks` / `mcp_*`
   capabilities only when this file provides them.
3. `adapter/resume.rs` — `pub(super) const ADAPTER: ResumeAdapter`: how a
   hook-captured conversation id becomes a resume command, and the
   documented continue-last fallback.
4. `adapter/transcript.rs` — normalized records from provider storage.
5. `adapter/tests.rs` — the package's conformance tests; shared fixtures come
   from `crate::hook_assets::test_support::*`.

A runtime with no safe hook or resume primitive omits that capability
instead of emulating a stronger integration. Research the provider before
writing code: executable signatures, official install path, lifecycle
events, conversation identity, exact resume semantics, MCP configuration,
transcript roots and format, and version-dependent behavior.

### Package rules

- Put provider-owned scripts, plugins, and optional `icon.svg` in `assets/`.
  Load setup assets with `include_str!`; the catalog generator embeds the
  declared icon for shared clients. Record an upstream URL or explicit
  `internal:` generation/migration marker and its license/brand status.
  Installers must merge user configuration idempotently, preserve unrelated
  entries, and remove only Unpeel-owned entries.
- Every owned lifecycle reporter must send and durably seed numeric
  `unpeel_runtime_generation`. It must no-op outside an Unpeel Session,
  report to the direct hook port and current port registry, and forward only
  the provider conversation ID/path fields the Host knows how to validate.
  The reporter reads its Session from the generic hosted environment (or,
  for launchers that scrub it, from its parent process); it never depends on
  a launch-time wrapper or provider variable.
  Finish bounded delivery before returning; provider-level asynchronous
  hooks can reorder opening and closing events even when the script waits
  for its own HTTP requests. An adapter may opt into
  `Integration::with_escape_cancellation()` only when Escape is a verified
  turn interrupt. The Host owns input parsing, durable cancellation fences,
  and rearming on the next submitted opening hook; see
  [Session activity](../docs/agents/clients/session-activity.md#escape-cancellation-and-hook-delivery).
- MCP registration is part of the installer, uses the provider's persistent
  additive mechanism, and always points at the MCP shim; the shim's gate
  fail-closes outside a granted hosted Session. Registration evidence on a
  Session means "the integration is installed and the launch granted the
  domain" — a grant alone is not proof of a configured client.
- Resume/restart code must preserve the original semantic command, support
  only verified identity modes (hook-captured exact ID, documented
  continue-last, or picker), and never turn passive process observation
  into a launch recipe. Nothing mints an id or pins storage at launch.
- Transcript code returns normalized records and provider path claims. Core
  still canonicalizes roots, rejects traversal/symlink escape, and applies
  read/search limits.
- Regenerate client metadata with `bun run generate:runtimes`, then run
  `bun run validate:runtimes` to validate the schema/generated registry and
  prove there is no client-catalog drift.

## Integration levels

A runtime does not need Claude-level capabilities to be valid:

- A generic preset runs any command in a durable terminal.
- Detection adds an active logo/tint while a matching foreground process is
  present. Detection alone is presentation-only.
- An installed integration adds lifecycle authority (busy/idle/attention,
  notify-when-done), hook-captured conversation identity (precise resume,
  archive), and the MCP registration. It applies to every way the agent
  starts — a preset, a hand-typed command in a blank terminal, an agent
  started from a script — because it lives in the provider's own global
  configuration, not in a launch.
- Resume Agent still requires the Session's launch command to name the
  runtime: a hand-typed agent in a blank terminal keeps the blank launch as
  its stable binding.

Capability honesty is more important than feature parity: a runtime with no
safe hook or MCP mechanism (Pi) is detection-only and refuses installation
rather than emulating a stronger integration.

## Verification

At minimum, add package-local unit fixtures and run:

```sh
bun run validate:runtimes
cargo test -p unpeel-core
cargo test -p unpeel-host
cargo test -p unpeel-cli
# The Apple clients (apps/) run their own suites against the catalog
# regenerated with --out from this checkout
```

Deep integrations also need a real hosted-PTY proof covering launch, lifecycle
busy/stop, captured conversation identity, same-PTY Resume Agent after the
managed runtime returns to its shell, stale hook generation rejection, and
transcript resolution. Keep the blank-terminal
negative proof: detection may change presentation but must not promote the
saved blank launch.
