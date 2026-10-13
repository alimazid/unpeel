//
//  SidebarSectionFocusCommand.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The pure decision behind ⇧⌘E (View ▸
//  Show/Hide Explorer) and ⌃⇧G (View ▸ Show/Hide Git History), so every
//  branch is testable without a window.
//

/// What a section's View-menu shortcut does now.
enum SidebarSectionCommandAction: Equatable, Sendable {
    /// The section's list already has focus, and the section is visible
    /// and expanded.
    case collapse
    /// Anything else: open the sidebar, show + expand the section, focus it.
    case revealAndFocus
}

/// ⇧⌘E's decision, generalised over the section for git support.
enum SidebarSectionFocusCommand {
    static func action(
        focused: Bool,
        expanded: Bool,
        hidden: Bool,
        sidebarCollapsed: Bool
    ) -> SidebarSectionCommandAction {
        focused && expanded && !hidden && !sidebarCollapsed ? .collapse : .revealAndFocus
    }

    static func menuTitle(for action: SidebarSectionCommandAction, section: SidebarSectionID) -> String {
        let name = section.title.capitalized
        switch action {
        case .collapse: return "Hide \(name)"
        case .revealAndFocus: return "Show \(name)"
        }
    }
}
