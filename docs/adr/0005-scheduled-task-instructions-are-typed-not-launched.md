# A Scheduled Task's instructions are typed once the agent is ready, never put on its command line

**Status:** accepted (2026-11-05)

## Context

A Scheduled Task on an Agent Preset has to hand the agent its instructions.
The obvious route is the command line (`claude "<instructions>"`, or a
headless mode such as `claude -p`). But `AGENTS.md` says launches are plain:
a preset runs exactly as typed and nothing appends a flag or wraps the
executable. Runtime descriptors declare no prompt argument, and each agent
takes one differently, if at all. Design detail:
`docs/superpowers/specs/2026-11-05-scheduled-tasks-design.md` (local only).

## Decision

A Run launches the preset exactly as typed, waits for the agent's first
real readiness signal (its program status report, a hook, or its declared
idle prompt on screen; a fresh Session's default "idle" never counts), then
types the instructions and submits them. This extends the existing
initial-text path of `session.create` with a wait-for-the-agent option.
No model or permission pickers: the preset's own command carries those.

## Considered Options

- **A `{prompt}` placeholder in the command.** Rejected: it adds templating
  and shell quoting to presets, and each runtime's syntax differs.
- **Headless mode.** Rejected: it's runtime-specific and leaves no
  conversation to follow up in. The terminal is the product surface.

## Consequences

Instructions work for any runtime whose readiness Unpeel can detect, and
only those count as Agent Presets. Readiness is the fragile part: an agent
that never reports ready fails to start after 2 minutes, and one that shows
no working signal within 60 s of the paste is marked "needs you".
