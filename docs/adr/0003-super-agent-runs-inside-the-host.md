# The Super Agent runs inside the Host; its Router and Workers are ordinary Sessions

**Status:** accepted (2026-11-05)

## Context

The operator wants a Super Agent: one agent Session they talk to (the
Router) that starts Worker Sessions across the workspace's Projects,
hears back from them, and keeps them moving. The design comes from the
DeepSeek Harness article "Exploring Super-agent Design" and its MIT
prototype, which runs the Router, the Workers' queue and its watchdog in a
separate Node orchestrator daemon. Design detail:
`docs/superpowers/specs/2026-11-04-super-agent-design.md` (local only).

## Decision

The Router and its Workers are ordinary agent Sessions launched from plain
presets. Everything the Super Agent adds at the systems level lives in the
Host as fork-only code: the per-Session Inbox and its batched delivery,
Worker alerts, the watchdog, the Super Agent mark, Hand-over, and the
built-in Router instructions. Shared state goes through `app-state.json`
and per-Session files under the existing flock and state-bus rules, and the
Mac app reaches it only through additive Host verbs.

"The Router coordinates and does not do the work" is an instruction the
Router reads (the built-in `unpeel/router` skill), never a launch wrapper,
flag or provider configuration edit.

## Considered Options

- **A separate orchestrator daemon** (the prototype's shape). Rejected: it
  duplicates Host state (Sessions, activity, lineage), creates pressure for
  a second notification channel, and the prototype's runtime is Node,
  which Unpeel never ships.
- **Provider-native sub-agents** (for example Claude Code's own agents).
  Rejected: they tie the feature to one provider and their work never
  appears as Sessions in the sidebar, which is the review surface.

## Consequences

- Inbox delivery is only as good as the Host's busy/idle authority, so only
  Claude Code Sessions (OSC 7501) can be made a Super Agent. Workers may be
  any agent; for those the Host delivers on a best guess.
- The Super Agent's limits are cooperative, like the rest of the MCP layer.
  By the operator's choice it types into any Session without asking and
  answers its Workers' prompts itself; only app-wide Deny stops it.
- Upstream files (`mcp_host.rs`, `driver.rs`, `session_ops.rs`) carry
  one-line delegations into the new modules, keeping upstream merges small.
