import AppKit

/// Fork-only: explorer operations. The tree's File Operations: the menu
/// items that start them and how each finds its targets.
extension ExplorerOutlineController {
    /// The context menu's operation group, shown for any entry target;
    /// Rename only for a single one.
    func operationActions(forTargetCount count: Int) -> [MenuAction?] {
        (count == 1 ? [.rename] : []) + [.trash, nil]
    }

    // MARK: - Rename

    /// Turns `path`'s row into a name field. False when the row is not on
    /// screen or another field could not give up focus.
    @discardableResult
    func beginRename(_ path: String) -> Bool {
        nameEditor?.cancel()
        guard let entry = applied?.entry(at: path), let outlineView, let item = items[path] else { return false }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ExplorerRowCellView,
              let field = cell.textField
        else { return false }
        let folder = FileTreeModel.parent(of: path)
        let editor = ExplorerNameEditor(
            field: field,
            purpose: .rename(currentName: entry.name),
            isTaken: { Self.nameIsTaken($0, in: folder, excluding: path) },
            onFinish: { [weak self] outcome in self?.finishRename(path, outcome) }
        )
        nameEditor = editor
        nameEditingFolder = folder
        let selection = ExplorerNameEditor.defaultSelection(for: entry.name, isFolder: entry.kind == .directory)
        guard editor.begin(selecting: selection) else {
            endNameEditing()
            return false
        }
        return true
    }

    private func finishRename(_ path: String, _ outcome: ExplorerNameEditor.Outcome) {
        endNameEditing()
        guard case .commit(let name) = outcome else { return }
        viewModel.rename(path, to: name)
    }

    /// Lets the edited folder's held-back reloads through.
    func endNameEditing() {
        nameEditor = nil
        nameEditingFolder = nil
        let held = deferredReloads
        deferredReloads = []
        for folder in held.sorted(by: { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }) {
            reloadRows(of: folder)
        }
    }

    /// Whether `name` in `folder` is another item than `excluding` — the
    /// item itself under a different case is not, on a case-insensitive
    /// volume.
    static func nameIsTaken(_ name: String, in folder: String, excluding path: String? = nil) -> Bool {
        guard let found = ItemIdentity.of((folder as NSString).appendingPathComponent(name)) else { return false }
        guard let path, let own = ItemIdentity.of(path) else { return true }
        return !found.isSameObject(as: own)
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
