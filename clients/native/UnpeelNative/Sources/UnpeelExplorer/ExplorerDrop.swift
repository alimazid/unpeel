import AppKit

/// Fork-only: explorer operations. Pure rules for drops onto the tree.
enum ExplorerDrop {
    /// The folder a drop lands in: a folder row itself, a file row's
    /// folder, or the root for the space below the rows.
    static func folder(on path: String?, isFolder: Bool, root: String) -> String {
        guard let path else { return root }
        return isFolder ? path : FileTreeModel.parent(of: path)
    }

    /// What dropping `sources` into `folder` does, or `[]` when it cannot
    /// happen. Rows dragged within the tree move; ⌥ (the source offering
    /// only copy) copies. Drags from outside the tree are not accepted yet.
    static func operation(
        sources: [String], into folder: String, sourceMask: NSDragOperation, isInternal: Bool
    ) -> NSDragOperation {
        guard isInternal, !sources.isEmpty else { return [] }
        if sources.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) { return [] }
        let copying = sourceMask == .copy
        if !copying, sources.allSatisfy({ FileTreeModel.parent(of: $0) == folder }) { return [] }
        return copying ? .copy : .move
    }
}
