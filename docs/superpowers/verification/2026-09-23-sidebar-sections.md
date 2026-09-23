# Sidebar sections — verification evidence

Date: 2026-09-23 · Branch: `feat/sidebar-sections` · Runtime checks at
`22ca444` (dev build) · Spec:
`docs/superpowers/specs/2026-09-23-sidebar-sections-design.md` · Plan:
`docs/superpowers/plans/2026-09-23-sidebar-sections.md`

Environment: macOS 26.6.2, Xcode 26.3 / Swift 6.2.4. Runtime checks ran in the
isolated dev build (`clients/native/dev-blank.sh`,
`UNPEEL_HOME=~/unpeel-dev-explorer-home`, workspace page 2), driven by
synthesized mouse, scroll-wheel and keyboard events posted at the HID tap;
window frames read from the window list; menu titles read through System
Events. The installed `/Applications/Unpeel.app` was not touched.
Screenshots in `sidebar-sections/`.

## 1. Tests

- `clients/native/test-native.sh` at `22ca444`: `Executed 824 tests, with 1
  test skipped and 0 failures` (the skip is upstream's).
- New/changed suites: `SidebarSectionLayoutTests` 19,
  `SidebarSectionLayoutStoreTests` 5, `ExplorerFocusCommandTests` 3,
  `SidebarSectionStackTests` 4, `ExplorerFocusTests` 3,
  `ExplorerSectionModelTests` 2, `ExplorerPanelViewTests` 4 (+2);
  `ExplorerPanelStateTests` (4) deleted with the column.

## 2. Reviews

Six task reviews (plus re-reviews after fixes). Findings fixed during the
run: the plan's stack smoke test asserted nothing (replaced by a test that
counts content builds — collapsed and hidden sections are never built);
divider cursor push/pop balance; a divider drag could overwrite a
concurrent collapse/hide (commit now applies only the resize to the current
layout); stack overflow at tiny heights (clipped); header accessibility
(value + default and named actions); a normal drag end relied only on
`onChange` (restored `onEnded`, idempotent finish); **the shared explorer
view model's teardown ran unconditionally on disappear, so a new host
appearing before the old one disappeared would blank the tree** (fixed with
a claim/release mount token); `focusTree` did not retry a refused first
responder. Remaining Minor items are listed in the ledger for the final
review.

## 3. Runtime checklist

| # | Check | Result |
|---|---|---|
| 1 | First launch of this build | PASS — PROJECTS over EXPLORER, visible separator, ≈40/60 split (`01`) |
| 2 | Drag the divider up, then down, far past the limits | PASS — PROJECTS stops at its 80 pt minimum (`02`), EXPLORER at 120 pt (`03`) |
| 3 | Collapse PROJECTS, then EXPLORER; expand both | PASS — collapsed sections shrink to their header, the other takes the space (`04`, `05`) |
| 4 | Header right-click: hide PROJECTS, try to hide the last one, show it again | PASS — checkmark menu (`06`); with one section left its item is disabled (`07`); showing restores the stack |
| 5 | Horizontal swipe over PROJECTS / over EXPLORER | PASS — over PROJECTS it switched to the other workspace page and back (`08`); over EXPLORER the swipe monitor saw the events but reported them outside its bounds and nothing switched (`09`; confirmed with temporary logging, since removed) |
| 6 | Finder folder dropped on PROJECTS | Not exercised (no synthetic Finder drag); the drop code moved byte-identically, verified in review |
| 7 | Reorder in PROJECTS | PASS for project rows — a project row drag reordered projects and a second drag restored the order (session-row drag not exercised) |
| 8 | Rows fade under the PROJECTS header while scrolled | PASS (`10`) |
| 9 | ⇧⌘E from every state | PASS — unfocused → tree focused, title "Hide Explorer" (`11`); focused → EXPLORER collapsed, terminal focused, "Show Explorer" (`12`); collapsed → expanded + focused; sidebar collapsed → sidebar opens + tree focused (`13`); EXPLORER hidden → shown + focused (`14`) |
| 10 | Settings open/close; sidebar collapse/expand | PASS — settings nav replaces the stack and restores it (`15`); ⌘B collapse and ⇧⌘E re-open |
| 11 | Quit and relaunch | PASS — the dragged split, visibility and collapse state persisted; the tree restored its expansions (`16`) |
| 12 | Edge tiling from the traffic-light strip | PASS — tiled to the left half of the laptop display, frame `(-1, 33, 757, 949)` (`18`) |
| 13 | Explorer double-click on a markdown file | PASS — preview pane opened beside the session (`17`) |

Not exercised at runtime: the cursor after a clamped divider drag released
outside the band; collapsing EXPLORER mid-drag; VoiceOver on section
headers; ⇧⌘E while Settings is open (reveals the section behind Settings,
no visible change — spec amendment); the empty-projects state inside
PROJECTS.

## 4. Observations

- The first two synthetic swipe attempts did not switch pages while the app
  was inactive; with the app frontmost the swipe switched every time.
- The EXPLORER header's `…` menu is disabled while the section is collapsed
  (no tree is loaded then) — recorded as a spec amendment.
