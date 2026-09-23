# System window drag (edge tiling) — verification evidence

Date: 2026-09-23 · Branch: `fix/system-window-drag` · Fork-only change.

## Root cause

Upstream sets `isMovable = false` on the main window (`AppDelegate.swift`) so
AppKit's titlebar-band drag never runs in parallel with the SwiftUI gestures
under the pane headers. That flag also makes `performDrag(with:)` a no-op,
so upstream's `WindowDragArea` (`Views/Chrome.swift`) moved the frame by
hand with `setFrameOrigin` on every mouse-dragged event. A programmatic
frame move is invisible to the window server, so macOS never offered its
drag-to-screen-edge tiling for this window (nor the tiling preview).

## Fix

`Views/SystemWindowDrag.swift` (new): `SystemWindowDrag.begin(_:with:)`
turns `isMovable` on for one drag, hands the drag to the window server with
`performDrag(with:)`, and turns the flag back off on the next left-button
release (one local and one global mouse-up monitor, or immediately if the
button is already up when `performDrag` returns). `WindowDragArea` calls it
instead of moving the frame itself; double-click-to-zoom is unchanged.

## Environment

macOS 26.6.2, dev build from this branch (`clients/native/dev-blank.sh`,
`UNPEEL_HOME=~/unpeel-dev-explorer-home`), window on the 3440×1440 external
display (Dock on its left edge). Driven by synthesized mouse events posted
at the HID tap; window frames read from the window list. The installed
`/Applications/Unpeel.app` was not touched (the operator restarted it
themselves while granting permissions).

Control: a plain `NSWindow` with a native titlebar and `isMovable = true`,
dragged with the same gesture (pointer to the exact screen edge, small
jiggle, 2.5 s hold), tiled to the left half — frame
`(-3348, 234, 1684, 1410)` — proving the synthetic gesture can trigger
tiling at all. Note: a pointer posted *past* the edge is not clamped and
does not tile; the pointer must stop at the edge itself.

## Checklist

| # | Check | Result |
|---|---|---|
| 1 | Drag by the sidebar's top strip to the left screen edge, hold | PASS — window tiled to the left half, frame `(-3348, -662, 1673, 1410)` (CG coords), same as the control window (`01-tiled-left-half.png`) |
| 2 | Drag a pane title chip 60 px and back while tiled | PASS — window frame unchanged, pane order unchanged (`02-after-pane-chip-drag.png`); `isMovable` was restored after the previous drag |
| 3 | Double-click the drag strip | PASS — zoomed to `(-3347, -662, 3347, 1410)`; second double-click restored the tiled frame |
| 4 | Drag the tiled window towards the centre | PASS — un-tiled and moved, size restored to 1200×800 by macOS (`03-dragged-off-tile.png`) |
| 5 | Consecutive drags (edge drag → zoom → chip drag → move) | PASS — every drag after the first still starts (the restore path works) |
| 6 | Plain drag before the fix (baseline, hand-rolled loop) | Window moved by the pointer delta only; no tiling at the edge (earlier run at commit 4206437) |

Not exercised: the right/top edges and the ⌥-hover green-button tiling
menu (same window-server path as the edge drag); pane-header empty-area
drags (`TerminalPaneView.swift` still calls `performDrag` directly and is a
no-op with `isMovable` off — unchanged, out of scope).

## Notes for future runs

- Synthetic first clicks reach a view only when its app is frontmost
  (`acceptsFirstMouse` is false); activate the dev app before dragging.
- With the Dock on the left of the external display, a press within the
  Dock's ~97 px column goes to the Dock, not the window.
- The compact titlebar band over the pane columns is covered by pane
  headers; the reliable drag surface is the sidebar's top strip
  (window-relative ≈ x 150, y 15).
