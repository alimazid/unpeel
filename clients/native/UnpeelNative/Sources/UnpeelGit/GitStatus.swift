import Foundation

/// One changed path in the working tree, reduced to a single state.
public struct GitStatusEntry: Equatable, Sendable {
    /// Relative to the work tree, without a trailing slash.
    public let path: String
    /// Where a rename or copy came from, relative to the work tree.
    public let originalPath: String?
    public let kind: GitChangeKind
    /// A folder git lists once because everything in it is untracked.
    public let isDirectory: Bool

    public init(path: String, originalPath: String? = nil, kind: GitChangeKind, isDirectory: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.isDirectory = isDirectory
    }
}

/// The working tree's git state from one `git status --porcelain=v2
/// --branch -z`: HEAD (the same headers `GitHead` reads) and every changed
/// path, staged and unstaged changes combined by `GitChangeKind.precedence`.
public struct GitStatus: Equatable, Sendable {
    public let head: GitHead
    public let entries: [GitStatusEntry]

    public init(head: GitHead, entries: [GitStatusEntry]) {
        self.head = head
        self.entries = entries
    }

    /// Records are NUL-terminated; a rename or copy (`2`) is followed by one
    /// more NUL-terminated field, its original path. Paths are taken as
    /// they are after a fixed number of space-separated fields, so spaces,
    /// quotes and newlines in them survive.
    public static func parse(porcelainV2 data: Data) -> GitStatus {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            switch record.first {
            case "1":
                if let entry = changed(record, fieldsBeforePath: 8) { entries.append(entry) }
            case "2":
                let original = index < fields.count ? fields[index] : nil
                index += 1
                if let entry = changed(record, fieldsBeforePath: 9, originalPath: original) { entries.append(entry) }
            case "u":
                if let path = path(of: record, fieldsBeforePath: 10) {
                    entries.append(GitStatusEntry(path: path, kind: .conflicted))
                }
            case "?":
                entries.append(untracked(String(record.dropFirst(2))))
            default:
                continue
            }
        }
        return GitStatus(head: GitHead.parse(porcelainV2: data), entries: entries)
    }

    /// An ordinary (`1`) or renamed/copied (`2`) record: its `XY` code
    /// combined into the strongest of the two sides.
    private static func changed(_ record: String, fieldsBeforePath: Int, originalPath: String? = nil) -> GitStatusEntry? {
        let parts = record.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, let path = path(of: record, fieldsBeforePath: fieldsBeforePath) else { return nil }
        let kinds = parts[1].compactMap(GitChangeKind.init(statusCode:))
        guard let first = kinds.first else { return nil }
        let kind = kinds.dropFirst().reduce(first, GitChangeKind.strongest)
        return GitStatusEntry(path: path, originalPath: originalPath, kind: kind)
    }

    private static func path(of record: String, fieldsBeforePath: Int) -> String? {
        let parts = record.split(separator: " ", maxSplits: fieldsBeforePath, omittingEmptySubsequences: false)
        guard parts.count == fieldsBeforePath + 1 else { return nil }
        return String(parts[fieldsBeforePath])
    }

    private static func untracked(_ path: String) -> GitStatusEntry {
        guard path.count > 1, path.hasSuffix("/") else { return GitStatusEntry(path: path, kind: .untracked) }
        return GitStatusEntry(path: String(path.dropLast()), kind: .untracked, isDirectory: true)
    }
}

/// An Explorer Root's repository as one read saw it: where it lives and
/// its status. Paths in `status` are relative to `location.workTree`.
public struct GitRepositorySnapshot: Equatable, Sendable {
    public let location: GitRepositoryLocation
    public let status: GitStatus

    public init(location: GitRepositoryLocation, status: GitStatus) {
        self.location = location
        self.status = status
    }
}
