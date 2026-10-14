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
  failures` (XCTest). Before this work (`1f689ba`): 1057. After the in-app
  fixes (`72cab0a`): 1245, 0 failures.
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

## 3. In-app checks (dev build, dedicated `UNPEEL_HOME`)

Run 2026-10-13 evening with the dev build (`UNPEEL_DEV_BUILD=1`, stable
signing identity) against `UNPEEL_HOME=~/udgh`, on a Session in a scratch
git repository, driven by synthetic input (CGEvent) and checked through
the file system, the Accessibility tree, the pasteboard and screenshots.
The installed app was not touched.

- [x] Move to Trash (⌘⌫) → the file is in `~/.Trash`, the row below is
  selected; ⌘Z puts it back **from the app process** and selects it; ⇧⌘Z
  trashes it again. Edit ▸ Undo reads "Undo Move to Trash". Replace in the
  Collision Prompt trashes the old item and ⌘Z brings it back.
- [x] Clicking a row and ⇧⌘E make the tree first responder: Edit ▸ Undo
  reads "Undo Rename" / "Undo Paste" / "Undo Move" / "Undo Duplicate";
  Cut/Copy are enabled and Paste only with files on the pasteboard.
- [x] With a terminal focused, Edit shows the terminal's own items (Undo and
  Redo disabled, Paste enabled); ⌘V pastes text into the shell and ⇧⌘Z
  does not redo the tree's operation.
- [x] Return renames inline with the stem selected (`beta` of `beta.md`);
  Return commits and the tree keeps the keyboard; Escape cancels. **Found
  and fixed:** the bubble of the last visible row was clipped (it now
  opens above the field, `99346dc`); in light appearance the typed name was
  invisible on a selected row (`72cab0a`). Not checked: a flash on commit
  (too short for screenshots).
- [x] An agent writing into the folder (and the repository root) while a
  rename field is open does not end the edit; the listing lands when the
  field closes. **Found and fixed:** the selection was lost when it did
  (`99346dc`).
- [x] New File… from the ⋯ header menu: the Draft Row takes focus; with
  nothing selected it sits in the root; `notes/todo.md` creates `notes/`,
  expands it, selects the file, opens nothing. Duplicate from the context
  menu gives `agent-two copy.txt`.
- [x] Copy in the tree → ⌘V in a Finder window copies the file; ⌘C in
  Finder → ⌘V on a folder in the tree copies it there (Finder's file
  reference URL resolves). Cut rows are dimmed until pasted; a pasted cut
  moves once and Paste is then disabled. The Collision Prompt is a sheet
  on the main window; Keep Both gives `alpha copy.txt`; with two
  collisions it shows "Apply to all", and Skip with it ticked changes
  nothing. **Found and fixed:** a result outside the visible rows was
  selected but not scrolled to (`99346dc`).
- [x] Drag: a row onto a folder moves it; ⌥ copies; ⌘ moves; ⌥⌘ also moves
  (the source offers no link, so AppKit drops that modifier); hovering a
  collapsed folder springs it open; a drop between two rows of an
  expanded folder lands in it; a row dropped on a terminal pastes its
  relative path and the file stays put. No modifier stays latched.
  **Found and fixed:** releasing on a never-listed folder right after it
  sprang open was refused (`962defe`).
- [x] Switching the Session to another repository and back: each root
  keeps its own history ("Undo Move" back on return, nothing in the other).

Known and accepted: Git Status Decorations after an operation refresh with
the watcher's batch (about 150 ms), like any other change, rather than at
once. A folder that was never listed shows its contents only once a drag
that sprang it open has left the tree (the price of `962defe`); folders
listed before spring open with their rows.
