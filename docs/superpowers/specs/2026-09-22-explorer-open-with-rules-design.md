# Explorer: open files through Unpeel's open-with rules

Status: approved 2026-09-22; implemented (evidence in
`docs/superpowers/verification/2026-09-21-explorer-phase1.md` §7). Addendum to
`2026-09-21-native-file-explorer-design.md`, which it amends in §2 and §3.2.

## 1. Goal

Double-clicking a file in the explorer should do what ⌘-clicking that path in
a terminal already does: open it with the plugin Unpeel's rules pick for its
type, so `README.md` opens in the Markdown plugin as a side pane of the
session, while files with no plugin rule still open in the configured editor.
Phase 1 hardwired every open entry point to the editor.

## 2. Behaviour

| Entry point | Phase 1 | Now |
|---|---|---|
| Double-click a file | editor | open-with rules |
| ⌘↓ on a selected file | editor | open-with rules |
| Context menu **Open** (new, first item for files) | — | open-with rules |
| Context menu **Open in Editor** | editor | editor (unchanged; the explicit bypass) |
| Double-click / ⌘↓ on a folder | expand | expand (unchanged) |

Superseded for markdown files the same day by
`2026-09-22-markdown-preview-pane-design.md`: `.md`/`.markdown`/`.mdown`/`.mkd`
now open in the native preview pane; the Markdown plugin is reached through
the context menu's **Open in Markdown Editor** or the preview's **Edit**
button. Every other file type keeps the routing described here.

"Open-with rules" means exactly `UnpeelStore.openClickedFile(_:path:fromSessionID:)`
(`UnpeelStore.swift:10700`), the routine behind a terminal ⌘-click:

1. The path's extension is matched against the plugin registry
   (`protocol/app-registry.json`, via `RemoteAppSummary.mediaType(forPath:in:)`).
   `.md`, `.markdown`, `.mdown`, `.mkd` → `text/markdown` → the Markdown
   plugin, which is `default_for` that selector.
2. A user override from Settings ▸ Open With (`snapshot.openers`) wins over the
   registry default. Plugins disabled for the workspace are never candidates.
3. No rule, or opener `editor` → the editor; opener `system` →
   `NSWorkspace.open`; opener `app:<id>` with the plugin installed → the plugin
   opens as a **side pane attached to the caller session** (Host-side
   `AppPresentationTarget::Panel`; an existing pane for the same app + project
   + file is reused, so double-clicking the same `.md` twice does not open two
   panes).
4. Plugin not installed → Unpeel's own alert: Install / Use Editor / Always
   Use Editor. The explorer adds no prompt of its own.
5. `openClickedFile` returns `false` — either the file no longer resolves
   locally (the watcher removes the row moments later), or, in remote scope
   (where the explorer shows no tree anyway), no plugin claims the type —
   and nothing opens; the explorer logs at `.info`.

The **caller session** is the tree's own session — the selected session
whose root the tree shows (`ExplorerHostActions.rootSessionID`) — never the
focused pane of a split: that pane may belong to another worktree, and the
pane should appear beside the session whose tree the user double-clicked in.
With no such session (context `.none`, when the panel shows no tree anyway)
the explorer falls back to `openInEditor(path:)`.

Multiple selected files + ⌘↓ or **Open** open each file in turn, as Phase 1
did with the editor. Enter is still reserved for Rename (Phase 2).

Remote-Host scope is unchanged: the explorer shows no tree there.

## 3. Code

### `UnpeelExplorer` (library)

- `ExplorerActionHandler` gains `func openFile(path: String)` ("open with
  Unpeel's rules"); `openInEditor(path:)` stays.
- `ExplorerOutlineController.MenuAction` gains `.open` (title "Open"), listed
  before `.openInEditor` for file targets only; `perform` calls
  `actionHandler?.openFile(path:)` for each file target.
- `handleDoubleClick()` and `handleKeyCommand(.open)` call `openFile` instead
  of `openInEditor` for files; directory behaviour unchanged.

### App (`UnpeelNative`)

- `ExplorerHostActions.openFile(path:)`:
  ```swift
  func openFile(path: String) {
      guard let store else {
          openInEditor(path: path)
          return
      }
      switch ExplorerContextResolver.openRoute(sessionID: rootSessionID) {
      case .editor:
          openInEditor(path: path)
      case let .rules(sessionID):
          let match = ClickablePath.Match(path: path, line: nil, column: nil)
          if !store.openClickedFile(match, path: path, fromSessionID: sessionID) {
              logger.info("open declined for \(path, privacy: .private)")
          }
      }
  }
  ```
  `ExplorerContextResolver.openRoute(sessionID:)` is the pure decision behind
  the switch — it returns `ExplorerOpenRoute.editor` or `.rules(sessionID:)`
  from a plain optional, so the session-selection logic is testable without
  `UnpeelStore`.
- No upstream file changes. `ExplorerPanelHost.swift` is fork-only; the two
  upstream files the fork edits (`RootView.swift`, `AppDelegate.swift`) are
  untouched.

## 4. Testing

- `UnpeelExplorerTests` (fake `ExplorerActionHandler` recording calls):
  double-click on a file → one `openFile`, zero `openInEditor`; double-click
  on a folder → no-op in the controller (expansion is the single click's
  job), no handler call; `.open` key command with two
  files selected → `openFile` for each in row order; `menuActions(forTargets:)`
  for a file starts `[.open, .openInEditor, …]`, for a folder contains
  neither; `perform(.open)` and `perform(.openInEditor)` call the matching
  handler member only.
- `UnpeelNativeTests`: `ExplorerHostActions` with no store falls back to
  `openInEditor` without crashing (guards the nil-session path).
- Runtime (dev build, `UNPEEL_HOME=~/unpeel-dev-explorer-home`, Markdown
  plugin linked with `unpeel apps link`): double-click `README.md` → Markdown
  pane beside the tree's session; double-click a `.ts` → editor; **Open in
  Editor** on `.md` → editor; ⌘↓ on `.md` → Markdown pane; second double-click
  on the same `.md` reuses the pane; plugin unlinked → Install / Use Editor
  alert. Evidence appended to
  `docs/superpowers/verification/2026-09-21-explorer-phase1.md` §7.

## 5. Out of scope

- A read-only Markdown reader (Unpeel's Markdown plugin auto-saves edits).
- Changing the registry, the openers, or `openClickedFile` itself.
- Opening from the explorer into a specific pane other than the target
  session's; the Host decides placement.
