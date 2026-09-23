//
//  ExplorerFocus.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. Finds the explorer's outline view in a
//  window, reports whether it holds keyboard focus, and focuses it — for
//  ⇧⌘E. The outline mounts a runloop turn or more after its section
//  expands, so `focusTree` retries briefly instead of assuming it exists.
//

import AppKit
import UnpeelExplorer

@MainActor
enum ExplorerFocus {
    private static let retryNanoseconds: UInt64 = 50_000_000

    static func outline(in view: NSView?) -> ExplorerNSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? ExplorerNSOutlineView { return outline }
        for subview in view.subviews {
            if let outline = outline(in: subview) { return outline }
        }
        return nil
    }

    static func isTreeFocused(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder is ExplorerNSOutlineView { return true }
        guard let outline = outline(in: window?.contentView) else { return false }
        return responder.isDescendant(of: outline)
    }

    /// Makes the outline first responder, retrying every 50 ms (about one
    /// second in total) while the section mounts. Gives up silently: the
    /// section is still revealed, only focus is missing.
    static func focusTree(in window: NSWindow?, attemptsLeft: Int = 20) {
        guard let window else { return }
        if let outline = outline(in: window.contentView) {
            window.makeFirstResponder(outline)
            return
        }
        guard attemptsLeft > 1 else { return }
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: retryNanoseconds)
            focusTree(in: window, attemptsLeft: attemptsLeft - 1)
        }
    }
}
