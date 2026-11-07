# A stopped Run Session keeps its output; other Sessions still drop it

**Status:** accepted (2026-11-06)

## Context

Stopping a Session empties its `output.bin` (`session_ops::drop_scrollback`):
Resume starts a fresh terminal and never replays the journal, and kept
journals once grew `app-sessions` into gigabytes. A Scheduled Task's next Run
stops the task's previous idle Run Session when it comes up ("the latest Run
replaces the previous one"), so every daily Run used to erase what the one
before it printed. An agent Run is still readable through the agent's own
transcript; a script Run has nothing else, and for a scheduled script that
output is usually the whole point. Triage of #32.

## Decision

Stop keeps `output.bin` for a Session that is a Run of a Scheduled Task,
agent and script Runs alike, whoever or whatever stops it. Every other
Session keeps today's drop-on-Stop. The kept output stays readable through
`unpeel logs <id>` and the MCP `sessions read_output` action, and the Mac
app replays it read-only in the stopped Run's row (#36). It goes when the
Session goes: retention keeps five stopped Run Sessions per task, and the
journal's own cap (about 64 MiB, hole-punched in 8 MiB steps) still applies.

## Considered Options

- **Keep the output of every stopped Session.** Rejected: it reverses the
  disk fix for every Session, and only Runs lose output nobody chose to drop.
- **Copy a Run's output aside at stop.** Rejected: a second store and a
  second retention rule for bytes `output.bin` already holds.

## Consequences

A task's stopped Runs can hold up to about 5 × 72 MiB on disk in the worst
case; in practice a Run prints far less. Resume of a stopped Run still
starts a fresh terminal: the kept output is for reading, not for replaying
into the resumed program.
