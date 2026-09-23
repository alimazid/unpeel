//
//  ExplorerFocusCommand.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The pure decision behind ⇧⌘E (View ▸
//  Show/Hide Explorer), so every branch is testable without a window.
//

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
        treeFocused && explorerExpanded && !explorerHidden && !sidebarCollapsed
            ? .collapseExplorer
            : .revealAndFocus
    }

    static func menuTitle(for action: ExplorerCommandAction) -> String {
        switch action {
        case .collapseExplorer: return "Hide Explorer"
        case .revealAndFocus: return "Show Explorer"
        }
    }
}
