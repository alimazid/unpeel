# An exported Session id is a claim; process ancestry decides

**Status:** accepted (2026-11-09)

## Context

Every process in a Session inherits `UNPEEL_SESSION_ID`, and both the MCP
gate and every `unpeel` CLI verb took that variable as the caller's identity
whenever it was set. Hook reporters posted to `/hook/<that id>` and wrote
the Session's `last-hook-event.json`. An environment travels further than a
process tree, though: Codex's shared app-server daemon keeps the environment
of the `codex` that started it and runs other clients' hooks and MCP servers
with it. Those hooks moved the starting Session's activity (#70), and a
server or CLI call that kept the variable got that Session's tools (#71).

The Host cannot sort this out on receipt. A hook POST carries only the id
in its URL, and the Host re-seeds activity from `last-hook-event.json` on
every scan, so a refused POST alone would still let the marker move the
Session.

## Decision

`session_identity` holds one rule for the gate, the CLI and the hook
reporters:

- **A claim needs ancestry.** An exported id is honored only when that
  Session's manifest pid, verified against its recorded start time, is the
  process itself or one of its ancestors (at most 12 hops). A claim that
  fails is refused, never redirected to some other ancestor.
- **No claim, nearest ancestor.** Launchers that strip the environment
  (cursor-agent, Codex, muse) keep today's fallback: the nearest verified
  Session ancestor.
- **Launching is undecided, not refused.** A Running manifest without a pid
  whose launching host is alive is undecided. The gate waits up to 5 s for
  it at startup and never caches that answer.
- **Hook reporters ask first.** Every owned shell reporter runs
  `unpeel-host __session_identity__` before it writes a marker or posts.
  Exit 3 (refused) stops the hook and traces `hook-refused`; anything else,
  including a missing or failing checker, keeps the old behavior. The
  reporter names the Host binary that installed it (`{{UNPEEL_HOST_BIN}}`,
  baked in at install), not the Session's exported `UNPEEL_HOST_BIN`: an
  older `unpeel-host` takes an unknown first argument for a launch file.
- **A test switch that cannot reach a real home.** `UNPEEL_TEST=1` plus
  `UNPEEL_TEST_TRUST_SESSION_ENV=1` trusts the claim, for PTY cases that act
  as a Session from outside it. It needs an explicit `UNPEEL_HOME` that is
  neither a real home nor inside one: `~/.unpeel` under `$HOME` and under
  the password-database home, and every workspace they register. Homes
  compare by path once resolved and by directory identity, so an APFS
  firmlink spelling (`/System/Volumes/Data/Users/…`) or a home not created
  yet behind a symlink is refused too. The Host strips the switch from every
  Session's shell, so a Session's own processes are always checked.

## Considered Options

- **Check in the Host on receipt.** Rejected: the POST carries no process
  to check, and the marker the reporter has already written re-seeds the
  Session on the next scan.
- **Require the caller's POSIX session to match the Session's.** Rejected:
  Claude Code starts every hook and every Bash-tool command with `setsid`,
  so its own processes would be cut off. A narrower form is #74.
- **A launcher file beside the reporters.** Rejected: one more installed
  file to keep in step with the Host; baking the path into the reporter at
  install needs nothing new, and the post-upgrade refresh rewrites it.

## Consequences

A process that keeps a Session's environment but has left its tree gets no
tools, makes no CLI call as that Session, and moves none of its activity.
`unpeel open` uses the same rule.

While the `codex` that started a shared daemon still runs, the daemon is
its descendant, so the daemon's hooks and servers still pass as that
Session. `--no-daemon` (#54) avoids the daemon. ADR 0014 closes the gap
for the MCP gate; the daemon's hooks and CLI calls still pass.
The omp extension posts from inside its process, without the reporter, and
skips the check (#75). Reporters installed by an older build carry no check
until the post-upgrade refresh rewrites them.
