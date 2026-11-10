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
- **Which menu (#72).** The menu detector scans the whole screen for a
  footer's hints, so output that quotes a menu, or the user's own line,
  read as one. For the guard a menu counts only when its footer is on a row
  below a shown cursor; with the cursor hidden it counts anywhere on screen,
  as before. The attention badge and the phone's menu bar keep the whole
  screen. Where the cursor sits while a runtime's menu waits decided it:
  Claude Code hides it and parks it on the selected option, under it on
  the "Type something." option, and Codex hides it wherever it last drew,
  or shows it in a picker's search field, above the options. Both show it
  on the input line at an idle prompt. See the survey below.
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

The Inbox asks the core too where its own guard has nothing to compare
with (#69). After the user typed, ADR 0008's guard pastes only onto the
target's known-empty prompt, which the drain learns at a clean turn. A
Worker's first task can meet the user's typing before any: a person answers
its startup menu. The menu took those keys, so the core started no draft.
With no known-empty prompt, on a core with `draft_guard`, the Inbox's
paste carries `unless_draft` as well, and a `draft` refusal holds the task
`draft` until the user types again or the Router writes to the Worker: its
`send_text` or `send_keys` asks the core once more, so a refusal the core
would no longer give cannot strand a Worker nobody types into. An older
core holds it until a clean turn, as before.

### Where the cursor sits at a menu (#72)

Real journals (`output.bin`, 60 Sessions on this machine and its backups)
replayed through the core's `TerminalViewportState` at 400×100, sampled at
the end of each update. The Sessions ran at 120 to 352 columns; Claude
Code's alternate-screen renderer places every row itself, so the rows below
are as drawn and only wrapping differs. Rows count from the top of the
screen, from 0.

- Claude Code's question menu (AskUserQuestion), four Sessions: each update
  ends by moving the cursor to the bottom row, then to column 0 of the
  selected `❯ N.` row, without `?25h`, so the cursor stays hidden. For
  example options on rows 68–76 and the footer on 78, the cursor on 68; after
  Down, on 70 with `❯ 2.`. Footers sat 6 to 14 rows below it.
- Its permission prompt (`Esc to cancel · Tab to amend`): hidden, column 1
  of ` ❯ 1. Yes` on row 76; options 76–77, footer 79.
- Its "Type something." option, while the user typed an answer: shown and
  blinking, in the typed text on that option's row 72; footer on 76.
- Its idle prompt: every update ends on the input row, column 3, and shows
  the cursor (`CUP rows-3;3`, `?25h`).
- Codex: no journal holds a Codex menu (the one Codex Session ran with
  approvals bypassed, and the real `codex` is not run here). Its source
  (`codex-rs/tui`, `custom_terminal.rs` `draw_with_size`) hides the cursor
  when a frame sets no position, leaving it at the last cell drawn; the
  update picker, the approval overlay and the list pickers set none, and a
  picker's on-demand search sets it on its `Search ›` row, above the
  options and footer. At an idle composer it is shown on the input row.

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
- **Take a Worker's first idle line after its menu as its empty prompt
  (#69).** Rejected: the person who answered the menu may have typed there
  already, the paused draft #38 fixed.
- **Scope the menu to the cursor's row and below, shown or hidden (#72).**
  Rejected: a hidden cursor is wherever the program last drew, below the
  footer as easily as above it. A menu above it would read as none, a key
  there would start a draft, and the agent's answer to the menu would be
  refused as `draft`.
- **Count a footer on the cursor's own row (#72).** Rejected: that row is
  the user's line, which can say "enter to confirm or esc to cancel". No
  runtime surveyed waits at a menu with the cursor on its footer.
- **Ask the core again every 10 s while a draft holds the Inbox (#69).**
  Rejected: a draft can sit for hours, and each ask claims the batch,
  writes, releases it and announces on the state bus.

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
shown elsewhere, that comes back while the screen is still busy.
Menu-like text anywhere on screen still reads as a menu while the cursor
is hidden, so a draft under it does not refuse then: a program that keeps
the cursor hidden, or a read caught mid-redraw (#72). Footer-like text
below a shown cursor (a status line) reads as a menu too. A program whose
menu waits with the cursor shown on or under its footer would have its
keys start a draft; none surveyed does.

The Inbox keeps ADR 0008's guard and asks this one only while it knows no
empty prompt (#69), so that paste inherits the early ends above. While
the whole-screen scan sees a menu the drain holds `attention` and does not
paste at all; a draft typed under quoted menu text (#72) still holds it
`draft` once that text goes. `report` without a Host worker takes this
one (#66).
