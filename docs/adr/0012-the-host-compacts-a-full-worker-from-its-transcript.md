# The Host compacts a full Worker from its transcript

**Status:** accepted (2026-11-09)

## Context

The user asked for Workers to be compacted when they reach 40% of their
context, "deterministic", as an Unpeel feature (#64). Until now the
Super Agent read each Worker's status line and sent `/compact` with
`send_keys` itself, and `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in the Worker
presets' settings file made Claude Code compact itself. That variable is an
internal Claude Code name (`testPctOverride`) that a release could drop,
it reaches only processes started after it was set, and Unpeel can neither
show nor configure it. Large contexts cost tokens on every turn, and a
compaction run after the prompt cache expired re-reads the whole context
uncached: about $7.70 across two Workers on 2026-11-08.

The Host had no context figure. Claude Code computes its own (status line
`context_window.used_percentage`) as the latest request's input, cache
writes and cache reads over the model's window, and passes it only to the
status line command, which is the user's. Each assistant line in the
transcript carries those three counts. The window is not in the
transcript: Claude Code takes it from its model catalog cache
(`~/.claude/cache/model-catalog/`), another internal file. A typed
`/compact` fires no prompt-submit or Stop hook, but it reports 7501
working, then done, so the Host saw an ordinary turn. Without help that
turn would reach the Router as a Worker "finished" notice (or a
`went_quiet` alarm) carrying the previous reply.

## Decision

The Host compacts a running Router's Worker when a turn of the Worker ends
with its context at or over `supervisor_compact_percent` (default 40,
`0` = off, nothing between 1 and 24, since the startup context comes back
after a compaction and a low value would compact every turn). Scheduled
Runs are never compacted.

- **The figure** is Claude Code's own, read from the Worker's transcript:
  the last main-chain reply's input, cache writes and cache reads, or a
  later `compact_boundary`'s `postTokens`. The reader is provider code, a
  `context_usage` callback on the runtime's transcript adapter.
- **The window** comes from the runtime package (`[context] windows`, by
  model-id prefix, taken from Claude Code's catalog on 2026-11-09), and so
  does the command (`compact_command = "/compact"`). A model none of them
  names is never compacted, and the Router hears that once per model.
  Guessing would be worse than doing nothing: a 200K guess for a 1M model
  fires at ~80K, close to the post-compaction baseline, and compacts every
  turn.
- **When:** at the Worker's Finished edge, once per turn, within 5 minutes
  of its end while the cache is warm. A write the core refuses (the user
  typing, a draft) is tried again every 2 s inside that window, re-checking
  every precondition each step; the first that fails, or a Router write,
  Inbox paste or program turn since the turn ended, gives the turn up. A
  turn end missed for any reason waits for the next one. After a compaction starts
  it does not compact again until a reading is under the threshold.
- **How:** the command, then Enter, as program writes under the PTY core's
  typing and draft guards (ADR 0011), off the tick thread, and only into an
  Idle Worker with no select menu (it would take the keys), a PTY core that
  has the draft guard, no Inbox items waiting, no Router write or Inbox
  paste in the last 5 s, and "Writing to other sessions" not set to Deny.
- **Notices:** the Router gets one ride-along `compacted` notice once the
  compaction goes busy; one that never starts tells nobody. The
  compaction's own turn raises nothing for the Router or the user, unless
  someone wrote to the Worker after the command, when that turn may also
  answer them.

## Considered Options

- **Keep `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`.** It stays where it is for
  now, but it is internal, Claude-wide and invisible to Unpeel. It also
  compacts mid-turn, which the Host avoids.
- **Read Claude Code's model catalog cache for the window.** Rejected:
  it is an internal cache whose format can change without notice. The
  runtime package is where Unpeel already records version-dependent
  provider behavior.
- **A threshold in tokens.** Rejected: the user thinks in the status
  line's percent, and the same token count means different things on 200K
  and 1M windows.
- **Wrap the user's status line command to capture its JSON.** Rejected:
  launches are plain and integrations are explicit; the status line
  belongs to the user.
- **Compact on a timer or whenever the Worker is idle.** Rejected: a
  Worker idle past the cache window costs the most to compact, and one
  about to be stopped needs no compaction.

## Consequences

Claude, Codex and Codewhale Workers are compacted (Codex and Codewhale
since #68, each with its own `context_usage` reader and windows); other
runtimes are not. Scheduled Runs, the Router and the user's own Sessions
are left to the agent itself. Codex's figure leaves out its 12,000-token
baseline, as its footer does (`[context] baseline_tokens`), and a
`model_context_window` set in Codex's config is not followed. Codewhale's
figure is its own local estimate of the saved session. Its footer shows
the larger of that and the last billed prompt, which only its memory
holds, so a Codewhale Worker can be compacted somewhat after its footer
passes the setting; Codewhale's own auto-compaction at 80% is the
backstop. A Codewhale compaction never reports busy, so the Host never
sees it start: the Router gets no `compacted` notice and the Worker is not
disarmed (a real Codewhale 0.10.2 run in a Host confirmed it on
2026-11-09). A new Claude model family
needs a line in `runtimes/claude-code/runtime.toml` before its Workers are
compacted, and until then the Router is told. A Worker whose transcript the
Host cannot find (no hooks reporting its path, and a cwd Claude Code
spells differently) is never compacted. When the Router writes to a Worker
during its compaction, the compaction's finish can reach the Router as a
"finished" notice carrying the previous reply. When the user types between
the command and Enter, the command stays on their input line unsubmitted.
A compaction that finishes while no Router runs reaches the user as any
Worker's finish does.
