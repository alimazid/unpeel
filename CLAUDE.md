@AGENTS.md

## Agent skills

### Issue tracker

GitHub Issues on the fork `alimazid/unpeel` (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Workflow

The main flow (grill → spec and tickets → implement → two-axis review), context hygiene, and how a Session runs the user-invoked skills with the Super Agent as maintainer. Read `docs/agents/skills-workflow.md` before taking an issue to done.
