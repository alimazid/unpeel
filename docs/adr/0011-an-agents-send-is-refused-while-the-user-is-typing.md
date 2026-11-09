# An agent's send is refused while the user is typing

**Status:** accepted (2026-11-09)

## Context

MCP `send_text` and `send_keys`, and `unpeel send` / `unpeel keys` from
inside a Session, wrote into the target with no guard (#61). A message could
land in a half-typed prompt and submit it with the user's words. ADR 0008's
`unless_typed_since` protected only the Inbox, which first waits for 3 s of
quiet and finds the line equal to the agent's known-empty prompt. A send has
neither: it is one synchronous call, and nothing it can read records when
the target's turn began or what its empty prompt looks like. Reading the
screen first leaves a gap between the look and the write.

## Decision

The PTY core decides, under its runtime lock, so nothing slips in between a
look and the write:

- **Typing.** Each write of a send carries `unless_typed_since` = now − 3 s,
  the Inbox's quiet window. The core sees a key at once; the manifest's
  `last_input_at` can lag it by ~2.5 s.
- **Draft.** At the first key the user has not sent, the core keeps the
  input line as it was: the cursor's row without suggested input. Plain
  Enter sends it and clears that. A `Write` with the additive
  `unless_draft` is refused with the wire code `draft` while the line
  differs from the kept one. Finding it equal ends the draft, so text a
  program leaves there later is never taken for the user's. A select menu
  takes the keys, so it neither starts nor refuses a draft, and the one
  under it survives. A new program in the foreground drops the draft.

The send is **refused, not held**. The result starts with a stable phrase:
`Not sent (typing)` or `Not sent (draft)` (nothing written, with what to do
next), or `Not submitted (typing)` when a key lands after the paste, which
then waits on the line unsubmitted. `send_keys` stops at the refused key and
says how many went in.

## Considered Options

- **Hold the send and deliver it when the box is clear.** Rejected: the
  call is synchronous and would block on a person, possibly for hours, past
  the ~2 minute approval wait callers already allow for. Queuing it in the
  Inbox needs what the drain needs (a Host worker, an agent's idle report,
  bracketed paste), which a shell or a menu answer lacks, and the caller
  would not learn whether it landed.
- **Guard in the MCP server with the Inbox's rule.** Rejected: it needs the
  turn's start and a known-empty prompt kept between calls, and `unpeel
  send` is a new process per call. Its read of the screen is also the gap
  #61 names.
- **Refuse only on recent typing.** Rejected: a paused draft is the case
  the issue reports.

## Consequences

The guard holds only on a PTY core of this build, which says so in the
manifest (`draft_guard`). A Session started on an older core writes as
before until it is resumed, and the result then ends `(unguarded: …)` so
the caller knows to read the screen first.

A false draft is possible and lasts until the line returns or the user
presses Enter: a key that a program takes without Enter (a one-key `y/n`
prompt), or a key typed right after Enter, before the program has redrawn
the line, so the kept line is the old one. The refusal says to ask the user
to press Enter when the line shows nothing of theirs. Menu-like text
anywhere on screen reads as a menu, so a draft under it does not refuse.

The Inbox keeps ADR 0008's guard; `report` without a Host worker still
pastes unguarded.
