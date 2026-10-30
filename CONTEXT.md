# Unpeel (fork)

The fork's Mac workspace for running CLI agents, with VS Code-style views of
the project around the terminal. This glossary covers the fork-only views;
the shipped product vocabulary (Host, Controller, Session, Project) is in
`AGENTS.md`.

## Language

### Explorer

**Explorer Root**:
The folder the EXPLORER shows: the selected Session's worktree if it has
one, otherwise its Project's root. The Git views read its repository, or
the Nested Repository in use when it is not one. Local Hosts only.
_Avoid_: workspace folder, repo root

**File Operation**:
A change the EXPLORER makes to the working tree on the user's behalf: new
file or folder, rename, duplicate, move, copy, or Move to Trash. Acts as
Finder does, never through git, and is always undoable.
_Avoid_: file action, file command, edit

**Operation History**:
The undo and redo stacks of File Operations for one Explorer Root, kept for
the life of the app. ⌘Z in the EXPLORER walks it.
_Avoid_: undo stack, undo manager

**Draft Row**:
The temporary row with a name field that New File… or New Folder… inserts
into the tree; committing it creates the item, Escape removes it.
_Avoid_: placeholder row, new-item row

**Collision Prompt**:
The question a paste, drop or move asks when a name already exists in the
destination: Replace, Keep Both, or Skip, optionally for all items.
_Avoid_: overwrite dialog, conflict dialog

**Transfer**:
A paste or drop that copies more than about 50 MB or 200 items. It copies
out of sight first, showing a progress row with Cancel in the EXPLORER,
then puts everything in place as one undo step; cancelled or failed, it
leaves nothing behind and records nothing.
_Avoid_: copy job, background copy, progress task

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

**Nested Repository**:
A git repository in a folder inside an Explorer Root that is not itself a
repository. Git History and the Git Status Decorations follow the one in
use: chosen in Git History or with the EXPLORER's Use as Git Repository,
remembered per Explorer Root, and used without asking when it is the only
one found (up to two levels down). Never offered when the Explorer Root is
a repository.
_Avoid_: subrepo, child repo, submodule

**Checked-out Branch**:
The branch HEAD points to in the Explorer Root's working tree, shown in the
Git History header with its ahead/behind counts. It changes only through git
itself (an agent, the user's shell, or a new worktree), never through Git
History.
_Avoid_: current branch, active branch
