import AppKit

/// Fork-only: explorer operations. Dragging rows onto a folder moves them
/// there; ⌥ copies. A file row stands for its folder, which is what
/// highlights; the space below the rows is the root. Hovering a collapsed
/// folder springs it open (AppKit's own outline behaviour).
extension ExplorerOutlineController {
    public func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex _: Int
    ) -> NSDragOperation {
        guard let root = applied?.root else { return [] }
        let target = dropTarget(onItem: item, root: root)
        let operation = ExplorerDrop.operation(
            sources: draggedPaths(info), into: target.folder,
            sourceMask: info.draggingSourceOperationMask, isInternal: isOwnDrag(info)
        )
        guard !operation.isEmpty else { return [] }
        outlineView.setDropItem(target.item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return operation
    }

    public func outlineView(
        _: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex _: Int
    ) -> Bool {
        guard let root = applied?.root else { return false }
        let folder = dropTarget(onItem: item, root: root).folder
        let sources = draggedPaths(info)
        let operation = ExplorerDrop.operation(
            sources: sources, into: folder,
            sourceMask: info.draggingSourceOperationMask, isInternal: isOwnDrag(info)
        )
        guard !operation.isEmpty else { return false }
        let copying = operation == .copy
        transfer(sources, into: folder, copying: copying, as: copying ? .copy : .move)
        return true
    }

    /// The folder under the pointer and the row standing for it (nil for
    /// the root).
    private func dropTarget(onItem item: Any?, root: String) -> (folder: String, item: ExplorerItem?) {
        guard let row = item as? ExplorerItem, row.role == .entry, let entry = applied?.entry(at: row.path) else {
            return (root, nil)
        }
        let isFolder = entry.kind == .directory && entry.isExpandable
        let folder = ExplorerDrop.folder(on: entry.path, isFolder: isFolder, root: root)
        return (folder, folder == root ? nil : items[folder])
    }

    private func isOwnDrag(_ info: any NSDraggingInfo) -> Bool {
        guard let outlineView, let source = info.draggingSource as AnyObject? else { return false }
        return source === outlineView
    }

    private func draggedPaths(_ info: any NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
        return (urls as? [URL])?.map(\.path) ?? []
    }
}
