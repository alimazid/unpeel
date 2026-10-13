# The EXPLORER's File Operations write to the working tree, as Finder does

**Status:** accepted (2026-10-13)

## Context

ADR 0001 keeps the fork's views read-only and says a view that writes to a
repository or edits a file needs its own decision. The operator wants
VS Code's explorer operations in the EXPLORER (alimazid/unpeel#12): new
file and folder, rename, duplicate, move, copy, cut/copy/paste, drag, and
Move to Trash, with undo. Those change the working tree.

## Decision

The EXPLORER may change the working tree through File Operations, and only
in the ways Finder would:

- **File-system calls, never git.** Operations go through `FileOperations`
  (`renamex_np`, copy, `FileManager.trashItem`), never `git mv`, `git rm`
  or any git command. A renamed tracked file shows as a deletion plus an
  untracked file until someone stages it; that is git's truth. Git History,
  Git Status Decorations and `GitRunner` stay read-only as ADR 0001 says.
- **Nothing irreversible.** No Delete Permanently. Removal is Move to Trash;
  undoing anything that created items moves them to the Trash; Replace in a
  collision trashes the item it replaces. Every operation is undoable
  through the Operation History of its Explorer Root.
- **Confined.** Writes stay inside the Explorer Root, never inside `.git`,
  never on the root itself, and never overwrite a destination that appeared
  after the check (agents write concurrently).
- **No editing.** File contents are still never edited in Unpeel; New File
  creates an empty file and does not open it.

## Consequences

ADR 0001's "read-only" line now reads "read-only, except the EXPLORER's
File Operations recorded here". A future operation that edits contents,
deletes without the Trash, or acts through git needs its own record.
