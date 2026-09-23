# Markdown preview pane — verification evidence

Date: 2026-09-22 · Branch: `feat/markdown-preview-pane` · Runtime checks at
`5086ca0` (dev build 19:47) · Spec:
`docs/superpowers/specs/2026-09-22-markdown-preview-pane-design.md` · Plan:
`docs/superpowers/plans/2026-09-22-markdown-preview-pane.md`

Environment: macOS 26.6.2, Xcode 26.3 / Swift 6.2.4. Runtime checks ran in the
isolated dev build (`clients/native/dev-blank.sh`,
`UNPEEL_HOME=~/unpeel-dev-explorer-home`, page 2 of the workspace pager — page
1 of that home shows the machine Host and was not used), driven by synthesized
mouse/keyboard events; the Markdown plugin was linked into the dev home. The
installed `/Applications/Unpeel.app` was never launched, quit or signalled.
Screenshots in `markdown-preview-pane/`.

## 1. Tests

- `clients/native/test-native.sh` at the last code commit (`2e7eb1c`, then
  `5086ca0`): `Executed 790 tests, with 1 test skipped and 0 failures` (the
  skip is upstream's `HostServiceIdentityTests`), plus 38 swift-testing tests.
- Per target: `UnpeelMarkdownPreviewTests` 31 → 39 after the final fixes
  (renderer, document, resource policy, scheme handler, navigation policy,
  observer); `PaneLayoutStateTests` 28 (+ conformance suite unchanged);
  `UnpeelExplorerTests` 120; `ExplorerContextResolverTests` 19;
  `MarkdownPreviewTargetTests` 5.

## 2. Reviews

Six task reviews plus a whole-branch review (report
`.git/sdd/final-review-mp.md`): 0 Critical, 2 Important, 12 Minor, all fixed
(`c8ce9d5`, `4d1aa5f`, `2e7eb1c`, `5086ca0`) and re-reviewed "ready to
merge". Notable findings fixed along the way: the scheme handler read files
before applying the 4 MB cap and never capped images; the page had no CSP
(now `script-src 'none'`, listeners injected as a `WKUserScript`); in-page
anchors were misrouted; `stop()` could let the observer resume; a preview
leaf could reach the persisted layout through the launcher snapshot; a
render-path `stat` (removed — the pane shows a notice instead); the observer
died after a >100 ms absence; in-page links were not confined to the root.

## 3. Runtime checklist

| # | Check | Result |
|---|---|---|
| 1 | Double-click `README.md` | PASS — preview pane right of the session pane: headings, task list, table, fenced code, quote, strikethrough (`01-…png`) |
| 2 | Double-click `README.md` again | PASS — existing pane focused, no new pane |
| 3 | Double-click `notes.md` | PASS — second preview pane beside the session (`02-…png`) |
| 4 | **Edit** on `notes.md` | PASS — Markdown plugin pane opened beside the session; typing in it (auto-save) updated the preview within ~2 s (`03-…png`, `04-…png`) |
| 5 | ⌘W with the preview focused | PASS — only that preview closed (`05-…png`) |
| 6 | Close the session panes (⌘W twice: shell, then the plugin session) | PASS — the group dissolved with its preview; no crash (`13-…png`) |
| 7 | `rm notes.md` while previewed | PASS — "notes.md is no longer available" centred in the pane, pane kept (`08-…png`); recreating the file re-rendered it (`09-…png`) |
| 8 | `![](img/a.png)` inside the root | PASS — image rendered (`01-…png`) |
| 9 | `![](../outside.png)` outside the root | PASS — broken-image glyph, nothing served |
| 10 | Click `https://www.apple.com` | PASS — Google Chrome came to the front, preview unchanged |
| 11 | Click the relative `notes.md` link | PASS — new preview pane for it (`07-…png`) |
| 12 | System appearance light/dark | PASS — preview re-styled without reload (`11-…png`) |
| 13 | Drag the divider | PASS — panes reflowed; no blank frame in the capture (`10-…png`); a still cannot rule out transient flicker |
| 14 | Quit and relaunch | PASS — previews gone, session group (shell + plugin) intact (`12-…png`) |
| 15 | Context menu on `README.md` | PASS — Open, Open in Markdown Editor, Open in Editor, Reveal in Finder, Quick Look, … (`06-…png`) |

Not exercised at runtime: ⌘↓ on a markdown file (unit-tested routing, same
path as double-click), Escape returning focus to the session pane, the
six-per-group preview cap, an oversized (>4 MB) file, and the plugin-not-
installed prompt (the plugin is always found in the real `~/.unpeel`).

## 4. Observations

- Closing a plain shell session with ⌘W removed it without a confirmation
  card (upstream behaviour for a non-archivable session).
- After the dev Host restart the plugin pane re-opened its previous buffer;
  unrelated to the preview.
- The dev app restores its last window frame even when that frame lies on a
  display that is asleep; Window ▸ Zoom then made it fill the external
  display. Synthetic input cannot reach the app while the screen is locked.
