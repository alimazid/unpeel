import Foundation

public enum FileKind: String, Sendable, Equatable {
    case file
    case directory
}

/// One row of a directory listing. `kind` follows symlinks (a link to a
/// folder is a `.directory`); `isExpandable` is false for a linked folder
/// whose target lies outside the explorer root.
public struct FileEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let kind: FileKind
    public let isSymlink: Bool
    public let isHidden: Bool
    public let isIgnored: Bool
    public let isExpandable: Bool

    public var id: String { path }

    public init(
        path: String,
        name: String,
        kind: FileKind,
        isSymlink: Bool = false,
        isHidden: Bool = false,
        isIgnored: Bool = false,
        isExpandable: Bool? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isIgnored = isIgnored
        self.isExpandable = isExpandable ?? (kind == .directory)
    }

    public func with(isIgnored: Bool) -> FileEntry {
        FileEntry(
            path: path, name: name, kind: kind, isSymlink: isSymlink,
            isHidden: isHidden, isIgnored: isIgnored, isExpandable: isExpandable
        )
    }
}

public struct DirectoryListing: Sendable, Equatable {
    public let entries: [FileEntry]
    /// Entries beyond the loader's cap that were not included.
    public let truncatedCount: Int

    public init(entries: [FileEntry], truncatedCount: Int = 0) {
        self.entries = entries
        self.truncatedCount = truncatedCount
    }
}

public enum ExplorerError: Error, Equatable, LocalizedError {
    case outsideRoot(String)
    case rootUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .outsideRoot(let path):
            return "“\(path)” is outside the project folder."
        case .rootUnavailable(let path):
            return "“\(path)” could not be opened."
        }
    }
}
