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
    /// only copy) copies. Items from Finder or another app copy, so their
    /// source is never altered unless asked: ⌘ (the source offering only a
    /// generic operation) moves. A link alone (⌃) is no drop.
    static func operation(
        sources: [String], into folder: String, sourceMask: NSDragOperation, isInternal: Bool
    ) -> NSDragOperation {
        guard !sources.isEmpty, let copying = isCopy(sourceMask, isInternal: isInternal) else { return [] }
        if sources.contains(where: { folder == $0 || folder.hasPrefix($0 == "/" ? "/" : $0 + "/") }) { return [] }
        if !copying, sources.allSatisfy({ FileTreeModel.parent(of: $0) == folder }) { return [] }
        return copying ? .copy : .move
    }

    /// Whether the drop copies (else moves), nil for no drop.
    private static func isCopy(_ mask: NSDragOperation, isInternal: Bool) -> Bool? {
        if isInternal {
            return mask.isDisjoint(with: [.copy, .move, .generic]) ? nil : mask == .copy
        }
        if mask.contains(.copy) { return true }
        return mask.isDisjoint(with: [.move, .generic]) ? nil : false
    }

    /// A dragged path with its folder resolved, as the tree's own paths
    /// are: Finder may hand over `/var/…` or a path through a symlink.
    static func canonical(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let name = (standardized as NSString).lastPathComponent
        guard let folder = CanonicalPath.resolve(FileTreeModel.parent(of: standardized)), name != "/" else {
            return standardized
        }
        return (folder as NSString).appendingPathComponent(name)
    }
}
