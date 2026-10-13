import Foundation

public enum DirectoryContents: Sendable, Equatable {
    case loading
    case loaded(DirectoryListing)
    case failed(String)
}

public struct VisibilityFilter: Sendable, Equatable {
    public let showHidden: Bool
    public let showIgnored: Bool

    public init(showHidden: Bool = false, showIgnored: Bool = false) {
        self.showHidden = showHidden
        self.showIgnored = showIgnored
    }
}

/// The whole tree as a flat map of directory path → contents plus the set of
/// expanded folders. Flat rather than nested so a reload replaces one entry
/// and an `NSOutlineView` row is addressed by its path. Every reducer returns
/// a new model.
public struct FileTreeModel: Sendable, Equatable {
    public let root: String
    public let directories: [String: DirectoryContents]
    public let expanded: Set<String>

    public init(
        root: String,
        directories: [String: DirectoryContents] = [:],
        expanded: Set<String> = []
    ) {
        self.root = root
        self.directories = directories
        self.expanded = expanded
    }

    public static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func isSameOrBelow(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// Whether a folder's rows are on screen: the root, or an expanded
    /// folder whose ancestors are all expanded too. A folder can stay
    /// expanded under a collapsed parent (so re-expanding restores it); it
    /// is not shown until the parent is.
    public func isShown(_ directory: String) -> Bool {
        if directory == root { return true }
        guard expanded.contains(directory), directory.hasPrefix(root + "/") else { return false }
        var ancestor = Self.parent(of: directory)
        while ancestor != root {
            guard expanded.contains(ancestor), ancestor.count > root.count else { return false }
            ancestor = Self.parent(of: ancestor)
        }
        return true
    }

    public var loadedDirectories: Set<String> {
        Set(directories.compactMap { path, contents in
            if case .loaded = contents { return path }
            return nil
        })
    }

    /// Replaces one directory's contents. A successful reload also drops the
    /// subtrees (contents and expansion) of child folders that vanished.
    public func settingContents(_ contents: DirectoryContents, for directory: String) -> FileTreeModel {
        var nextDirectories = directories
        nextDirectories[directory] = contents
        guard case .loaded(let listing) = contents else {
            return FileTreeModel(root: root, directories: nextDirectories, expanded: expanded)
        }
        let alive = Set(listing.entries.filter { $0.kind == .directory }.map(\.path))
        let tracked = Set(nextDirectories.keys).union(expanded)
        let orphans = tracked.filter { Self.parent(of: $0) == directory && !alive.contains($0) }
        let survives: (String) -> Bool = { path in
            !orphans.contains { Self.isSameOrBelow(path, $0) }
        }
        return FileTreeModel(
            root: root,
            directories: nextDirectories.filter { survives($0.key) },
            expanded: expanded.filter(survives)
        )
    }

    public func expanding(_ path: String) -> FileTreeModel {
        FileTreeModel(root: root, directories: directories, expanded: expanded.union([path]))
    }

    /// Descendants stay expanded so re-expanding restores the subtree, as in
    /// VS Code.
    public func collapsing(_ path: String) -> FileTreeModel {
        FileTreeModel(root: root, directories: directories, expanded: expanded.subtracting([path]))
    }

    public func collapsingAll() -> FileTreeModel {
        FileTreeModel(root: root, directories: directories, expanded: [])
    }

    public func removingDirectory(_ path: String) -> FileTreeModel {
        FileTreeModel(
            root: root,
            directories: directories.filter { !Self.isSameOrBelow($0.key, path) },
            expanded: expanded.filter { !Self.isSameOrBelow($0, path) }
        )
    }

    /// Fork-only: explorer operations. `from` was renamed or moved to `to`:
    /// expansion beneath it follows to the new path, and its listings are
    /// dropped — their entries name the old paths — to be rescanned there.
    public func relocating(from: String, to: String) -> FileTreeModel {
        let rewrite: (String) -> String = { path in
            Self.isSameOrBelow(path, from) ? to + path.dropFirst(from.count) : path
        }
        return FileTreeModel(
            root: root,
            directories: directories.filter { !Self.isSameOrBelow($0.key, from) },
            expanded: Set(expanded.map(rewrite))
        )
    }

    /// `.git` is never listed, regardless of filter settings.
    public func visibleChildren(of directory: String, filter: VisibilityFilter) -> [FileEntry] {
        guard case .loaded(let listing)? = directories[directory] else { return [] }
        return listing.entries.filter { entry in
            if entry.name == ".git" { return false }
            if entry.isHidden && !filter.showHidden { return false }
            if entry.isIgnored && !filter.showIgnored { return false }
            return true
        }
    }

    public func truncatedCount(of directory: String) -> Int {
        guard case .loaded(let listing)? = directories[directory] else { return 0 }
        return listing.truncatedCount
    }

    public func entry(at path: String) -> FileEntry? {
        guard case .loaded(let listing)? = directories[Self.parent(of: path)] else { return nil }
        return listing.entry(at: path)
    }
}
