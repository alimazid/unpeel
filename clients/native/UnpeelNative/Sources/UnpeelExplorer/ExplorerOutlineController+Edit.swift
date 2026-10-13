import AppKit

/// Fork-only: explorer operations. The Edit menu while the tree has focus:
/// undo and redo walk the Explorer Root's Operation History.
extension ExplorerOutlineController: ExplorerEditTarget {
    public func title(for command: ExplorerEditCommand) -> String? {
        switch command {
        case .undo: return viewModel.undoActionTitle
        case .redo: return viewModel.redoActionTitle
        case .cut, .copy, .paste: return nil
        }
    }

    public func perform(_ command: ExplorerEditCommand) {
        switch command {
        case .undo: viewModel.undo()
        case .redo: viewModel.redo()
        case .cut, .copy, .paste: break
        }
    }
}
