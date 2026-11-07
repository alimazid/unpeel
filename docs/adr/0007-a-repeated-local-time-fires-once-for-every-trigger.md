# A repeated local time fires once, for every kind of Trigger

**Status:** accepted (2026-11-06)

## Context

Triggers read the Host's local wall clock (ADR 0004). On the night clocks go
back, the local times of one hour happen twice. The Scheduled Tasks spec
agreed that a fixed time on that night runs once; the implementation applied
the same rule to every Trigger kind and compares occurrences as local
date-times. So an hourly task fires one time fewer that night, and an
every-minute cron task is quiet for the whole second pass. Classic cron
does it the other way for interval jobs. Triage of #33.

## Decision

Every Trigger kind fires a repeated local time once, on its first pass:
daily, weekdays, weekly, once, hourly, and every cron expression. The rule is
stated in `docs/agents/cli.md` and the `unpeel schedules` help, and step
tests pin it for hourly and `* * * * *` in a fixed zone.

## Considered Options

- **Classic cron's rule**: interval Triggers (hourly, and cron with an hour
  field of `*` or `*/n`) fire on both passes, fixed times once. Rejected: it
  needs a new instant in every task's stored clock (a local time cannot say
  which pass already fired, across a Host restart) and instant-aware
  next-run logic for hourly and cron, about 200–400 lines, for one night a
  year. One rule for every kind is also simpler to state.

## Consequences

Someone who knows cron will expect minute-level cron to keep firing through
the repeated hour; it doesn't, by design. Revisiting this means adding the
stored instant above. On a Host whose zone has no DST the rule never applies.
