# Sidebar sections: Projects and Explorer in one left panel

Status: approved design 2026-09-23 (brainstorming); not yet planned.
Fork-only. Amends `2026-09-21-native-file-explorer-design.md`, which placed
the explorer in its own column between the sidebar and the content pane.

## 1. Goal

The left sidebar becomes a VS Code-style stack of sections: **PROJECTS** on
top, **EXPLORER** below, and later **GIT HISTORY** (not part of this work).
The separate explorer column goes away. Every section has a header, can be
collapsed to that header, resized against its neighbour with a draggable
divider, and hidden; a visible horizontal separator divides sections.

## 2. Layout

Top to bottom inside the sidebar:

1. The traffic-light strip (`SidebarTopGlassOverlay`), unchanged — still a
   window drag surface (`WindowDragArea` → `SystemWindowDrag`, so edge
   tiling keeps working).
2. **PROJECTS** section: header row, then today's project tree
   (`projectTreePanel` inside `SidebarListPage` + `SidebarWorkspaceCarousel`)
   with its workspace-page sliding, session drag-and-drop, and Finder-folder
   drop intact. Header actions (trailing): **Add Project** (only when
   `store.canPickProjectFolder`, same as the footer "+"), and a `…` menu
   with **Collapse All Folders** (`store.collapseAllSidebarFolders()`).
3. Separator: a 1 pt line in the sidebar divider colour; the hit area for
   dragging is 6 pt tall centred on it, showing the vertical resize cursor.
   Present between every pair of visible sections; draggable only when both
   neighbours are expanded.
4. **EXPLORER** section: header "EXPLORER" followed by the tree's root folder
   name in secondary colour (e.g. `EXPLORER  unpeel`); the `…` menu carries
   today's Refresh, Collapse All, Show Hidden Files, Show Git-Ignored Files.
   Content: the existing explorer tree (`ExplorerPanelHost`) minus its own
   header row.
5. The footer (`SidebarFooter` + workspace dots), unchanged, at the very
   bottom.

Header row: 22 pt tall, chevron (right = collapsed, down = expanded),
uppercase 11 pt semibold title in secondary text colour, actions revealed on
hover of the header (always visible for the `…` menu while its menu is open).
Clicking anywhere on the header outside an action toggles collapse.

## 3. Behaviour

- **Collapse / expand.** A collapsed section occupies only its header. Its
  height weight is kept; the expanded sections share the freed height in
  proportion to their weights. Expanding restores its weight and the others
  shrink proportionally. Height changes animate (`SidebarMotion.slide`-like,
  scoped to the sidebar subtree — never a window-wide transaction).
- **Divider drag.** Moves height between the two adjacent expanded sections
  only, clamped so neither drops below its minimum height (PROJECTS 80 pt,
  EXPLORER 120 pt, content only, excluding the header). The result is stored
  as weights when the drag ends.
- **Hide / show.** Right-click on any header opens a menu listing every
  section with a checkmark; unchecking hides that section (header and all).
  The last visible section's item is disabled.
- **All collapsed.** Headers stack at the top; the remaining space below is
  empty sidebar background above the footer.
- **⇧⌘E** (View menu item titled "Show Explorer" / "Hide Explorer" as
  today):
  - if the tree has keyboard focus and EXPLORER is expanded → collapse
    EXPLORER, move focus to the active terminal pane;
  - otherwise → un-collapse the sidebar if collapsed, show EXPLORER if
    hidden, expand it if collapsed, and make the outline view first
    responder.
  The title reads "Hide Explorer" exactly when the first branch would apply.
- **Sidebar collapse** (existing toggle) hides the whole stack; reopening
  restores the same layout.
- **Settings** (`store.settingsVisible`): the stack is replaced by
  `SettingsSidebarPanel` with the existing slide, exactly as the project
  list is today.
- **Workspace carousel.** Only the PROJECTS content slides between workspace
  pages. `SidebarWorkspaceSwipeMonitor` moves from the whole sidebar's
  background onto the PROJECTS content, so a horizontal trackpad swipe over
  EXPLORER never switches workspace.
- **Finder-folder drop** (add project) moves onto the PROJECTS content only,
  so drops onto EXPLORER (Phase 2 drag-in copy) are never captured by it.
- **Explorer content** is unchanged: it follows the selected session, shows
  the same empty-state messages (none / remote Host), and keeps its saved
  expansion state. It is mounted only while EXPLORER is visible and
  expanded, so a collapsed or hidden explorer holds no FSEvents stream.
- **Row fade under the header.** The project rows currently scroll under the
  traffic-light glass with a 48 pt top clearance
  (`SidebarListPageMetrics.topInset`, shared by both carousel pages) and
  dissolve through `SidebarListFadeMask`. With the stack, the PROJECTS header
  sits below the traffic-light strip, and the rows scroll under the header
  instead: the carousel's top clearance becomes a small constant (the header
  already provides the separation), applied identically to both carousel
  pages, and the fade ramp is aligned to the header's bottom edge. Verified
  at runtime during a workspace swipe (the pooled page must not jump on
  commit).
- **Short window.** If the available height is below the sum of expanded
  minimums, the bottom-most expanded section is compressed first (its
  content scrolls); nothing ever overlaps the footer.

## 4. Persistence

One Codable record, stored in `AppDefaults.shared` (so a dev
`UNPEEL_HOME` never touches the daily layout) under
`unpeel.sidebarSections.layout`:

```swift
struct SidebarSectionLayout: Codable, Equatable {
    var version: Int                 // 1
    var order: [SidebarSectionID]    // [.projects, .explorer]
    var hidden: Set<SidebarSectionID>
    var collapsed: Set<SidebarSectionID>
    var weights: [SidebarSectionID: Double]   // fractions, normalised over expanded
}
```

- Defaults (first launch, or undecodable / unknown-version record): both
  visible, both expanded, weights PROJECTS 0.4, EXPLORER 0.6.
- Weights are fractions of the height available to expanded sections, so a
  window resize keeps proportions.
- Unknown section ids in a record are dropped; ids missing from a record are
  appended visible and expanded with the default weight (this is how GIT
  HISTORY will arrive later without a migration).
- Migration: the old explorer-column keys `unpeel.explorer.visible` and
  `unpeel.explorer.width` are removed on first launch of this build.
  `unpeel.explorer.visible == false` is **not** carried over — the explorer
  starts visible in the sidebar.

## 5. Code

### New fork-only files (`UnpeelNative` target, `Views/SidebarSections/`)

- `SidebarSectionID.swift` — `enum SidebarSectionID: String, Codable,
  CaseIterable { case projects, explorer }`.
- `SidebarSectionLayout.swift` — the record above plus pure functions, no
  SwiftUI: `heights(available:headerHeight:minimums:) -> [ID: CGFloat]`,
  `resizing(divider:between:and:by:available:minimums:) -> Self`,
  `toggledCollapse(_:)`, `settingHidden(_:_:)` (refuses to hide the last
  visible), `normalised()`, `static func decode(_ data: Data?) -> Self`
  (falls back to defaults). Returns new values; never mutates in place.
- `SidebarSectionLayoutStore.swift` — `@MainActor final class ObservableObject`
  owning the current layout, loading/saving it through `AppDefaults.shared`,
  and performing the one-time removal of the old column keys.
- `SidebarSectionStack.swift` — the generic SwiftUI container: takes
  `[SidebarSectionDescriptor]` (id, title, optional subtitle, header
  actions, header menu, content builder, minimum height) and the store;
  draws headers, separators, drag dividers and content frames; knows
  nothing about projects or files.
- `SidebarSectionHeader.swift`, `SidebarSectionDivider.swift` — the header
  row and the separator/drag handle.
- `ExplorerFocusCommand.swift` — the pure ⇧⌘E decision
  (`func explorerCommand(treeFocused:explorerExpanded:explorerHidden:sidebarCollapsed:) -> ExplorerCommandAction`)
  and the menu-title rule.

### Changed library code (`UnpeelExplorer`, fork-only target)

- `ExplorerPanelView`: gains a `showsHeader: Bool` (default `true` for
  compatibility with its tests); the sidebar passes `false` and renders the
  title and `…` menu through the section header. The menu's contents move
  to a public `ExplorerPanelMenu` view so both places use one definition.
- `ExplorerViewModel` / outline: a public way to make the outline view first
  responder and to ask whether it currently is (for ⇧⌘E).

### Upstream files edited (each block marked "Fork-only: sidebar sections")

- `Views/SidebarView.swift` — the `else` branch of the list-area `ZStack`
  renders `SidebarSectionStack` with PROJECTS (the existing
  `SidebarListPage { projectTreePanel }` + carousel modifier) and EXPLORER
  (`ExplorerPanelHost`) as sections. The `.onDrop(of: [.fileURL]…)` folder
  drop, its highlight overlay, and the `SidebarWorkspaceSwipeMonitor`
  background move onto the PROJECTS content.
- `Views/SidebarWorkspaceDots.swift` — `SidebarListPageMetrics.topInset`
  becomes the small in-section clearance (both carousel pages keep sharing
  it).
- `Views/RootView.swift` — remove the explorer column, its width handle and
  `explorerLeadingInset`; restore upstream's content leading padding
  expression.
- `AppDelegate.swift` — ⇧⌘E and its `validateMenuItem` title go through
  `ExplorerFocusCommand`.
- `ExplorerPanelState.swift` (fork-only) — deleted; its role passes to the
  layout store.

The native-file-explorer spec's §3.3 touchpoint list is updated with the
two newly edited upstream files (`SidebarView.swift`,
`SidebarWorkspaceDots.swift`).

## 6. Testing

- **Unit (`UnpeelNativeTests`)** — `SidebarSectionLayoutTests`: default
  layout; heights for 1 and 2 expanded sections; collapse hands height to
  the other section and expand restores it; divider drag clamps at both
  minimums; hiding the last visible section is refused; normalisation after
  hide/collapse; decode of nil, garbage, unknown version, unknown ids, and a
  record missing a known id; short-window compression order.
  `ExplorerFocusCommandTests`: every branch of the ⇧⌘E decision and the
  menu title.
- **Unit (`UnpeelExplorerTests`)** — `ExplorerPanelView` without header
  still shows the tree / empty states; the shared menu has the four items.
- **Gate** — `clients/native/test-native.sh`.
- **Runtime (dev build, `UNPEEL_HOME=~/unpeel-dev-explorer-home`,
  screenshots in `docs/superpowers/verification/sidebar-sections/`)** —
  1. first launch: 40/60 split, separator visible;
  2. divider drag, clamped at both minimums;
  3. collapse / expand each section; all collapsed;
  4. hide / show via header right-click; last one cannot be hidden;
  5. two-finger swipe over PROJECTS switches workspace with no jump on
     commit; over EXPLORER does nothing;
  6. Finder folder dropped on PROJECTS adds a project;
  7. session drag-reorder in PROJECTS still works;
  8. rows fade under the PROJECTS header while scrolling;
  9. ⇧⌘E from each state (sidebar collapsed, explorer hidden, collapsed,
     expanded unfocused, expanded focused);
  10. Settings open/close; sidebar collapse/expand;
  11. quit and relaunch keeps the layout;
  12. window drag from the traffic-light strip still edge-tiles;
  13. explorer double-click / context menu / markdown preview still work.

## 7. Out of scope

- GIT HISTORY (a later spec; it arrives as a third `SidebarSectionID`).
- Reordering sections by drag, or moving sections to other panels.
- Remote-scope explorer content (unchanged: empty-state message).
