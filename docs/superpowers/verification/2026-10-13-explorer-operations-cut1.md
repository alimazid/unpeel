# EXPLORER file operations, cut 1 — verification evidence

Date: 2026-10-13 · Branch: `feat/explorer-operations` · Spec:
alimazid/unpeel#12 (tickets #13–#20) · ADR 0002 · Screenshots in
`explorer-operations/` (local only, like the other verification screenshots).

Environment: macOS 26 (Darwin 25.6), Xcode 26.3 / Swift 6.2.4. The installed
`/Applications/Unpeel.app` and the real `~/.unpeel` are not touched.

## Decisions taken before building (the user, 2026-10-13)

- Move to Trash never asks; ⌘Z puts the items back.
- New File… selects and reveals the new file; it never opens it.
- Two cuts, each verified and installable on its own; cut 2 (#21, #22) starts
  after cut 1 is merged.
- No Delete Permanently.
- Implementer's calls: a per-root Operation History instead of
  `NSUndoManager` (operations run off the main actor and can fail for some
  items); undo of anything that created items trashes them; a created item
  is only trashed by an undo while it is exactly as the operation left it
  (same object, size and modification time; a created folder only while
  empty); two sources of one name in one paste or drop keep both.

## 1. Tests

- `clients/native/test-native.sh` at `d4e6813`: `Executed 1237 tests, with 0
  failures` (XCTest). Before this work (`1f689ba`): 1057.
- New suites (all against real temporary trees, no mocked file system):
  `FileOperationsTests`, `FileOperationsRaceTests`,
  `FileOperationsReverseTests`, `FileNameValidationTests`,
  `IncrementalNameTests`, `OperationHistoryTests`, `ExplorerOperationsTests`,
  `ExplorerEditMenuTests`, `ExplorerTrashTests`, `ExplorerSelectionTests`,
  `ExplorerRenameTests`, `ExplorerDraftTests`, `ExplorerClipboardTests`,
  `ExplorerDropRuleTests`, `ExplorerDropTests`, `FileTreeModelRelocationTests`.
  The rename, draft and Edit-menu suites drive a real `NSWindow`, field
  editor and first responder.
- The real Trash: `testTheSystemTrashRoundTrip` trashes through
  `FileManager.trashItem` and renames the item back out of `~/.Trash` — run
  from a shell whose responsible process is the Unpeel app.

## 2. Reviews

Each ticket had a strong-model review; every finding was fixed with a
regression test before moving on:

- #13 (`d6cd47c`): `copyfile` with `COPYFILE_RECURSIVE` merged into a folder
  (or wrote through a symlink) that appeared at the destination, and its
  cleanup could delete it — copies now stage under a unique name and are
  renamed into place exclusively; a failed Replace puts the trashed item
  back or keeps the step; case-only renames go through two exclusive
  renames; a rename cannot create `.git`.
- #14 (`c5e4c4e`): undo trashed an agent's in-place edit; a forged record
  could pull a file out of anywhere; a folder swapped for a symlink
  redirected the undo.
- #15 (`cf73974`): an expanded folder moved under a collapsed one never
  loaded; an undo right after switching back lost its selection.
- #17/#18 (`dbeefa7`): a reload of a folder above the edited row committed
  the half-typed name; closing a field from the update pass published to the
  view model mid-update.
- #19 (`d4e6813`): a skipped cut paste used up the cut; two sources of one
  name failed the second; stale cut dimming.
- #20 (`f8bc025`): a link-only drag fell through to a move.

## 3. In-app checks (dev build, dedicated `UNPEEL_HOME`) — PENDING

Not run yet: the screen was locked for the whole build. Each item below needs
the dev app (`clients/native/dev-blank.sh` with a dedicated `UNPEEL_HOME`), a
Session on a scratch git repository, and the EXPLORER expanded.

- [ ] Move to Trash (⌘⌫ and menu) → the items are in Finder's Trash; ⌘Z puts
  them back **from the app process** (the one check that could change the
  design: if the app may not rename out of `~/.Trash`, restore needs another
  path).
- [ ] Clicking a row (and ⇧⌘E) makes the tree first responder: Edit ▸ Undo
  reads "Undo Rename" etc.; Cut/Copy/Paste enabled only then.
- [ ] With a terminal focused, ⌘Z, ⌘C, ⌘V behave exactly as before.
- [ ] Return renames inline: field look in light and dark, stem selected,
  bubble under the row (also at the last row, not clipped), no flash on
  commit; Escape cancels.
- [ ] While a rename field is open in a git repository, an agent's write
  (decorations refresh) does not end the edit.
- [ ] New File… / New Folder… from the ⋯ header menu and the context menu:
  the Draft Row takes focus; a nested name creates folders and reveals the
  file; nothing opens.
- [ ] Copy in the tree → paste in Finder, and Finder → paste in the tree; cut
  rows dimmed; the Collision Prompt sheet attaches to the main window.
- [ ] Drag: rows onto a folder move; ⌥ copies (confirm ⌥, ⌘, ⌥⌘ masks);
  hovering a collapsed folder springs it open; a drop between rows lands in
  the expanded folder; a row dropped on a terminal pastes its path and the
  file stays put.
- [ ] A root switch while an operation's history exists (exercises the
  controller's activation observer teardown and per-root history).

Known and accepted: Git Status Decorations after an operation refresh with
the watcher's batch (about 150 ms), like any other change, rather than at
once.
