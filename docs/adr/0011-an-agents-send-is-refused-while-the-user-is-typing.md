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
- **What the keys left (#65).** While only text and Backspace typed the
  draft, the core also keeps that text: text adds to it, Backspace takes
  off its last character. Any other key (arrows, Tab, Escape, control
  keys, a paste, a Backspace into what was there before) and a mouse click,
  which can move the cursor inside the draft, leave only the kept line to
  end it. Erasing every key ends the draft, so a line kept
  from before a redraw no longer matters. A program took the keys and
  moved on when the cursor has left the row they were typed on, **and**
  what it follows is none of the characters typed and no mask (`*`, `•`,
  `●`, `·`, `▪`, `■`), **and** the row above shows none of them; short of all three
  it is still a draft (one that wraps, onto a new row or past a box
  border; one whose input box moves; a prompt redrawn in place; masked
  echo). The screen counts only when quiet: nothing drawn
  for 500 ms, no synchronized update open, and for the cursor, shown.
  A program's take holds while the screen is busy, so the send's own
  paste echoing does not refuse its Enter, and any key of the user's undoes
  it. The screen is read at a draft's first key, at Enter and at a write
  with Backspace, never at a text key, which keeps a text key's cost what
  it was (12 ns; one read is ~140 µs at 80×24, ~600 µs at 200×60). So a
  text key a menu took is counted too; what the line shows of the user's is
  still among the counted characters, because a Backspace at a menu reads
  the screen and is not counted. Where the core cannot tell, the draft
  stays: the rule is built to end late rather than early, and the few
  early ends it cannot see are listed below.

The send is **refused, not held**. The result starts with a stable phrase:
`Not sent (typing)` or `Not sent (draft)` (nothing written, with what to do
next), or `Not submitted (typing)` when a key lands after the paste, which
then waits on the line unsubmitted. `send_keys` stops at the refused key and
says how many went in.

A `report` with no Host worker running, which types the report at once
instead of queuing it in the Inbox, is a send too (#66): the same guard and
the same results. It used to retry a failed paste for up to 20 s; it now
fails at once like `send_text`, since a draft seldom clears that fast and a
paste left unsubmitted would be typed a second time.

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
presses Enter: a one-key prompt that a program redraws in place (the cursor
never leaves the row), a key the count cannot follow (Ctrl+U, Ctrl+W or
Alt+Backspace erasing a draft whose kept line came from before a redraw;
an arrow or a paste on one a program then took), a draft on a screen that
never goes quiet (a spinner, a clock), and a program whose cursor stays
hidden. The refusal says to ask the user to press Enter when the line shows
nothing of theirs. A draft can end early only where the core cannot see:
a raw-mode program that ignores Backspace, a text key a menu took inflating
the count so a later Backspace into what a program left there reaches
zero, a picker the menu detector misses taking a Backspace, a masked
secret drawn with a glyph not on the list, an Enter that does not send (a
completion accepted, a backslash continuation) until the next key, and a
draft hidden for 500 ms behind something that is no menu, with the cursor
shown elsewhere, that comes back while the screen is still busy. Menu-like text anywhere on screen reads as a menu, so a draft under
it does not refuse (#72).

The Inbox keeps ADR 0008's guard; `report` without a Host worker takes this
one (#66).
