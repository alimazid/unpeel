//
//  ExplorerFocus.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. Finds a section's list view (the
//  explorer's outline, Git History's list) in a window, reports whether it
//  holds keyboard focus, and focuses it — for ⇧⌘E and ⌃⇧G. A list mounts
//  a runloop turn or more after its section expands, so `focus` retries
//  briefly instead of assuming it exists.
//

import AppKit
import UnpeelExplorer
import UnpeelGit

/// Fork-only: git support. The lookup and focus behind `ExplorerFocus`,
/// generalised over the list's view type.
@MainActor
enum SidebarSectionFocus {
    private static let retryNanoseconds: UInt64 = 50_000_000

    static func view<List: NSView>(_ type: List.Type, in view: NSView?) -> List? {
        guard let view else { return nil }
        if let list = view as? List { return list }
        for subview in view.subviews {
            if let list = self.view(type, in: subview) { return list }
        }
        return nil
    }

    static func isFocused<List: NSView>(_ type: List.Type, in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder is List { return true }
        guard let list = view(type, in: window?.contentView) else { return false }
        return responder.isDescendant(of: list)
    }

    /// Makes the list first responder, retrying every 50 ms (about one
    /// second in total) while the section mounts. Gives up silently: the
    /// section is still revealed, only focus is missing. Retries not only
    /// while the list hasn't mounted yet, but also when it has mounted but
    /// refuses first responder status (e.g. `acceptsFirstResponder` is
    /// briefly false while the table is still laying out its column) —
    /// `makeFirstResponder` returning `false`, or the window's first
    /// responder ending up something other than the list, both count as
    /// "not focused yet".
    static func focus<List: NSView>(_ type: List.Type, in window: NSWindow?, attemptsLeft: Int = 20) {
        guard let window else { return }
        if let list = view(type, in: window.contentView),
           window.makeFirstResponder(list),
           window.firstResponder === list {
            return
        }
        guard attemptsLeft > 1 else { return }
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: retryNanoseconds)
            focus(type, in: window, attemptsLeft: attemptsLeft - 1)
        }
    }
}

@MainActor
enum ExplorerFocus {
    static func outline(in view: NSView?) -> ExplorerNSOutlineView? {
        SidebarSectionFocus.view(ExplorerNSOutlineView.self, in: view)
    }

    static func isTreeFocused(in window: NSWindow?) -> Bool {
        SidebarSectionFocus.isFocused(ExplorerNSOutlineView.self, in: window)
    }

    static func focusTree(in window: NSWindow?) {
        SidebarSectionFocus.focus(ExplorerNSOutlineView.self, in: window)
    }
}

/// Fork-only: git support. GIT HISTORY's list, for ⌃⇧G.
@MainActor
enum GitHistoryFocus {
    static func list(in view: NSView?) -> GitHistoryNSOutlineView? {
        SidebarSectionFocus.view(GitHistoryNSOutlineView.self, in: view)
    }

    static func isListFocused(in window: NSWindow?) -> Bool {
        SidebarSectionFocus.isFocused(GitHistoryNSOutlineView.self, in: window)
    }

    static func focusList(in window: NSWindow?) {
        SidebarSectionFocus.focus(GitHistoryNSOutlineView.self, in: window)
    }
}
