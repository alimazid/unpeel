# Unpeel (fork)

The fork's Mac workspace for running CLI agents, with VS Code-style views of
the project around the terminal. This glossary covers the fork-only views;
the shipped product vocabulary (Host, Controller, Session, Project) is in
`AGENTS.md`.

## Language

### Explorer

**Explorer Root**:
The folder the EXPLORER and the Git views show: the selected Session's
worktree if it has one, otherwise its Project's root. Local Hosts only.
_Avoid_: workspace folder, repo root

### Git

**Git Status Decoration**:
The letter and colour on an EXPLORER row giving the file's git state
(modified, added, untracked, deleted, renamed, copied, conflicted); a folder
carries the strongest state among its descendants.
_Avoid_: git badge, git marker, git icon

**Git History**:
The read-only GIT HISTORY sidebar section: the commit log of the Explorer
Root's repository, with each commit expandable to its message and changed
files.
_Avoid_: git graph, source control, history pane, git log view

**History Branch Filter**:
The choice of which branch's commits Git History lists. It never changes the
working tree.
_Avoid_: branch selector, branch picker, branch switcher

**Checked-out Branch**:
The branch HEAD points to in the Explorer Root's working tree, shown in the
Git History header with its ahead/behind counts. It changes only through git
itself (an agent, the user's shell, or a new worktree), never through Git
History.
_Avoid_: current branch, active branch
