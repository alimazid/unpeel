//
//  ExplorerFocusCommand.swift
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

/// Fork-only: git support. ⇧⌘E's decision, generalised over the section.
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

enum ExplorerCommandAction: Equatable, Sendable {
    /// The tree already has focus in a visible, expanded EXPLORER section.
    case collapseExplorer
    /// Anything else: open the sidebar, show + expand EXPLORER, focus it.
    case revealAndFocus
}

enum ExplorerFocusCommand {
    static func action(
        treeFocused: Bool,
        explorerExpanded: Bool,
        explorerHidden: Bool,
        sidebarCollapsed: Bool
    ) -> ExplorerCommandAction {
        switch SidebarSectionFocusCommand.action(
            focused: treeFocused,
            expanded: explorerExpanded,
            hidden: explorerHidden,
            sidebarCollapsed: sidebarCollapsed
        ) {
        case .collapse: return .collapseExplorer
        case .revealAndFocus: return .revealAndFocus
        }
    }

    static func menuTitle(for action: ExplorerCommandAction) -> String {
        switch action {
        case .collapseExplorer: return SidebarSectionFocusCommand.menuTitle(for: .collapse, section: .explorer)
        case .revealAndFocus: return SidebarSectionFocusCommand.menuTitle(for: .revealAndFocus, section: .explorer)
        }
    }
}
