import Foundation

/// Lists exactly one directory. Never recurses and never reads outside
/// `root`; callers hop off the main thread before calling `load`.
public struct DirectoryLoader: Sendable {
    public static let defaultMaxEntries = 10_000
    public let maxEntries: Int

    public init(maxEntries: Int = DirectoryLoader.defaultMaxEntries) {
        self.maxEntries = maxEntries
    }

    public func load(directory: String, root: String) throws -> DirectoryListing {
        guard CanonicalPath.isInside(directory, root: root) else {
            throw ExplorerError.outsideRoot(directory)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        let sorted = names
            .map { Self.entry(named: $0, in: directory, root: root) }
            .sorted(by: Self.precedes)
        let kept = Array(sorted.prefix(maxEntries))
        return DirectoryListing(entries: kept, truncatedCount: sorted.count - kept.count)
    }

    private static func entry(named name: String, in directory: String, root: String) -> FileEntry {
        let manager = FileManager.default
        let path = (directory as NSString).appendingPathComponent(name)
        let attributes = try? manager.attributesOfItem(atPath: path)
        let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: path, isDirectory: &isDirectory)
        let kind: FileKind = (exists && isDirectory.boolValue) ? .directory : .file
        let expandable = kind == .directory
            && (!isSymlink || CanonicalPath.isInside(path, root: root))
        return FileEntry(
            path: path,
            name: name,
            kind: kind,
            isSymlink: isSymlink,
            isHidden: name.hasPrefix("."),
            isIgnored: false,
            isExpandable: expandable
        )
    }

    /// VS Code's default order: folders first, then natural name order.
    private static func precedes(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind == .directory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
