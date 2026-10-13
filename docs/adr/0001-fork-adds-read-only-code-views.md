# The fork adds read-only, VS Code-style views around the terminal

**Status:** accepted (2026-09-21 for the EXPLORER, 2026-10-11 for Git Status
Decorations and Git History; recorded 2026-10-13)

## Context

Upstream Unpeel will never grow code-editor affordances: "no diff viewers, no
file trees, no source editors, no language tooling, no IDE chrome"
(`AGENTS.md`, Product philosophy; `CONTRIBUTING.md`, "Unpeel is never an
IDE"). This fork is the operator's daily Unpeel and they want to see the
project around the terminal, as they would in VS Code, while agents work in it.

## Decision

The fork departs from that rule for a small set of read-only views, and
nothing beyond them: the EXPLORER (a file tree of the Explorer Root, with Git
Status Decorations), the Markdown preview pane, and the GIT HISTORY section
(commits, the History Branch Filter, a commit's message and changed-file
names). They keep these lines:

- **Read-only.** The views never change the repository or the working
  tree: no staging, committing, checkout or fetch. Their git runs only
  through `GitRunner`'s read-command list with `GIT_OPTIONAL_LOCKS=0` and
  `GIT_NO_LAZY_FETCH=1`. The one exception is the EXPLORER's File
  Operations (new, rename, move, copy, trash), which act on files as Finder
  does, never through git — see ADR 0002.
- **No diffs and no editing.** A changed file is a name and a letter; opening
  it opens the working-tree file in the user's own editor or the Markdown
  preview. No diff viewer, source editor, or language tooling.
- **Local Hosts only, fork-only targets.** The views read the local disk and
  never extend the Host protocol; they live in the fork-only `UnpeelExplorer`,
  `UnpeelMarkdownPreview` and `UnpeelGit` targets, and upstream files are
  touched only at points marked "Fork-only".
- **Not for upstream.** Upstream declines these surfaces, so none of this is
  proposed upstream; `AGENTS.md` and `CONTRIBUTING.md` stay as upstream wrote
  them, to keep merges from `upstream/main` clean.

## Consequences

A future view is judged against these lines first: one that writes to a
repository, shows a diff, or edits a file needs its own decision recorded
here. Reviews that apply upstream's "never an IDE" rule to the views above
should cite this record instead of flagging them.
