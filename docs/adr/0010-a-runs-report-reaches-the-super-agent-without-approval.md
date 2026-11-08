# A Run's report reaches the Super Agent without approval

**Status:** accepted (2026-11-08)

## Context

The Super Agent sets up Scheduled Tasks whose instructions end with "send a
`sessions report` to the Super Agent". Every write to another Session goes
through the app-wide write policy. Under its default, Ask, the first write
of each (caller, target) pair raises an approval prompt and waits about two
minutes for an answer. Each Run is a new Session, so an approved pair never
carries over to the next Run, and nobody is there to answer when a Run
fires on its Trigger. The "Upstream: check for new commits" Run of
2026-11-07 reported only on its second try, after the user approved it.
A Worker's report to its own Router already skips the prompt (the Super
Agent spec's §18.1.7, under ADR 0003). Triage of #47.

## Decision

While a Host worker runs, a `report` from a Run Session to the Session
marked as the Super Agent skips the write gate and is queued in the
Router's Inbox, as a Worker's report is. A Run Session is one whose
`spawned_by` is `schedule:` followed by a non-empty task id, the same test
ADR 0006 uses. Only the Host's runner writes that prefix; Resume carries it
to the replacement Session. The skip holds whether or not the task still
exists, so a Run that removes its own task can still report.

Everything else keeps the ordinary policy: a Run's `send_text` and
`send_keys`, a Run's report to any other Session, and any other Session's
report to the Router unless it is the Router's Worker. App-wide Deny still
holds when the Inbox drains. Without a Host worker, `report` keeps
upstream's paste through the gate. A Run is not a Worker: it gets no
marker, no Worker card and no `handover` kind, and its report wakes the
Router by the same rules as a Worker's (`done`, `blocked` or questions).

## Considered Options

- **Remember an approval per task instead of per Session.** Rejected: the
  first Run of every task still waits out a prompt nobody is there to
  answer, and the Super Agent's id changes on Resume.
- **Let any Session report to the Router without approval.** Rejected:
  only Runs and Workers act for the user unattended; a user's own Session
  can be approved once and stays approved.
- **Make the Run a Worker.** Rejected: the Router would get a card, alerts
  and stop authority over Sessions the user owns ("A Run's Session is not
  your Worker").

## Consequences

Any agent in a Run Session can put items in the Super Agent's Inbox without
asking, including a Run the user resumed and kept talking in. Like the rest
of the MCP layer this is cooperative, not a boundary: the gate already
trusts the caller's own manifest. A Run's `update` report still rides
along until something wakes the Router, so the Router's instructions tell
it to have Runs report with `done`.
