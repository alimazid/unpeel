# EXPLORER file operations, cut 2 — verification evidence

Date: 2026-10-14 · Branch: `feat/explorer-operations-cut2` · Spec:
alimazid/unpeel#12 (tickets #21, #22) · ADR 0002 (amended) · CONTEXT.md
(**Transfer**).

Environment: macOS 26 (Darwin 25.6), Xcode 26.3 / Swift 6.2.4. The installed
`/Applications/Unpeel.app` and the real `~/.unpeel` are not touched.

## Decisions

- **A move from another volume trashes the original, never deletes it**
  ("nothing irreversible"). It copies, compares the copy with the original
  (every path, kind, file size and link destination; `.DS_Store` ignored),
  puts the copy in place, and only then moves the original to its volume's
  Trash. If that volume has no Trash the copy stays, the original stays,
  and the message says so.
- **Undo of a ⌘-drop from Finder writes outside the root**, to exactly
  where the item came from. Each record names the outside paths it took
  items from (`FileOperationRecord.outsidePaths`); an undo or redo refuses
  any other outside path, so a forged or buggy record cannot reach further
  (ADR 0002 amended).
- **Transfers copy outside the operation queue.** Planning (which measures
  what will be copied, off the main actor) is queued like every operation;
  the copying is not, so a rename or ⌘Z never waits behind a large copy;
  putting the copies in place is queued again — one undo step. A collision
  that appears during a long copy fails that item at the end (its copy is
  removed) and the message says so.
- **Two large copies at once each run and each show their own row.**
- **The row appears only after 300 ms**, so a copy that clones instantly
  (one APFS volume) never flashes one.
- **Copies are staged in the destination folder** under
  `.unpeel-copy-<uuid>` (cut 1's mechanism): hidden by default, visible
  with Show Hidden Files and to git as untracked while a Transfer runs.
- Drags out to Finder are unchanged: rows are exported as file URLs with
  copy, generic and link offered (no move); Finder applies its own rules
  and the EXPLORER never deletes a source after a drag.

## 1. Tests

- `clients/native/test-native.sh`: `Executed 1292 tests, with 2 tests
  skipped and 0 failures` (XCTest). Before this cut (`b88afdb`): 1246.
- New suites, against real temporary trees: `FileOperationsExternalTests`
  (copy and move from outside, undo/redo back out, forged outside paths
  refused, cross-volume move with an injected failing copier — the original
  untouched and no partial output — with a copy that does not match, with
  no Trash, and with Replace), `FileOperationsStagingTests` (measuring,
  the real copier's progress and cancel, stage/commit, cancel mid-copy with
  a gated copier leaving nothing, failure removing every staged copy, skip,
  an original changed while staged), `ExplorerTransferTests` (small copies
  show no Transfer, a large one is one undo step, cancel leaves nothing and
  records nothing, failure removes partial output and shows the message,
  other operations do not wait, two at once, a large cross-volume move,
  the 300 ms row, a root change mid-Transfer), `ExplorerFinderDropTests`.
- `FileOperationsVolumeTests` runs only with `UNPEEL_TEST_OTHER_VOLUME`: on
  an APFS disk image (`hdiutil create -fs APFS`, attached with
  `-nobrowse`) both pass — a 64 MB folder moved from the image reports
  every item and byte, its original lands in the image's Trash and undo
  brings it back; cancelling a 256 MB copy mid-file leaves nothing.

## 2. Reviews

A strong-model review of the whole cut found no confinement or data-loss
defect; every finding acted on got a regression test (each checked to fail
with its fix reverted):

- Undoing a move across volumes whose original was no longer in the Trash
  still trashed the copy, leaving the item only in the Trash — the copy and
  its original now undo (and redo) as a pair.
- A Transfer commits minutes after it plans, and trusted the planned path:
  a move now re-resolves each source and acts only while it is the same
  object.
- The copy was only compared by shape, so an original edited in place
  (same size) while it was copied would be trashed for a stale copy — the
  original must now be exactly as it was when its copy began (file and link
  times; a changed original fails with "changed since").
- Extended-attribute errors were all ignored; now only "not supported"
  (a destination that cannot hold them) is, any other stops the copy.
  The callback reads `errno` first and keeps the first failure.
- The real copier's byte-by-byte path (`COPYFILE_COPY_DATA` progress,
  cancel mid-file, an unreadable file) is now covered by default, with
  cloning switched off in the test.

Accepted: a crash or quit in the middle of a Transfer leaves its hidden
`.unpeel-copy-<uuid>` behind (nothing sweeps it); an app that offers only
a generic drag operation (no copy) moves; free space is not checked
before a Transfer starts (it fails, cleans up and says why); two Transfers
of one name into one folder — the second fails at the end.

## 3. In-app checks (dev build, dedicated `UNPEEL_HOME`)
