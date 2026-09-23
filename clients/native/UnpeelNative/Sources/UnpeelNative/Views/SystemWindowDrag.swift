import AppKit

/// Fork-only. Starts a window drag through the window server instead of
/// moving the frame by hand.
///
/// The main window keeps `isMovable = false` (see `AppDelegate`) so
/// AppKit's titlebar-band drag never runs in parallel with the SwiftUI
/// gestures under the pane headers. That flag also makes
/// `performDrag(with:)` a no-op, which is why upstream's `WindowDragArea`
/// moved the frame itself with `setFrameOrigin` — and a programmatic move
/// is invisible to the window server, so macOS never offered its
/// drag-to-screen-edge tiling for this window.
///
/// This helper flips `isMovable` on for exactly one drag: it hands the
/// drag to the window server (which shows the tiling previews and snaps on
/// release) and turns the flag back off as soon as the mouse button is
/// released, so the pane-header conflict upstream avoided stays avoided.
@MainActor
enum SystemWindowDrag {
    private static var monitors: [Any] = []
    private static weak var draggingWindow: NSWindow?

    /// Begins a system drag of `window` for the mouse-down `event`.
    static func begin(_ window: NSWindow, with event: NSEvent) {
        endPendingDrag()
        let wasMovable = window.isMovable
        window.isMovable = true
        window.performDrag(with: event)
        guard !wasMovable else { return }
        // `performDrag` may return before or after the button goes up
        // depending on the OS release: restore now if the drag is already
        // over, otherwise on the next left-button release, wherever the
        // pointer ends up (the window server may deliver it to the app or
        // to nobody, hence one local and one global monitor).
        if NSEvent.pressedMouseButtons & 0x1 == 0 {
            window.isMovable = false
            return
        }
        draggingWindow = window
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { event in
            Task { @MainActor in endPendingDrag() }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { _ in
            Task { @MainActor in endPendingDrag() }
        }) {
            monitors.append(global)
        }
    }

    /// Restores `isMovable = false` on the window of the drag in flight, if
    /// any, and drops the release monitors.
    static func endPendingDrag() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        draggingWindow?.isMovable = false
        draggingWindow = nil
    }
}
