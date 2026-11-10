# The MCP gate refuses an ancestry match across a setsid helper

**Status:** accepted (2026-11-10)

## Context

ADR 0013 lets a process speak for a Session only when that Session's
start-time-verified pid is one of its ancestors. One gap was left open.
Codex's shared app-server daemon is spawned once with `setsid` and no
double fork (rust-v0.167.0, `app-server-daemon/src/backend/pid_start.rs`).
While the `codex` that started it is alive, the daemon is still that
`codex`'s child, inside Session A. Every MCP server the daemon starts, for
any client, therefore has Session A on its ancestry and gets A's tools.

A daemon leads a POSIX session of its own, and the servers it starts
inherit it. Codex starts them with a new process group only
(`ProcessMode::NewGroup`). The rule ADR 0013 rejected was "the caller must
be in the Session shell's POSIX session". It would have cut off Claude
Code's hooks and Bash-tool commands, which run under `setsid`. For the MCP
gate alone it fails too. Two runtimes start the gate itself with `setsid`,
straight from the agent:

- Kimi: fastmcp 3.2.4 → `mcp>=1.24`, whose `stdio_client` spawns with
  `start_new_session=True`.
- OMP on Linux: its stdio transport spawns `detached` everywhere except
  macOS.

Checked on 2026-11-10:

| Runtime | How it starts the gate | Source |
| --- | --- | --- |
| Claude Code | shell's POSIX session | live, every gate on one Mac |
| Codex `--no-daemon` | embedded app-server, new process group | rust-v0.167.0 source |
| Codewhale 0.10.2 | new process group | real binary, probe server, private home |
| Kimi 1.52 | gate leads its own POSIX session | fastmcp + mcp SDK source |
| OMP 18.18.6 | macOS: shell's session; Linux: gate leads its own | published package source |
| Cline 3.0.74 | process keeps the session, but sessions run in a shared hub daemon once one is running (#79) | published bundle |
| Kiro | predecessor `aws/amazon-q-developer-cli` uses `process_group(0)` | predecessor source only |
| Cursor Agent, Muse Code, Antigravity, fx | not checked (closed binaries) | — |

Gemini registers no Unpeel MCP server.

## Decision

The MCP gate (`unpeel-host __mcp_gate__`, `session_identity::current_for_gate`)
accepts an ancestry match only when every process from the gate up to the
Session's pid shares that pid's POSIX session. The gate itself may lead its
own. A sid that cannot be read refuses, and so does a walk that never
reaches the Session's pid. Ambiguous ownership fails closed. A refusal
traces `mcp gate refused session=<id> reason=other-posix-session`, and the
gate then serves no tools.

The `unpeel` CLI, `unpeel open` and the hook reporters keep ADR 0013's
ancestry rule alone, because Claude Code starts each of them under `setsid`.
The test switch that trusts an exported id skips this check too.

## Considered Options

- **The gate's sid must equal the Session shell's.** Rejected: it cuts off
  Kimi on every platform and OMP on Linux.
- **The gate's sid equals the shell's or its own pid.** Rejected: weaker
  for no gain. It checks only the gate, so a daemon that also starts each
  server with `setsid` passes.
- **Apply it to the CLI and hook reporters too.** Rejected for the reason in
  ADR 0013: Claude Code runs every hook and Bash-tool command with `setsid`.

## Consequences

A shared daemon's MCP servers get no Session's tools, even while the agent
that started the daemon is alive. The daemon's hooks and CLI calls still
pass as that Session until it exits. Codex's `--no-daemon` (#54) stays the
way to keep Codex's tools.

A runtime that starts its MCP servers from any `setsid` helper gets no
Unpeel tools: a per-Session backend as well as a shared daemon. The process
tree cannot tell the two apart. The failure is visible as missing tools,
never a wrong Session. The runtimes not checked above carry that risk
(`runtimes/README.md`), and Cline's hub is one such helper (#79).
