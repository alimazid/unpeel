# Native File Explorer for the Mac app — Design

Date: 2026-09-21
Status: approved 2026-09-21; Phase 1 implemented — see §7 for what changed while building it
Repo: `alimazid/unpeel` (fork of `unpeel-com/unpeel` at 0.7.3), branch `feat/native-file-explorer`

## 1. Goal

Add a VS Code–style file explorer to the Unpeel Mac app: a native, collapsible
tree of the selected session's project, with VS Code's file management, git
decorations, and keyboard behaviour. The explorer sits in the app window as its
own resizable column between the left sidebar and the terminal content.

### Decisions already made

| Decision | Choice |
|---|---|
| Scope | Full VS Code explorer parity, delivered in four phases |
| Placement | Native Mac panel between `SidebarView` and `ContentArea` |
| Implementation | AppKit `NSOutlineView` in a new SwiftPM target `UnpeelExplorer` |
| Root folder | Selected session's worktree if it has one, else its project folder |
| Remote hosts | Not supported; panel shows an explanatory empty state |
| File open | Double-click → configured editor; Space → Quick Look; Enter → rename |
| "Open Editors" section | Dropped (Unpeel has no editor tabs) |
| GitHub account | `alimazid` (personal), never the work account |

### Non-goals

- iOS / iPad client, the TUI, and remote-Host sessions.
- Any change to the Host, the Host protocol, `protocol/`, the *persisted*
  pane-layout contract, or App Kit's `unpeel.ui/1` contract. (The 2026-09-22
  preview pane adds a transient, never-persisted leaf to the client-side pane
  model; the durable schema and fixture are unchanged.)
- Replacing or modifying the existing `crates/apps/filetree` TUI app.
- Editing files inside Unpeel. Files open in the user's external editor.
- Upstreaming. Upstream declines file trees (`CONTRIBUTING.md`, "Unpeel is
  never an IDE"), so this lives in the fork only.

### Fork constraints

- `TRADEMARK.md`: private builds may keep the Unpeel name. Distributing a
  modified build requires a new name and icon and must not use Unpeel's update
  feeds or Link service. Nothing in this project distributes a build; revisit
  before any release.
- Merge hygiene: upstream ships often and its core Swift files are very large
  (`UnpeelStore.swift` is ~16.6k lines). All explorer code goes in **new
  files**. Edits to existing files are limited to the small, enumerated
  touchpoints in §3.3 so `git merge upstream/main` stays cheap.

## 2. User experience

```
┌──────────┬───────────────┬──────────────────────┐
│ Projects │ EXPLORER  ⋯   │ claude ~/proj        │
│ ▾ proj   │ ▾ src         │                      │
│   claude │   ▾ views     │ > fix the bug in     │
│   codex  │     App.tsx M │   App.tsx            │
│ ▸ other  │     Nav.tsx   │                      │
│          │   main.ts   U │ ● Editing App.tsx…   │
│          │ ▸ tests       │                      │
│          │   README.md   │                      │
└──────────┴───────────────┴──────────────────────┘
  existing     NEW column        existing
```

- **Toggle:** View ▸ Show/Hide Explorer, ⌘⇧E (unused in the app today). State
  persists across launches. Hidden by default so an upstream-identical window
  is the first-run experience.
- **Width:** drag the column's trailing edge; min 180, default 260, max 520;
  persisted globally.
- **Header:** the root folder's name in small caps, plus a `⋯` menu holding
  Refresh, Collapse All, Show Hidden Files, Show Git-Ignored Files (Phase 2
  adds New File and New Folder).
- **Root follows selection:** selecting another session re-roots the tree to
  that session's worktree/project. Expanded folders, selection, and scroll
  position are remembered **per root path** and restored on return.
- **Empty states:** no session selected → "Select a session to browse its
  files."; remote-Host session → "The explorer is available for sessions
  running on this Mac."; root missing/unreadable → the error with a Retry
  button.
- **Hidden in full-content pages:** the column slides away while Settings is
  shown, matching the right project panel's behaviour.

### Interaction model (VS Code on macOS)

| Input | Action |
|---|---|
| Click | Select. Click on a folder row also toggles expansion (VS Code default) |
| Double-click file | Open through Unpeel's open-with rules (`UnpeelStore.openClickedFile`; `.md` → Markdown plugin side pane, else the editor). Phase 1 shipped editor-only; amended by `2026-09-22-explorer-open-with-rules-design.md` |
| ⌘-click / ⇧-click | Toggle / range multi-select (Phase 2) |
| ↑ ↓ | Move selection |
| → | Expand folder; if expanded, move to first child |
| ← | Collapse folder; if collapsed or a file, move to parent |
| Enter | Rename (Phase 2) |
| Space | Quick Look the selection |
| ⌘↓ | Open file (same open-with rules as double-click) / expand folder |
| ⌘⌫ | Move to Trash (Phase 2) |
| ⌘C / ⌘X / ⌘V | Copy / cut / paste files (Phase 2) |
| ⌘Z / ⇧⌘Z | Undo / redo the last file operation (Phase 2) |
| ⌥⌘C | Copy Path; ⇧⌥⌘C copy relative path |
| ⌥⌘R | Reveal in Finder |
| Type letters | Type-select (native `NSOutlineView` behaviour) |
| Drag row → terminal pane | Pastes the shell-quoted path (existing `.fileURL` drop target in `GhosttyBridge.swift`; no terminal changes) |
| Drag row → folder row | Move; ⌥-drag copies (Phase 2) |
| Drag from Finder (or any app) → folder row | Copy into that folder; hold ⌘ to move instead (Phase 2, see "External drops") |
| Drag row → Finder / another app | Exports the file URL; Finder applies its own copy/move rules (Phase 2) |

Keyboard shortcuts apply only while the outline view is first responder, so
they never steal keys from a terminal.

### Context menu

Phase 1: Open in Editor, Reveal in Finder, Quick Look, Send Path to Agent,
Copy Path, Copy Relative Path, Refresh, Collapse. Added 2026-09-22: Open
(open-with rules; first item for files — see
`2026-09-22-explorer-open-with-rules-design.md`).
Phase 2 adds: New File…, New Folder…, Rename…, Duplicate, Cut, Copy, Paste,
Move to Trash.

"Send Path to Agent" pastes the path into the **focused pane's** terminal
(the active pane of a split, else the selected session) without pressing
Enter, through the terminal's own attach path (focus + bracketed paste), so
the result is identical to dragging the row onto that terminal. The path is
shortened against **that pane's working directory**, not the project root and
not the explorer's root: two worktrees of one repository mirror each other, so
shortening against the wrong basis yields a plausible relative path that
silently names the other worktree's copy. A file outside the pane's directory
falls through to the terminal's `~/…`/absolute form; image paths stay absolute
(the terminal's existing rule, so agents attach them as images).

## 3. Architecture

### 3.1 Module boundary

A new SwiftPM library target **`UnpeelExplorer`** in
`clients/native/UnpeelNative/Package.swift`, sources under
`Sources/UnpeelExplorer/`, tests under `Tests/UnpeelExplorerTests/`.

`UnpeelExplorer` depends on **Foundation and AppKit only** — not on
`UnpeelStore`, Ghostty, `UnpeelShared`, or the Rust bridge. This is the point
of the split: the whole feature builds and unit-tests without the terminal
engine (Ghostty surfaces cannot initialise headless), and upstream churn in
the app target cannot break it.

The app target `UnpeelNative` gains a dependency on `UnpeelExplorer` and one
small adapter file that feeds it app state and receives its intents.

```
UnpeelNative (app)                         UnpeelExplorer (library)
┌───────────────────────────┐   root URL   ┌─────────────────────────────┐
│ ExplorerPanelHost.swift   │ ───────────▶ │ ExplorerPanelView (SwiftUI) │
│  · derives ExplorerContext│              │  └ ExplorerOutlineView      │
│    from UnpeelStore       │ ◀─────────── │     (NSViewRepresentable →  │
│  · implements             │   intents    │      NSOutlineView)         │
│    ExplorerActionHandler  │              │ ExplorerViewModel           │
└───────────────────────────┘              │ FileTreeModel  FileEntry    │
                                           │ DirectoryLoader             │
                                           │ FileSystemWatcher (FSEvents)│
                                           │ DirectoryScanner  FileIconProvider
                                           │ ExplorerStateStore          │
                                           │ (P2) FileOperations         │
                                           │ (P3) GitStatusProvider      │
                                           └─────────────────────────────┘
```

### 3.2 Units

Each unit has one purpose and is testable alone.

| Unit | Responsibility | Depends on |
|---|---|---|
| `FileEntry` | Immutable row value: `path`, `name`, `kind` (file/directory, following symlinks), `isSymlink`, `isHidden`, `isIgnored`, `isExpandable` | — |
| `DirectoryLoader` | Read **one** directory off the main thread → sorted `[FileEntry]` (folders first, then `localizedStandardCompare`, matching VS Code's default). Never follows a directory symlink out of the root | FileManager |
| `FileTreeModel` | Pure, immutable tree state: a flat map of directory path → contents (`loading` / `loaded` / `failed`) plus the expanded set, with reducers `settingContents`, `expanding`, `collapsing`, `collapsingAll`, `removingDirectory`. Flat rather than nested so a reload replaces one entry and an outline row is addressed by path. Every reducer returns a new model | `FileEntry` |
| `FileSystemWatcher` | One FSEvents stream on the root; coalesces events (150 ms) into a `FileSystemChange`: a set of changed directory **paths** (`Set<String>`), a `touchedGitignore` flag, and a `needsFullRescan` flag raised when FSEvents reports dropped/coalesced events. The C callback reads only a heap box, never the watcher, so the watcher may be stopped or released from any thread, including its own handler | CoreServices |
| `GitIgnoreChecker` / `DirectoryScanner` | Which paths are git-ignored: one `git check-ignore -z --stdin` per directory scan, no cache (a changed `.gitignore` triggers a rescan of every tracked directory). Not a git repo → nothing ignored | `git` CLI |
| `FileIconProvider` | Icon per node: `NSWorkspace.icon(for: UTType)` keyed and cached by extension; folder open/closed variants | AppKit |
| `ExplorerStateStore` | Persist/restore per-root expanded paths, selection, scroll offset, and the two visibility toggles in `UserDefaults` (`unpeel.explorer.*`), bounded to the 50 most recent roots | UserDefaults |
| `ExplorerViewModel` | `@MainActor ObservableObject`. Owns the model, loader, watcher, ignore rules, state store. Public surface: published `context`, `model`, `rootError`, `selection`, `filter`, `restoreToken`; `setContext(_:)`, `expand(_:)`, `collapse(_:)`, `collapseAll()`, `refresh()`, `retry()`, `handleChange(_:)`, `reveal(_:)`, `setFilter(_:)`, `persistState()`. All paths are `String`s. Loads are guarded by a context generation and a per-directory request token; persistence is suppressed from the moment a root starts opening until its saved state has been replayed | all of the above |
| `ExplorerOutlineView` | `NSViewRepresentable` wrapping `NSScrollView` + `NSOutlineView`, with data source/delegate that diff-apply model changes (`insertItems`/`removeItems`/`reloadItem`) so expansion and selection survive refreshes | AppKit, view model |
| `ExplorerPanelView` | SwiftUI shell: header, `⋯` menu, empty/error states, the outline view | view model |
| `ExplorerActionHandler` (protocol) | Intents the library cannot perform itself: `canSendToAgent`, `openFile(path:)` (open-with rules, added 2026-09-22), `openInEditor(path:)`, `sendPathToAgent(path:)`. Implemented by the app | — |
| `ExplorerContext` (value) | `.none`, `.remote`, `.local(root: String, projectRoot: String)` | — |

`ExplorerPalette` (a small struct of `NSColor`s/fonts) is injected by the app
from `Theme` so the library never imports the app's theme code but still
matches the sidebar's typography (13 pt row labels) and light/dark handling.

### 3.3 Touchpoints in existing files (the complete list)

1. `Package.swift` — add the `UnpeelExplorer` target, its test target, and
   the app target's dependency on it.
2. `Views/RootView.swift` — now only passes `cache` to `SidebarView`. The
   explorer column (and its resize handle) was removed by the sidebar-sections
   change (`2026-09-23-sidebar-sections-design.md`); the explorer is a section
   of the left sidebar.
3. `AppDelegate.swift` — one View-menu item ⌘⇧E. Originally a plain "Show
   Explorer" toggle; replaced by the sidebar-sections change
   (`2026-09-23-sidebar-sections-design.md`): ⌘⇧E now reveals and focuses the
   EXPLORER section, or collapses it when the tree already has focus, titled
   "Show Explorer" / "Hide Explorer" accordingly.
4. `UnpeelStore.swift` — **no edits.** Visibility/width persistence originally
   lived in a new `ExplorerPanelState` object (new file). Removed by the
   sidebar-sections change: section visibility, collapse and heights live in
   `SidebarSectionLayoutStore` (`AppDefaults`, key
   `unpeel.sidebarSections.layout`).

New app-target files: `Views/ExplorerPanelHost.swift` (adapter + action
handler). `ExplorerPanelState.swift` was removed by the sidebar-sections
change (replaced by `Views/SidebarSections/`).

Added 2026-09-22 by `2026-09-22-markdown-preview-pane-design.md` (every
edited block marked `// Fork-only: markdown preview pane`):

5. `Package.swift` — the `swift-markdown` dependency (and its
   `Package.resolved` pin), the `UnpeelMarkdownPreview` target and test target.
6. `PaneLayoutState.swift` — the transient `.markdownPreview` leaf and its
   grouping rules; `DurablePaneNode` and the protocol fixture untouched.
7. `UnpeelStore.swift` — `openMarkdownPreview`, `markdownPreviewProjectRoot`,
   the `validatedPaneGroup` arm.
8. `Views/TerminalPaneView.swift` — the preview pane's render branch and menu.
9. `docs/agents/clients/panes.md` — one paragraph on the transient leaf.

Added 2026-09-23 by `2026-09-23-sidebar-sections-design.md` (every edited
block marked `// Fork-only: sidebar sections`):

10. `Views/SidebarView.swift` — the section stack hook (PROJECTS / EXPLORER
    replace the list area); the Finder-folder drop, session-drop catch-all
    and workspace swipe monitor scoped to PROJECTS; the `SidebarListFadeMask`
    ramp height; the row-reveal top occlusion.
11. `Views/SidebarWorkspaceDots.swift` — `SidebarListPageMetrics.topInset`
    and the pooled page's fade ramp.
12. `Views/SidebarSessionDrag.swift` — the detached drag's press band: no
    top occlusion (the list no longer scrolls under the titlebar; the fade
    only dims rows).

### 3.4 Data flow

**Context.** `ExplorerPanelHost` observes `store.selectedSession` and
`store.selectedHostScope` and computes:

- `selectedHostScope != .local` → `.remote`
- no session → `.none`
- else root = `session.worktreePath` if non-empty, otherwise
  `store.displayProjectsByID[session.projectID]?.path`, otherwise
  `store.paneWorkingDirectory(for:)`; `projectRoot` = the project path.

It calls `viewModel.setContext(_:)` only when the value changes.

**Loading.** Lazy, one directory at a time. `setContext` loads the root, then
re-expands the persisted expanded paths breadth-first, skipping any that no
longer exist. Expanding a folder marks it `loading`, calls `DirectoryLoader`
on a background task, then `replacingChildren`. A load that finishes after
the root changed, or after its folder stopped being tracked, is discarded
(generation token). A merely collapsed folder keeps its contents so it keeps
refreshing and re-expands instantly.

**Refresh.** `FileSystemWatcher` reports changed directories. For each one
that is currently **loaded** in the model, the view model reloads just that
directory and diffs children by name, so unrelated expansion/selection state
is untouched. Changes under unloaded folders are ignored. A changed
`.gitignore` rescans every tracked directory.

**Filtering.** Two independent toggles, both default off (VS Code shows
dotfiles by default, but agent projects are dominated by `.git`,
`node_modules`, build output): *Show Hidden Files* (dotfiles; `.git` stays
hidden regardless) and *Show Git-Ignored Files*. When shown, ignored entries
render dimmed, as in VS Code.

### 3.5 Safety and error handling

- **Confinement.** Every path the explorer reads or (Phase 2) writes must
  resolve, after symlink resolution, inside the current root. Symlinked
  directories are listed and can be expanded only if their target is inside
  the root; otherwise they show as a non-expandable link with a tooltip.
- **Unreadable directories** become a `failed` node showing the localized
  error inline; the rest of the tree is unaffected.
- **Root disappears** (worktree removed, volume ejected) → error empty state
  with Retry; the watcher is torn down and rebuilt on retry.
- **Huge directories.** `NSOutlineView` virtualises rows. Directory reads are
  off-main. A directory over 10,000 entries loads the first 10,000 and adds a
  trailing "… N more items not shown" row, so a pathological folder cannot
  freeze the UI.
- **`git` missing or failing** → `GitIgnoreChecker` degrades to "nothing ignored"
  and logs once; never blocks listing.
- No error is swallowed silently: user-facing failures surface in the panel,
  everything else goes to the app's existing logging.

## 4. Phases

Each phase is its own plan → TDD implementation → verification in the running
"Unpeel Dev" app → code review cycle. Phases 2–4 each get a short addendum
spec before their plan, because details depend on what Phase 1 teaches us.

### Phase 1 — Core tree (this spec is complete for Phase 1)

Everything in §2–§3 not marked Phase 2+: the `UnpeelExplorer` target, panel
column + toggle + resize, lazy tree, icons, keyboard navigation, type-select,
FSEvents auto-refresh, hidden/ignored toggles, state persistence per root,
Quick Look, open in editor, reveal in Finder, copy path, send path to agent,
drag a row onto a terminal, empty/error states.

Done when: all Phase 1 unit tests pass; `clients/native/test-native.sh` still
passes; and in the dev app, against a real project, the tree loads, expands,
survives session switches with state restored, updates within about a second
of an agent creating/deleting files, and dragging a file onto a terminal
pastes its path.

### Phase 2 — File operations

`FileOperations` service (create file/folder, rename, duplicate, move, copy,
trash via `FileManager.trashItem`) with every operation registered on an
`UndoManager`; inline rename and inline "new file" rows with VS Code's
validation (empty name, `/`, name collision, leading/trailing space warning);
multi-select; drag-to-move / ⌥-drag copy inside the tree with
spring-loaded folders; drop from Finder; cut/copy/paste via `NSPasteboard`
file URLs; collision prompt (Replace / Keep Both / Cancel). All writes pass
the confinement check in §3.5.

#### External drops (Finder and other apps → explorer)

The outline view registers for `.fileURL` drags from outside the app.

- **Default is copy**, matching VS Code and the safest choice: the source is
  never altered unless the user asks. The cursor shows the green ＋ badge.
- **⌘ held = move** (Finder's modifier for "move instead of copy"); the badge
  disappears to show it. ⌥ is accepted as an explicit copy. The operation is
  re-evaluated live as modifiers change during the drag
  (`validateDrop` returns `.copy` or `.move`).
- **Drop targets:** a folder row → into that folder; a file row → into that
  file's parent folder (the parent highlights, not the file); empty space
  below the rows → into the root. Hovering a collapsed folder for ~0.7 s
  spring-loads it open.
- **Multiple files and whole folders** are accepted in one drop; folders copy
  recursively.
- **Collisions** prompt once per drop: Replace / Keep Both (`name copy.ext`) /
  Skip, with "Apply to all".
- **Progress and cancel:** copies run off the main thread; a drop larger than
  ~50 MB or 200 items shows a progress row in the panel header with Cancel. A
  cancelled or failed copy removes its partial output.
- **Undo:** ⌘Z after a copy trashes the copies; after a move it moves the
  items back to where they came from.
- **Safety:** the *destination* must pass the §3.5 confinement check. The
  *source* may be anywhere the user can read. Dropping a folder into itself or
  a descendant is refused. A move across volumes is performed as copy-then-
  delete, deleting the source only after the copy is verified complete.
- After the drop, the new items are selected and revealed in the tree.

### Phase 3 — Git decorations

`GitStatusProvider` runs `git status --porcelain=v2 -z` (debounced on watcher
events and on `.git/index` changes), maps entries to M / A / U / D / R / C
(conflict) / ignored, colours and badges rows with VS Code's palette, and
propagates a dot + colour to ancestor folders. Works per root, so a worktree
shows its own status.

### Phase 4 — Polish

Compact folders (single-child folder chains rendered as `a/b/c`, on by
default as in VS Code); file nesting (e.g. `package.json` ▸ lockfiles) with
VS Code's default patterns; a filter field (⌥⌘F, fuzzy, highlights matches);
"reveal the file the agent just touched" using the existing clickable-path
detection; sort-order option (default / modified / type).

## 5. Testing

- **Unit (XCTest, `UnpeelExplorerTests`)** against real temporary
  directories, no mocks of the filesystem: `DirectoryLoader` sort order,
  hidden detection, symlink confinement, unreadable directory, 10k cap;
  `FileTreeModel` reducers (immutability asserted — the input model is
  unchanged after every reducer); child diffing preserves expanded
  descendants; `DirectoryScanner` against a temp git repo and a non-repo;
  `FileSystemWatcher` sees create/delete/rename within a timeout;
  `ExplorerStateStore` round-trip and the 50-root bound; `ExplorerViewModel`
  context switching, stale-load discarding, state restore.
- **Context derivation** (app target): the pure function mapping
  (host scope, session, project) → `ExplorerContext`, including the
  worktree-over-project rule and the remote case.
- **Outline view** data source/delegate tested headlessly by instantiating
  `NSOutlineView` without a window and asserting row counts and item
  identities after model changes.
- **Runtime verification** (required before any phase is called done): build
  and launch "Unpeel Dev" with `bun run dev:native:blank` (throwaway
  `UNPEEL_HOME`, so the installed `/Applications/Unpeel.app` and its live
  sessions are never touched), exercise the done-criteria by hand/automation,
  and capture screenshots.
- **Regression gate:** `clients/native/test-native.sh` and `swift build` stay
  green. Rust and protocol suites are untouched by this work and are not part
  of the gate.
- Coverage target: ≥ 80% of `UnpeelExplorer` lines, **excluding** the three
  window-only view files (`ExplorerOutlineView`, `ExplorerPanelView`'s body,
  `ExplorerNSOutlineView`'s Quick Look plumbing), which are covered by the
  windowed XCTest harnesses and the runtime checklist instead. Phase 1 as
  built: 73% raw, ≈ 88% with the exclusion (see the verification log).

## 6. Risks

| Risk | Mitigation |
|---|---|
| Upstream merges conflict in `RootView.swift` | One small, clearly delimited insertion; everything else in new files |
| `NSOutlineView` diffing bugs lose expansion/selection | Item identity = standardized path string; reload only changed parents; covered by headless outline tests |
| FSEvents storms while an agent runs `npm install` | 150 ms coalescing; only loaded directories reload; ignored folders stay collapsed by default |
| Dev build interferes with the user's real Unpeel | Always verify with the blank-home dev script; never quit or signal the installed app |
| Trademark | No distribution in scope; flagged in §1 |

## 7. Phase 1 as built — what Phase 2 must know

Phase 1 is implemented on `feat/native-file-explorer`. The plan's code samples
were superseded in many places by review-driven fixes; the code and this
section are authoritative, the plan's samples are not. Evidence:
`docs/superpowers/verification/2026-09-21-explorer-phase1.md`.

- **Root follows the selected session only.** Following pane focus was tried
  and rejected: re-rooting tears down the watcher and rescans, so clicking
  between panes in different worktrees rebuilt the tree each time, and focus
  also covers the right-hand project panel. Pane focus decides only where
  "Send Path to Agent" pastes.
- **Session selection publishes separately.** `UnpeelStore.objectWillChange`
  does not fire on a plain session switch; the host view also observes
  `SessionSelectionState`.
- **Entry lookup is O(1).** `DirectoryListing` carries a path index; anything
  that resolves rows per-row (rendering, expansion sync, menus) must go
  through it. A linear scan here hung the app on a 10,000-entry folder.
- **The outline's single column is fitted in `layout()`.** AppKit re-tiles the
  column to a content-derived width on every reload; without the fitter,
  labels collapse to zero width.
- **`.git`** is refused at three places: listing, expansion, and reveal.
- **Row identity** is one `ExplorerItem` per path, kept across reloads and
  filter changes; note rows derive their text live.
- **Watcher safety** rests on design review and deterministic tests:
  ThreadSanitizer does not run on this toolchain (Xcode 26.3).

### Phase 2 backlog carried from Phase 1 reviews

- Coalesce reload chains and skip collapsed directories on refresh: each
  FSEvents batch starts its own sequential reload, one `git check-ignore`
  process per directory. Decide this before Phase 3 adds git-status polling
  to the same path.
- `ExplorerContext.projectRoot` is unused but participates in equality.
- `viewModel.selection` can be a superset of the outline's visible selection
  (paths under a collapsed parent) — resolve with multi-select.
- `items`/`childCache` and `loadTokens` grow until the root changes.
- `DirectoryListing` equality is O(entries) per `apply`; a version stamp
  would make it O(1).
- `git` is resolved through `/usr/bin/env`; probe once and cache "unavailable".
- Log, rather than drop, a failed state save and a failed `git` stdin write.
- Upstream divergence: "Open" on a file with no plugin rule resolves the
  editor via `preferredCodeEditor()` (native override ?? "code"), while
  "Open in Editor" uses `codeEditor` (native override ?? `app-state.json`
  `code_editor` ?? "code"); a user who set `code_editor` only in
  `app-state.json` gets different editors from the two adjacent items.
  Fixing it means touching `UnpeelStore.swift`.
- Multi-select Open / ⌘↓ opens one plugin pane per selected file with no
  bound; consider a confirmation above ~5 files.
- Store a note row's directory on the item instead of recovering it from the
  path; poll instead of a fixed budget in the hosted rendering test; add
  root/filter-change stages to the 10k performance test; test the scroll
  observer's teardown; cache `resolvedContext`'s session lookup.
- Keep saved expansions under a transiently failed ancestor.
- **Unexplained, not reproduced:** a root's saved expansion was once found
  empty after launching a rebuilt app whose new Host binary replaced the
  running dev Host (see the verification log, §6). If it recurs, log every
  `ExplorerStateStore.save` with the root, the counts and the generation.
- From the closing review: check `FSEventStreamStart`'s result (today `start()`
  proves only that the stream was created); clear the Quick Look override on a
  root change; read the FSEvents flags before the empty-paths guard; note that
  `RootChanged` needs `WatchRoot`; make the watcher tests' second bursts
  assert their writes succeeded; drop the dead default line-break mode in
  `makeCell`.
