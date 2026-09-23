# Native Markdown preview pane — Design

Date: 2026-09-22
Status: approved 2026-09-22; implemented (evidence in
`docs/superpowers/verification/2026-09-22-markdown-preview-pane.md`)
Repo: `alimazid/unpeel` fork, branch `feat/markdown-preview-pane`
Amends: `2026-09-21-native-file-explorer-design.md` (§3.3 touchpoints, non-goal
"no change to the pane-layout contract") and
`2026-09-22-explorer-open-with-rules-design.md` (Markdown now opens in the
preview by default; the plugin is the editor).

## 1. Goal

Opening a Markdown file from the explorer shows a **rendered, read-only
preview** — what VS Code's "Open Preview" shows — as a native pane in the
split layout beside the session, where an Unpeel plugin pane appears today.
Editing stays one click away in Unpeel's Markdown plugin pane.

### Decisions already made

| Decision | Choice |
|---|---|
| Where the preview lives | A native pane in the split layout (option C), not a window or a terminal render |
| Reuse | One preview pane per file; opening a file already previewed in that group focuses its pane |
| Edit path | An **Edit** button in a slim toolbar row at the top of the pane body opens the Markdown plugin pane (through the open-with rules a terminal ⌘-click uses); VS Code stays in the explorer context menu |
| Persistence | Transient in v1: preview panes are stripped before the layout is persisted (like the launcher pane); durable restore is a later addendum |
| Renderer | `WKWebView` fed by `swift-markdown` (GitHub-flavoured) → HTML with a bundled stylesheet |

### Non-goals

- Restoring preview panes after relaunch (v1 is transient).
- Changing what terminal ⌘-click does with `.md` (still the plugin).
- Syntax highlighting inside fenced code blocks; MathJax/Mermaid.
- iOS, remote Hosts, the TUI. The pane tree is Controller-side state and never
  reaches the Host or iOS (`docs/agents/clients/panes.md`).
- Editing inside the preview.

## 2. Behaviour

- **Open:** double-click, ⌘↓ or context-menu **Open** on a file whose extension
  maps to `text/markdown` in the plugin registry (`md`, `markdown`, `mdown`,
  `mkd`) opens a preview pane to the **right** of the tree's session pane at a
  50/50 split — the same placement as a plugin pane
  (`UnpeelStore.reconcileAppPresentations`, `insertSession(_:beside:at: .right)`).
  If the tree's session is not in a group yet, one is created. Files of every
  other type keep the open-with routing shipped on 2026-09-22.
- **Reuse:** if that group already holds a preview pane for the same canonical
  path, it is focused instead. Different files open separate panes.
- **Header:** the standard pane chrome (`paneHeader`) with the file name as the
  title chip, an **Edit** button, and the standard pane menu. Edit calls
  `UnpeelStore.openClickedFile(_:path:fromSessionID:)` with the group's
  representative session, i.e. the Markdown plugin opens beside the preview
  unless Settings ▸ Open With says otherwise.
- **Close:** ⌘W or the pane menu's close on a focused preview detaches just
  that pane (`terminalPaneCloseAction` already yields `.detachPane` for a leaf
  with no session). A group whose last **session** leaf disappears drops its
  preview leaves with it.
- **Live update:** the pane re-renders when the file changes on disk
  (debounced 150 ms), preserving the scroll position. Deleted or unreadable
  file → the pane body shows "*name* is no longer available" and stays until
  the user closes it (or the file returns, which reloads it). No filesystem
  check runs on the render path: an editor that saves by unlink-then-write
  would otherwise make the pane vanish and reappear (revised 2026-09-22 after
  the Task 4 review).
- **Rendering:** GitHub-flavoured Markdown — headings, paragraphs, emphasis,
  lists, task lists, tables, fenced and indented code, block quotes, thematic
  breaks, links, images, inline HTML escaped (not rendered). Light/dark follows
  the app appearance. Relative links and images resolve against the file's
  folder and are served only from inside the explorer's **project root**
  (realpath-checked); anything outside is refused. `http(s)` links open in the
  default browser; relative `.md` links open a new preview pane in the same
  group — only when the target resolves inside the project root (a link to a
  file outside it is refused at the pane and again in the store, so web
  content can never choose a path the Edit button would open). A group holds
  at most six preview panes.
- **Focus:** clicking a preview makes it the active pane (highlight border).
  ⌥-arrows move between panes as today; the preview takes no first-responder
  handoff (like the launcher pane). Escape in the preview returns focus to the
  session pane of its group.
- **Explorer context menu for markdown files:** Open (preview), Open in
  Markdown Editor (plugin), Open in Editor (external), then the existing items.
  For other files: Open, Open in Editor, … as today.

## 3. Architecture

### 3.1 New library target `UnpeelMarkdownPreview` (fork-only)

`clients/native/UnpeelNative/Sources/UnpeelMarkdownPreview/`, depends on
`swift-markdown` (`https://github.com/swiftlang/swift-markdown`, from 0.9.0)
and WebKit. Imports limited to Foundation, AppKit, SwiftUI, WebKit, Markdown,
os. Never imports app types.

| Unit | Responsibility | Depends on |
|---|---|---|
| `MarkdownHTMLRenderer` | Pure: Markdown source → HTML body string via a `MarkupVisitor`. Escapes text and attribute values; raw HTML blocks/inline are emitted escaped. Task-list items render as disabled checkboxes. Heading ids are slugified for in-page `#anchor` links | `Markdown` |
| `MarkdownPreviewDocument` | Pure: wraps the body in the page template (`<!doctype html>`, `<meta charset>`, bundled CSS inlined, `data-theme` attribute, a small script that reports/restores `scrollY`) | `MarkdownHTMLRenderer` |
| `PreviewResourcePolicy` | Pure: decides whether a requested local path may be served — inside `projectRoot` after `CanonicalPath`-style realpath, regular file, allowed media (images, `.md`) | Foundation |
| `PreviewSchemeHandler` | `WKURLSchemeHandler` for `unpeel-preview://` — serves files approved by `PreviewResourcePolicy`, 404 otherwise; the document's base URL is `unpeel-preview:///<relative dir>/` so relative references resolve here | `PreviewResourcePolicy` |
| `MarkdownFileObserver` | `DispatchSource.makeFileSystemObjectSource` on the file (write, delete, rename, extend), debounced, re-armed after atomic saves (editors replace the inode) | Foundation |
| `MarkdownPreviewWebView` | `NSViewRepresentable` around `WKWebView`; loads the document, restores scroll after reload, routes `http(s)` navigations to `NSWorkspace`, relative `.md` navigations to an `onOpenMarkdown(path)` callback, `data:`/`unpeel-preview:` allowed, everything else cancelled | all above |
| `MarkdownPreviewPaneView` | SwiftUI body used inside the pane: the toolbar row with **Edit**, the web view, the "no longer available" state; the title chip is the app's header. Its `onOpenMarkdown` hop refuses link targets `PreviewResourcePolicy` would not serve | `MarkdownPreviewWebView`, `MarkdownFileObserver`, `PreviewResourcePolicy` |

`CanonicalPath` (realpath) lives in `UnpeelExplorer`; `UnpeelMarkdownPreview`
gets a copy of the 20-line helper rather than a dependency on the explorer.

### 3.2 Pane model (upstream files, fork-only marked edits)

- `PaneLayoutState.swift`
  - `PaneContent.markdownPreview(path: String)`; accessors `markdownPreviewPath`,
    `isTransient` (launcher or preview).
  - `hashStructure` includes the path; `reconcile(candidateGroups:)` keeps
    preview leaves; `DurablePaneGroup.init?` strips them like launchers
    (unchanged schema, no fixture change).
  - `insertPane(_ content: PaneContent, beside sessionID: String, at edge:)`
    generalising `insertSession` (which becomes a wrapper), plus
    `location(ofMarkdownPreview path: String, inGroupOf sessionID:)`.
  - Group rules: preview leaves never count toward `maximumSessionLeafCount`
    or the two-leaf minimum; `reconcile(eligibleSessionIDs:)` removes preview
    leaves from a group that has no remaining session leaf.
- `UnpeelStore.swift`
  - `openMarkdownPreview(path: String, besideSession sessionID: String)`:
    canonicalise, reuse-or-insert via `mutatePaneLayout`, set the active pane.
  - `validatedPaneGroup(containingSession:)`: `.markdownPreview` is kept like
    the launcher (no file check on the render path); the grouping guard counts
    transient leaves.
  - `canCloseActiveTerminalPane` needs no change: it gates on the group's
    representative session being alive, which holds for a focused preview.
  - `markdownPreviewProjectRoot(for sessionID:)`: the session's worktree or
    project path, for `PreviewResourcePolicy`.
- `Views/TerminalPaneView.swift`
  - `PresentedPane.id` and `paneSlot` gain the case; `markdownPreviewPane(_:path:)`
    is modelled on `launcherPane` (same chrome). The Edit button lives in a
    slim toolbar row at the top of the pane body (`MarkdownPreviewPaneView`),
    not in the header: `paneHeader` is upstream code with no trailing slot,
    and adding one would widen the merge surface (decided 2026-09-22).
  - Focus highlighting needs no change: preview leaves always live in a
    group, and the multi-pane branch of `paneIsFocused` already compares pane
    ids.
- `Package.swift`: the dependency, the target, the app's dependency on it.
- `docs/agents/clients/panes.md`: one paragraph on the transient preview leaf.

### 3.3 Explorer wiring (fork-only)

- `ExplorerActionHandler` gains `openMarkdownEditor(path:)` (the plugin) and
  the app's `ExplorerHostActions.openFile` routes markdown extensions to
  `store.openMarkdownPreview(path:besideSession: rootSessionID)`; everything
  else to `openClickedFile` as today. `ExplorerHostActions.openMarkdownEditor`
  calls `openClickedFile` (the plugin is the registry default for
  `text/markdown`).
- `ExplorerOutlineController.MenuAction.openInMarkdownEditor` ("Open in
  Markdown Editor"), shown between Open and Open in Editor when every file
  target is markdown; `perform` calls the handler for markdown targets only.
  The markdown-extension set is one constant, `MarkdownFileTypes.extensions`,
  in `UnpeelExplorer`, mirroring the registry.

### 3.4 Safety

- Files are read with `Data(contentsOf:)` and rendered only when under 4 MB;
  larger files show "too large to preview" with an Open in Editor hint.
- The scheme handler is the only path to local resources: absolute paths,
  `..`, symlinks resolving outside the project root, and non-regular files
  are refused; nothing is ever written.
- `WKWebView` runs with JavaScript enabled only for the bundled scroll script;
  the document is built from escaped text, so file content cannot inject
  script. `allowFileAccessFromFileURLs` stays off; no `file:` base URL.
- The web view is created per pane and torn down with it; no shared process
  pool configuration beyond the default.

## 4. Testing

- `UnpeelMarkdownPreviewTests`: renderer (each GFM construct, escaping of
  `<script>` and attributes, task lists, heading ids); document template
  (theme attribute, CSS inlined once); `PreviewResourcePolicy` (inside root
  ok, `../` out refused, symlink out refused, directory refused, disallowed
  type refused); scheme handler responds 200/404 with correct MIME; observer
  fires on write and on atomic replace, debounced.
- `UnpeelNativeTests`: `PaneLayoutState` — insert preview beside a solo
  session creates a group; insert beside a grouped session splits right;
  reuse by path returns the existing pane; preview leaves stripped by
  `DurablePaneGroup`; group with only preview leaves dissolves; preview leaves
  ignored by the session cap; `hashStructure` differs per path.
  `canCloseActiveTerminalPane` true for a focused preview.
- `UnpeelExplorerTests`: markdown files route to `openMarkdownPreview`, others
  to `openFile`; menu order for markdown vs other files vs mixed sets.
- Runtime (dev build): open → pane beside the session; reopen focuses; second
  file → second pane; Edit → plugin pane appears and typing in it updates the
  preview; ⌘W closes the preview only; closing the session closes its previews;
  delete the file → pane drops; image in a subfolder renders; image outside
  the root does not; theme switch re-styles; relaunch → previews gone,
  session layout intact.

## 5. Risks

- `WKWebView` inside the pane card: Metal terminal surfaces and web views in
  one split have shown flicker on resize in other apps; verify drag-resize
  smoothness at runtime, keep the web view's `drawsBackground` matching the
  card colour.
- `swift-markdown` adds a C target (cmark-gfm) to the build; first build is
  slower. If the package fails to build with this toolchain, fall back to an
  in-repo minimal renderer (headings, lists, code, emphasis, links, images) —
  a design change to be brought back here.
- Upstream merge surface grows by three edited layout files; every edit is
  confined to marked blocks.
