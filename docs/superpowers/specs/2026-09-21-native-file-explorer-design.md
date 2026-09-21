# Native File Explorer for the Mac app — Design

Date: 2026-09-21
Status: approved direction; awaiting spec review
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
- Any change to the Host, the Host protocol, `protocol/`, the pane-layout
  contract, or App Kit's `unpeel.ui/1` contract.
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
  New File, New Folder, Refresh, Collapse All, Show Hidden Files, Show
  Git-Ignored Files.
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
| Double-click file | Open in configured editor (`UnpeelStore.openInEditor(path:)`) |
| ⌘-click / ⇧-click | Toggle / range multi-select (Phase 2) |
| ↑ ↓ | Move selection |
| → | Expand folder; if expanded, move to first child |
| ← | Collapse folder; if collapsed or a file, move to parent |
| Enter | Rename (Phase 2) |
| Space | Quick Look the selection |
| ⌘↓ | Open file / expand folder |
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
Copy Path, Copy Relative Path, Refresh, Collapse.
Phase 2 adds: New File…, New Folder…, Rename…, Duplicate, Cut, Copy, Paste,
Move to Trash.

"Send Path to Agent" pastes the project-relative, shell-quoted path into the
selected session's terminal without pressing Enter — the same result as
dragging the row onto that terminal.

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
└───────────────────────────┘              │ FileTreeModel  FileNode     │
                                           │ DirectoryLoader             │
                                           │ FileSystemWatcher (FSEvents)│
                                           │ IgnoreRules   FileIconProvider
                                           │ ExplorerStateStore          │
                                           │ (P2) FileOperations         │
                                           │ (P3) GitStatusProvider      │
                                           └─────────────────────────────┘
```

### 3.2 Units

Each unit has one purpose and is testable alone.

| Unit | Responsibility | Depends on |
|---|---|---|
| `FileNode` | Immutable value: `url`, `name`, `kind` (file/directory/symlink→kind), `isHidden`, `isIgnored`, child state (`unloaded` / `loaded([FileNode])` / `failed(String)`) | — |
| `DirectoryLoader` | Read **one** directory off the main thread → sorted `[FileNode]` (folders first, then `localizedStandardCompare`, matching VS Code's default). Never follows a directory symlink out of the root | FileManager |
| `FileTreeModel` | Pure, immutable tree state + reducers: `expanding`, `collapsing`, `replacingChildren`, `applyingChanges`. Every reducer returns a new model; no in-place mutation | `FileNode` |
| `FileSystemWatcher` | One FSEvents stream on the root; coalesces events (150 ms) into a set of changed directory URLs | CoreServices |
| `IgnoreRules` | Which paths are git-ignored: `git check-ignore --stdin` batched per loaded directory, cached, invalidated when a `.gitignore` changes. Not a git repo → nothing ignored | `git` CLI |
| `FileIconProvider` | Icon per node: `NSWorkspace.icon(for: UTType)` keyed and cached by extension; folder open/closed variants | AppKit |
| `ExplorerStateStore` | Persist/restore per-root expanded paths, selection, scroll offset, and the two visibility toggles in `UserDefaults` (`unpeel.explorer.*`), bounded to the 50 most recent roots | UserDefaults |
| `ExplorerViewModel` | `@MainActor ObservableObject`. Owns the model, loader, watcher, ignore rules, state store. Public surface: `setContext(_:)`, `toggle(_:)`, `select(_:)`, `refresh()`, `collapseAll()`, `reveal(_:)` | all of the above |
| `ExplorerOutlineView` | `NSViewRepresentable` wrapping `NSScrollView` + `NSOutlineView`, with data source/delegate that diff-apply model changes (`insertItems`/`removeItems`/`reloadItem`) so expansion and selection survive refreshes | AppKit, view model |
| `ExplorerPanelView` | SwiftUI shell: header, `⋯` menu, empty/error states, the outline view | view model |
| `ExplorerActionHandler` (protocol) | Intents the library cannot perform itself: `openInEditor(URL)`, `sendPathToAgent(URL)`. Implemented by the app | — |
| `ExplorerContext` (value) | `.none`, `.remote`, `.local(root: URL, projectRoot: URL)` | — |

`ExplorerPalette` (a small struct of `NSColor`s/fonts) is injected by the app
from `Theme` so the library never imports the app's theme code but still
matches the sidebar's typography (13 pt row labels) and light/dark handling.

### 3.3 Touchpoints in existing files (the complete list)

1. `Package.swift` — add the `UnpeelExplorer` target, its test target, and
   the app target's dependency on it.
2. `Views/RootView.swift` — insert the explorer column into the `appLayout`
   `HStack` between the sidebar `ZStack` and `ContentArea`, with a width
   computed the same way as `shownProjectSidebarWidth`, plus a resize handle
   modelled on the existing sidebar handle.
3. `AppDelegate.swift` — one View-menu item, "Show Explorer" ⌘⇧E.
4. `UnpeelStore.swift` — **no edits.** Visibility/width persistence lives in a
   new `ExplorerPanelState` object (new file), using `AppDefaults` like
   `sidebarCollapsed` does.

New app-target files: `Views/ExplorerPanelHost.swift` (adapter + action
handler), `ExplorerPanelState.swift`.

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
its folder was collapsed or the root changed is discarded (generation token).

**Refresh.** `FileSystemWatcher` reports changed directories. For each one
that is currently **loaded** in the model, the view model reloads just that
directory and diffs children by name, so unrelated expansion/selection state
is untouched. Changes under unloaded folders are ignored. A changed
`.gitignore` invalidates `IgnoreRules` and re-filters loaded directories.

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
- **`git` missing or failing** → `IgnoreRules` degrades to "nothing ignored"
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
  descendants; `IgnoreRules` against a temp git repo and a non-repo;
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
- Coverage target: ≥ 80% of `UnpeelExplorer` lines.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Upstream merges conflict in `RootView.swift` | One small, clearly delimited insertion; everything else in new files |
| `NSOutlineView` diffing bugs lose expansion/selection | Item identity = standardized path string; reload only changed parents; covered by headless outline tests |
| FSEvents storms while an agent runs `npm install` | 150 ms coalescing; only loaded directories reload; ignored folders stay collapsed by default |
| Dev build interferes with the user's real Unpeel | Always verify with the blank-home dev script; never quit or signal the installed app |
| Trademark | No distribution in scope; flagged in §1 |
