# The Host's health check alerts once per episode

**Status:** accepted (2026-11-10)

## Context

Scheduled Tasks and the Router can go wrong with nobody told: a Run fails
at night, an occurrence is skipped behind a Run left waiting, a task stops
firing, the Router stops, its Inbox stops delivering (#84). The Router is
an LLM. It cannot watch for its own absence, and it should not have to poll
for things the Host already knows.

## Decision

`unpeel serve` runs a check every 5 minutes, with no LLM
(`unpeel-serve/src/health/`). It looks for five problems: a failed or
skipped Run; a Run waiting on a prompt, or blocked, for 30 minutes; a
missed fire 10 minutes late; a marked Router that is not running; and an
Inbox delivery due for 15 minutes. The limits are named constants. The
rules are a pure function of what the Host sees, the state the last check
left, and the time.

- **Once per episode.** A problem alerts once. It alerts again only after a
  check saw it gone and a later check saw it back. Failures alert again
  after a done Run; skips alert again after a Run starts. A failed or
  skipped Run is news only when its line was recorded after the last check,
  so history never alerts. `failed_to_start` counts as failed.
- **Waiting and blocked.** A waiting Run's clock starts when a check first
  sees it waiting: the Run line records no such time. Every Run that
  reported `blocked` and still needs attention (#81) counts from its
  report, until a new report or a failure. A later Run does not clear it.
  A waiting Run that reported `blocked` raises one alert.
- **The newest failure is found by log order**, not by end time. A done
  agent Run's end moves forward with each later turn.
- **Where an alert goes.** Each alert goes to the Router's Inbox as a Host
  report (`blocked`, wake) and to the Mac as an alert notification. A
  stopped Router alerts only the Mac. Its undelivered Inbox does too, and
  that check pauses while the Router is down. A failure alerts only the
  Inbox, because the Run's own notice is already a Mac banner. While the
  Router is down, the other reports still queue.
- **State on disk.** It lives in `<UNPEEL_HOME>/health/state.json` and holds
  the problems, the last check time, when the Router was first seen
  running, and the notifications kept because no app could show them (at
  most 20, oldest first). A kept alert whose problem cleared is dropped,
  and a check runs before kept notifications go out.

## Considered Options

- **The Router watches for these itself.** Rejected: it cannot report its
  own absence, and polling costs turns.
- **A new Run field for when waiting began.** Rejected: a first-seen time
  in the check's state is enough, and it changes no shared format.
- **Alert on every check while a problem lasts.** Rejected: it buries the
  Inbox and the Mac in repeats.

## Consequences

An episode is what the 5-minute checks see. Fail, done, fail inside one
interval is one episode: the second failure still gets its Run's own
banner, but a second skip in that window gets nothing. A state file that
will not read starts over, which can repeat a lasting problem's alert once,
but never hides one. On the first check after install, every Run that
still needs attention is checked, old ones included.
