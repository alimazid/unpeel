# The Host tells a person's keys from programmatic writes

**Status:** accepted (2026-11-07)

## Context

The Inbox pastes Worker reports into the Router when it is idle. The draft
guard compared the input line with a baseline taken once the screen had
been quiet for 3 s, so a draft the user had paused on became the baseline
and was pasted over and submitted with the batch (#38). The screen alone
cannot tell an empty prompt from a paused draft. Every write to a hosted PTY
went through the same `SessionHostCommand::Write`, whoever sent it, so the
Host could not say when a person last typed.

## Decision

`Write` carries an additive `origin`. Absent means the user: the attach
stream, the Mac app's controller writes, the phone's keys and its text box.
`"program"` is set by Unpeel and agent writers: the Inbox paste, MCP
`send_text`/`send_keys`, a preset's initial prompt, the screenshot request.
A writer that predates the field counts as the user, so an unknown writer
holds the Inbox rather than being pasted over.

Only a person's write that can change an input line counts as typing: keys,
text (dictation included) and the user's own bracketed paste. Mouse reports,
focus in/out and replies to terminal queries do not. Claude Code turns on
any-motion mouse tracking, so a pointer over its pane sends input bytes all
the time. The PTY core keeps the time in memory and flushes it to the
manifest as `last_input_at`, coalesced like `screen_changed_at`.
Programmatic writes never stamp it.

`Write` also carries `unless_typed_since`: the PTY core refuses the write
when a person typed at or after that time. The Inbox's paste and its Enters
use it, so a key that lands during the paste is never submitted with it.

## Considered Options

- **A screen-only guard (cut 1).** Rejected: a paused draft and an empty
  prompt look the same once the screen is still.
- **A separate command for programmatic writes.** Rejected: every caller
  already speaks `Write`, and an additive field keeps older PTY cores
  working; they ignore it and write as before.
- **Re-reading `last_input_at` before the Enter.** Rejected: the manifest
  stamp can lag the key by up to ~2.5 s, longer than the 250 ms paste
  settle. Only the PTY core sees the key in time.

## Consequences

A Session whose PTY core predates the field has no `last_input_at` and
keeps the older guard until it is resumed. Anything else that needs "is a
person at the keyboard" (idle detection, auto-stop) can read the same stamp,
and new writers must pick their origin. A new programmatic writer that
leaves `origin` out reads as the user's typing. The Inbox then waits for
3 s of quiet and an empty prompt, so the failure is a delay, never a paste
over a draft.
