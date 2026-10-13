import AppKit

/// Fork-only: explorer operations. The tree's File Operations: the menu
/// items that start them and how each finds its targets.
extension ExplorerOutlineController {
    /// The context menu's operation group, shown for any entry target.
    var operationActions: [MenuAction?] {
        [.trash, nil]
    }

    /// Moves `paths` to the Trash; the row after them is selected next.
    func trash(_ paths: [String]) {
        let targets = paths.filter { applied?.entry(at: $0) != nil }
        guard !targets.isEmpty else { return }
        viewModel.trash(targets, thenSelect: ExplorerSelection.afterRemoving(targets, rows: visibleEntryRows()))
    }

    /// Every entry row the outline shows, top to bottom.
    func visibleEntryRows() -> [String] {
        guard let outlineView else { return [] }
        return (0..<outlineView.numberOfRows).compactMap { row in
            guard let item = outlineView.item(atRow: row) as? ExplorerItem, item.role == .entry else { return nil }
            return item.path
        }
    }
}
