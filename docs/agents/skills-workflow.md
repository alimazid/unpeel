# Skills workflow

How this repo runs the `mattpocock/skills` plugin. It follows Matt Pocock's
own walkthrough, ["mattpocock/skills: A complete AI Coding workflow,
end-to-end"](https://www.youtube.com/watch?v=M6mYodf0dJM), adapted for agent
Sessions that take direction from the Super Agent. For the whole map of
skills, run `/ask-matt` (the video calls it "me as a skill"). Before you say
what a skill does, or skip one, read its `SKILL.md`. On a skill's own steps
the `SKILL.md` wins; this page owns the settings that are specific to this
repo.

## The main flow

Every change takes the same route:

1. **Align.** `/grill-with-docs` interviews the maintainer until you share an
   understanding of the change. It records terms in `GLOSSARY.md` and
   decisions in `docs/adr/` as they land. A question that needs a runnable
   answer detours through `/prototype`.
2. **Fork on size.** If the work fits in what is left of the smart zone, run
   `/implement` right there. If it needs several sessions, run `/to-spec` (the
   destination), then `/to-tickets` (the route: tracer-bullet tickets, each
   sized to one smart zone), then `/implement` per ticket, or
   `/implement-spec` for the whole ticket graph.
3. **Build.** `/implement` drives `tdd` at pre-agreed seams, runs the checks,
   and then runs `code-review` before it commits to the current branch.
4. **Review.** `code-review` grades the diff on two axes, Standards and Spec,
   each in its own subagent. The session that wrote the code reviews it too
   kindly, so the review runs in a fresh window.

Raw issues come in through the **triage on-ramp**: `/triage` verifies the
claim, grills whatever is still open, and posts an agent brief, which
`/implement` then picks up. Triage is for issues that arrived raw. Tickets
from `/to-tickets` are already agent-ready. A bug that resists a first look
goes to `diagnosing-bugs`, which builds a feedback loop that goes red before
any fix.

## Context hygiene

- **Smart zone.** The budget is about 140–150k tokens. Past that, attention
  degrades, so size each session's work to fit inside it.
- Keep grilling, spec and tickets in **one unbroken window**, so each step
  builds on the same thinking.
- **One ticket per Session.** Each `/implement` starts fresh from its ticket.
  The ticket is self-contained, so the previous ticket's context can go. In
  Unpeel, "clear between tickets" means the Super Agent starts a new worker
  Session for each ticket.
- Choose between continue, `/clear`, `/handoff`, a subagent and `/compact`
  only at a phase boundary, using the tree in `ask-matt`'s
  `PHASE-BOUNDARIES.md`. A ticket worker needs no `/handoff`, because the
  issue and its agent brief are the context.

## Driving the skills from a Session

- **The Super Agent speaks for the maintainer.** Decisions (grilling rounds,
  triage recommendations, test seams) go to the Super Agent's Session with
  the `unpeel` MCP `sessions` `report` action. Put the round in `questions`:
  number each question, give your recommended answer, and word it so "yes"
  accepts the recommendation. Set `status` to `blocked` until it is answered.
  Questions go only through `report`, never through choice menus. Facts are
  your job: look them up, with a subagent if needed.
- **Most skills are user-invoked.** `/triage`, `/implement`,
  `/grill-with-docs`, `/to-spec`, `/to-tickets`, `/implement-spec`,
  `/handoff`, `/retro` and `/ask-matt` run only when someone types them. The
  Super Agent starts a worker by typing the slash command as the worker's
  first input, for example `/implement #28`. A worker told to run one of
  these skills without the slash command reads that skill's `SKILL.md` (under
  `~/.claude/plugins/cache/*/mattpocock-skills/`) and follows it as written.
  The model invokes `tdd`, `code-review`, `diagnosing-bugs`, `grilling`,
  `domain-modeling`, `codebase-design`, `prototype` and `pr` on its own.

## This repo's settings

- **Glossary and ADRs:** `GLOSSARY.md` at the repo root and `docs/adr/`. Use
  the glossary's terms (Scheduled Task, Trigger, Run, Agent Preset). The
  rules are in [domain.md](domain.md).
- **Tracker and labels:** [issue-tracker.md](issue-tracker.md) (GitHub on the
  fork) and [triage-labels.md](triage-labels.md).
- **Standards sources** for `code-review`: [AGENTS.md](../../AGENTS.md) (the
  hard invariants and client rules), [CONTRIBUTING.md](../../CONTRIBUTING.md),
  and the `docs/agents/` page that owns the area you touched.
- **Spec source** for `code-review`: the issue body plus its agent brief. Put
  `#<n>` in every commit message so the review can find it. The fixed point
  is `git merge-base main HEAD`.
- **`/implement`'s checks** in this repo's terms. The fork's `run.sh` shares
  the machine through slots, so `CONTRIBUTING.md`'s "never run two `run.sh`
  invocations at once" and its `UNPEEL_TUI_TEST_BASE` advice don't apply
  here (see [the matrix README](../../crates/unpeel-cli/tests/README.md)).
  Several runs may go at once, from any worktrees, with no lock of your own:
  each case takes one of `UNPEEL_TUI_SLOTS` machine-wide slots (default 4),
  waits while all are busy, and names its home after its slot. Keep
  `UNPEEL_TUI_SLOTS` the same for every run on a machine, leave
  `UNPEEL_TUI_TEST_BASE` unset, and pass `-j N` to let one run hold up to N
  slots.
  - "typecheck" means `cargo clippy` with `-D warnings` on the crates you
    touched;
  - "single test files" means a filtered `cargo test` or
    `crates/unpeel-cli/tests/run.sh <filter>`;
  - "the full suite at the end" means the "Tests to run" list in
    [AGENTS.md](../../AGENTS.md), plus the fork's
    `scripts/verify-matrix-runner.sh` (`run.sh` itself: isolation, slots,
    `-j`, interrupt; fake cases, ~50 s, safe beside a real `run.sh`). Run the
    whole PTY matrix after you touch the CLI, `unpeel serve` or anything they
    share with the clients, and the client suites after you touch `clients/`.
    A change to `docs/` still runs `scripts/check-links.sh`.
  - After you touch the sidebar's PROJECTS list, also run
    `scripts/verify-sidebar-interaction.sh --app clients/native/dist/Unpeel.app`
    on a dev build, then again with the long-list options in its header, then
    with `--only cross-project-insert,session-above-folder`, which need a list
    that ranks no folder yet. It
    clicks and drags with the real pointer on a throwaway home, because xctest
    can't reach those paths. It needs an unlocked screen and pauses on any
    input from the user. When a change can look different at 2x, run it there
    too (`--scale`, also in the header). `clients/native/test-native.sh` and CI
    only compile the driver (`scripts/ci/check-sidebar-driver.sh`), so a change
    to its checks needs a real run, and one that goes red on a build with the
    bug put back.

  Every run uses a private `UNPEEL_HOME`. A unit-test binary that resolves
  the home sets its own before `main` unless the caller already did
  (`src/test_home.rs` in `unpeel-core`, `unpeel-serve` and
  `unpeel-native-bridge`: a `#[ctor]` hook plus a guard test), so a plain
  `cargo test` needs no setup. A new crate whose tests resolve the home gets
  the same `test_home.rs`; process tests pass their own `HOME`/`UNPEEL_HOME`
  to the binaries they spawn. The Mac app's test bundle does the same from
  C (`clients/native/UnpeelNative/Tests/UnpeelNativeTestHome`, guarded by
  `TestHomeIsolationTests`). It claims a reused `/tmp/unt-<n>` slot under
  an flock, and that slot also names its defaults suite. It sets
  `UNPEEL_TEST_NATIVE_SUITE` and points `UNPEEL_HOST_CMD` at
  `/usr/bin/false`, so no test starts a Host. The PTY matrix and the
  verify scripts build their own homes.

## Taking a raw issue to done

This covers the follow-ups from #27 (Scheduled Tasks, spec #26), #28–#34,
which were filed as `needs-triage` from #27's known gaps. They are raw issues
with independent fixes, so each one takes the triage on-ramp and then
`/implement`. `/implement-spec` doesn't apply, because they don't form a
ticket graph.

1. **Triage all of them in one Session** with `/triage`. That way the
   maintainer's decisions come in as few rounds as possible. Triage notes
   and briefs live on the issues, so if the Session nears the smart zone,
   `/clear` and resume from them. For each issue:
   - **Verify before you grill.** Several were found in review and never
     reproduced (#28–#30). Reproduce them. For a race, build a test that goes
     red with `diagnosing-bugs`. A claim that won't reproduce is still
     evidence for triage.
   - **Grill the open decisions** through the Super Agent. Each of #30–#34
     has at least one: a "Decisions needed" section, or a criterion that
     offers a choice. Record any answer that is hard to reverse as an ADR.
   - **Apply the outcome.** Set the category to `bug` or `enhancement` (the
     `question` label comes off once the question is answered). Then move
     the issue to `ready-for-agent` with an agent brief, or to
     `ready-for-human`, `needs-info` or `wontfix`. Start every triage comment
     with the skill's AI disclaimer.
2. **Implement each `ready-for-agent` issue in its own fresh worker
   Session**, started with `/implement #<n>`, in its own worktree on a
   branch off `main`. The agent brief is the contract. The seams in spec
   #26's Testing Decisions count as pre-agreed for Scheduled Tasks work: the
   PTY matrix, the scheduler's step function with injected time, and the Mac
   app's SCHEDULED section model. A test at any other seam needs a yes from
   the Super Agent first.
3. **Land one ticket at a time.** First merge `main` into the branch and
   rerun the affected tests. Then, in the main checkout (`git worktree list`
   shows it; other Sessions share it, so confirm it is clean and on `main`),
   run `git merge --no-ff` with the message `Merge <branch>: <outcome>
   (#<n>)`. The fork is public, so check
   `git log --name-only origin/main..main` for screenshots or client names
   before you push. Most of these tickets touch the same schedules code, so
   land them one after another even when they were built in parallel.
4. **Close the issue** with `gh issue close <n> --comment`, naming the merge
   commit and the checks you ran. Then send a `report` with status `done` to
   the Super Agent, with that proof.

A ticket is done when every acceptance criterion in its brief holds, the full
suite for its area is green, the merge is on `origin/main`, and the issue is
closed. If a ticket went sideways, run `/retro` in its Session before the
Session ends, so the lesson becomes a check or a coding standard.
