# Explorer Phase 1 — verification evidence

Date: 2026-09-21 · Branch: `feat/native-file-explorer` · Verified at commit `bf92dba`
Plan: `docs/superpowers/plans/2026-09-21-native-file-explorer-phase1.md`

Environment: macOS 26.6.2 (arm64, Dark appearance), Xcode 26.3 / Swift 6.2.4.
Runtime checks ran in an isolated dev build (`clients/native/dev-blank.sh`,
`UNPEEL_HOME=~/unpeel-dev-explorer-home`, menu bar "Unpeel Dev") driven by
synthesized mouse/keyboard events; results were read from window screenshots,
the clipboard, the session's terminal, process samples and `heap`. The
installed `/Applications/Unpeel.app` and its Host processes were running
throughout and were confirmed untouched (same PIDs) after every launch and
after stopping the dev app.

## 1. Regression gate

`clients/native/test-native.sh` → exit 0 —
`Executed 704 tests, with 1 test skipped and 0 failures`.
The skip is upstream's `HostServiceIdentityTests.testStaleWorkerIsRestartedOnceNotInALoop`
("needs crates/target/debug/unpeel-host"), unrelated to the explorer.

After the runtime-defect fixes: `swift test --filter UnpeelExplorerTests` →
103 tests, 0 failures; app-side explorer tests → 21 tests, 0 failures;
`swift build` → Build complete, no new warnings in touched files.

## 2. Coverage of `UnpeelExplorer` (measured before the runtime fixes, 96 tests)

| File | Lines | Cover |
|---|---:|---:|
| CanonicalPath, DirectoryLoader, DirectoryScanner, ExplorerItem, ExplorerKeyCommand, ExplorerPalette, ExplorerPaths, ExplorerStateStore, FileTreeModel | 253 | 100% |
| FileSystemWatcher | 117 | 97.4% |
| ExplorerViewModel | 241 | 94.2% |
| FileEntry | 29 | 93.1% |
| FileIconProvider | 23 | 91.3% |
| IgnoreChecking | 53 | 90.6% |
| ExplorerOutlineController | 502 | 75.9% |
| ExplorerPanelView (SwiftUI body) | 145 | 7.6% |
| ExplorerNSOutlineView (Quick Look plumbing) | 52 | 1.9% |
| ExplorerOutlineView (NSViewRepresentable) | 69 | 0% |
| **TOTAL** | **1485** | **73.0%** |

The spec's 80% target is **not met** on the raw total. Excluding the three
window-only view files the figure is ≈ 88%. Those three files were exercised by
the runtime checklist below, and the runtime fixes added windowed XCTest
harnesses (`ExplorerRowRenderingTests`, `ExplorerRowColorTests`,
`ExplorerLargeDirectoryTests`) that now cover part of them; coverage was not
re-measured afterwards.

ThreadSanitizer could not be used: with this toolchain `swift test
--sanitize=thread` crashes before running any test, even a single-threaded one
in a minimal package (SwiftPM inserts a TSan dylib path that does not exist).

## 3. Defects found at runtime and fixed (test-first, reviewed)

| # | Symptom | Root cause (measured) | Fix |
|---|---|---|---|
| 1 | Row labels invisible after first mount and after every root reload, until the panel's frame changed (`07-…png`, `08-…png`) | The single table column was never fitted to the clip view: 12 pt column in a 260 pt panel → label 4 pt wide behind the icon | `c7b53e4` — fit the column in `ExplorerNSOutlineView.layout()` |
| 2 | Root-level icons shrank to a dot after a root reload | Same starved column; re-laid-out root cells broke the icon's width constraint (3×16) | `c7b53e4` |
| 3 | Expanding a 10,050-file folder pinned the main thread at 100% CPU for 15+ minutes | `FileTreeModel.entry(at:)` scanned the listing linearly and `syncExpansion` queried every row on every `apply` (rows × directory size) | `bf92dba` — path index on `DirectoryListing`, expansion pass over expanded items only (apply 3.33 s → 0.108 s; 10k lookups 3.21 s → 0.011 s) |

Also fixed in `c7b53e4`: label colour on an emphasized selection (light-mode
text measured 3.48:1 on the accent fill; now ≥ 4.5:1).

## 4. Acceptance checklist (after the fixes, rebuilt dev app)

| # | Check | Result |
|---|---|---|
| 1 | ⌘⇧E shows/hides the column with a terminal focused; View menu reads "Hide Explorer"/"Show Explorer"; visibility, width (180) and filter toggles survived quitting and relaunching | PASS |
| 2 | Header shows the root folder name (middle-truncated when narrow); default listing hides `build`, `debug.log`, `.env`, `.gitignore`, `.git` | PASS |
| 3 | Show Hidden Files → `.env`, `.gitignore` dimmed; Show Git-Ignored Files → `build`, `debug.log` dimmed; `.git` never listed (`06-…png`) | PASS |
| 4 | Click on a folder row expands/collapses; the disclosure triangle toggles once (no double toggle); nested expansion survives collapsing the parent | PASS |
| 5 | ↑↓ move; → expands then moves to first child; ← collapses then moves to parent; type-select (`rec` → `recovered.txt`); Space opens Quick Look and Space closes it; ⌥⌘C absolute path and ⇧⌥⌘C relative path verified via `pbpaste` | PASS (⌘↓ and ⌥⌘R not exercised) |
| 6 | Double-click a file opens it in the configured editor (VS Code came to the front) | PASS |
| 7 | Context menu → Send Path to Agent pasted `src/main.ts` at the prompt as a bracketed paste, no Enter, terminal focused | PASS |
| 8 | Dragging `src/new.ts` onto the terminal pane pasted `src/new.ts`, no Enter | PASS |
| 9 | Auto-refresh: new file, new folder and deleted file reflected within 1.5 s with expansion and selection preserved | PASS |
| 10 | Two projects/sessions: the root follows the selected session; each root's expansion, selection and scroll offset are restored on return (`03-…png`) | PASS |
| 11 | Width drag clamps at both ends and persists; with the left sidebar collapsed the column keeps a leading inset, clears the title strip, and abuts the content card like the sidebar does | PASS |
| 12 | Opening Settings slides the column away; closing restores it including scroll position | PASS |
| 13 | Deleting the root shows "… could not be opened." + Retry; recreating the folder and pressing Retry recovers (`04-…png`, `05-…png`) | PASS |
| 14 | 10,050-file folder: loads and restores on relaunch in < 3 s, scrolling to the end is instant, CPU ≈ 2%, last row reads "… 50 more items not shown" (`01-…png`, `02-…png`) | PASS after fix 3 |
| 15 | Hidden panel holds no watcher: `heap` shows exactly one `FileSystemWatcher`, `ExplorerViewModel` and `ExplorerOutlineController` while shown and none while hidden, one each again when re-shown. (The plan's `lsof` method is invalid — FSEvents holds no file descriptor.) | PASS |

No Keychain/licence prompt appeared in the dev build.

## 5. Open issues (not fixed in Phase 1)

- The note row is middle-truncated at the 180 pt minimum width ("… 50…ot shown"); tail truncation would read better.
- Coverage total below the 80% target (see §2).
- ⌘↓ (open) and ⌥⌘R (Reveal in Finder) were not exercised at runtime; both are unit-tested.
- Minor review findings deferred to the whole-branch review are tracked in the branch's progress ledger.
