import AppKit

/// Fork-only: explorer operations. The Edit menu while the tree has focus:
/// undo and redo walk the Explorer Root's Operation History.
extension ExplorerOutlineController: ExplorerEditTarget {
    public func title(for command: ExplorerEditCommand) -> String? {
        dropStaleCut()
        switch command {
        case .undo: return viewModel.undoActionTitle
        case .redo: return viewModel.redoActionTitle
        case .cut, .copy:
            return viewModel.selection.contains { applied?.entry(at: $0) != nil } ? command.defaultTitle : nil
        case .paste:
            return applied != nil && !pasteableFiles.isEmpty ? command.defaultTitle : nil
        }
    }

    public func perform(_ command: ExplorerEditCommand) {
        switch command {
        case .undo: viewModel.undo()
        case .redo: viewModel.redo()
        case .cut, .copy: copyItems(viewModel.selection, cutting: command == .cut)
        case .paste: paste(into: viewModel.selection)
        }
    }
}

/// The context menu's Paste is enabled only with files to paste.
extension ExplorerOutlineController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let payload = menuItem.representedObject as? MenuActionPayload, payload.action == .paste else {
            return true
        }
        return !pasteableFiles.isEmpty
    }
}
