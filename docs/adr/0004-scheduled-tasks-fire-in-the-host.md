# Scheduled Tasks fire in the Host, so they run with the app closed

**Status:** accepted (2026-11-05)

## Context

The operator wants the Claude desktop app's scheduled tasks in Unpeel: a
Scheduled Task starts a Session from a preset on its Trigger, unattended.
The clock has to live somewhere that is running at the Trigger's time.
`unpeel serve` is a per-user LaunchAgent with `RunAtLoad` that keeps running
after the app quits; the Mac app is a pure Controller. Design detail:
`docs/superpowers/specs/2026-11-05-scheduled-tasks-design.md` (local only).

## Decision

The Host keeps and fires Scheduled Tasks. Each workspace worker evaluates
its own workspace's tasks against the local wall clock from its existing
tick and starts Runs itself. Definitions live in `app-state.json` under the
flock and state-bus rules; the app and the phone reach them only through an
additive, advertised `schedule.*` Host capabilities, the same for local and
remote Hosts. The app never runs a timer.

Notifications stay where they are today, in the app. While the app is quit a
finished Run gets no banner or phone push: the Host marks its Session
unread, and it shows when the app reopens.

## Considered Options

- **A timer in the Mac app.** Rejected: it stops when the app quits, can't
  serve a remote Host, and breaks the pure-Controller rule.
- **Moving phone push into the Host** so Runs notify with the app closed.
  Deferred: that's a new subsystem (APNs is sent by the app today), not
  something scheduling should bring in.

## Consequences

A Scheduled Task fires from login onward, app open or not, and never wakes
the Mac; a Trigger missed while the Mac slept or the Host was down fires
once when it's back. This extends the Host protocol as fork-only code, like
the fork's other Host verbs, so merges from `upstream/main` must carry it.
