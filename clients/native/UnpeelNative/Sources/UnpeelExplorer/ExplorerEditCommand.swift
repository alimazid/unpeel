import AppKit

/// Fork-only: explorer operations. The app's Edit-menu commands the tree
/// answers while it is the first responder. They arrive through the
/// responder chain (`undo:`, `copy:`, …), so a focused terminal keeps them.
public enum ExplorerEditCommand: Equatable, Sendable {
    case undo, redo, cut, copy, paste

    public init?(action: Selector?) {
        switch action {
        case #selector(ExplorerNSOutlineView.undo(_:)): self = .undo
        case #selector(ExplorerNSOutlineView.redo(_:)): self = .redo
        case #selector(ExplorerNSOutlineView.cut(_:)): self = .cut
        case #selector(ExplorerNSOutlineView.copy(_:)): self = .copy
        case #selector(ExplorerNSOutlineView.paste(_:)): self = .paste
        default: return nil
        }
    }

    /// The menu title while the command is unavailable.
    var defaultTitle: String {
        switch self {
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        }
    }
}

/// Answers the Edit menu for the tree: nil when a command is unavailable,
/// else the title its menu item shows ("Undo Rename").
@MainActor
public protocol ExplorerEditTarget: AnyObject {
    func title(for command: ExplorerEditCommand) -> String?
    func perform(_ command: ExplorerEditCommand)
}
