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
/// generalised over the section whose list holds its keyboard focus.
@MainActor
enum SidebarSectionFocus {
    private static let retryNanoseconds: UInt64 = 50_000_000

    /// The view that takes a section's keyboard focus; PROJECTS has none.
    static func listType(for section: SidebarSectionID) -> NSView.Type? {
        switch section {
        case .explorer: return ExplorerNSOutlineView.self
        case .gitHistory: return GitHistoryNSOutlineView.self
        case .projects: return nil
        }
    }

    static func list(of section: SidebarSectionID, in view: NSView?) -> NSView? {
        listType(for: section).flatMap { find($0, in: view) }
    }

    static func isFocused(_ section: SidebarSectionID, in window: NSWindow?) -> Bool {
        guard let type = listType(for: section),
              let responder = window?.firstResponder as? NSView
        else { return false }
        if responder.isKind(of: type) { return true }
        guard let list = find(type, in: window?.contentView) else { return false }
        return responder.isDescendant(of: list)
    }

    /// Makes the section's list first responder, retrying every 50 ms
    /// (about one second in total) while the section mounts. Gives up
    /// silently: the section is still revealed, only focus is missing.
    /// Retries not only while the list hasn't mounted yet, but also when it
    /// has mounted but refuses first responder status (e.g.
    /// `acceptsFirstResponder` is briefly false while the table is still
    /// laying out its column) — `makeFirstResponder` returning `false`, or
    /// the window's first responder ending up something other than the
    /// list, both count as "not focused yet".
    static func focus(_ section: SidebarSectionID, in window: NSWindow?, attemptsLeft: Int = 20) {
        guard let window, let type = listType(for: section) else { return }
        if let list = find(type, in: window.contentView),
           window.makeFirstResponder(list),
           window.firstResponder === list {
            return
        }
        guard attemptsLeft > 1 else { return }
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: retryNanoseconds)
            focus(section, in: window, attemptsLeft: attemptsLeft - 1)
        }
    }

    private static func find(_ type: NSView.Type, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.isKind(of: type) { return view }
        for subview in view.subviews {
            if let list = find(type, in: subview) { return list }
        }
        return nil
    }
}

@MainActor
enum ExplorerFocus {
    static func outline(in view: NSView?) -> ExplorerNSOutlineView? {
        SidebarSectionFocus.list(of: .explorer, in: view) as? ExplorerNSOutlineView
    }

    static func isTreeFocused(in window: NSWindow?) -> Bool {
        SidebarSectionFocus.isFocused(.explorer, in: window)
    }

    static func focusTree(in window: NSWindow?) {
        SidebarSectionFocus.focus(.explorer, in: window)
    }
}
