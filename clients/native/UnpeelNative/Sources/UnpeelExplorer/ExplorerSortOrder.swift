import Foundation

/// Fork-only: date modified column. How the EXPLORER orders each folder's
/// rows. Folders stay above files in every order, as in VS Code's
/// `explorer.sortOrder` (and the Draft Row's placement relies on it).
public enum ExplorerSortOrder: String, Sendable, Equatable, CaseIterable {
    /// Natural name order — the order `DirectoryLoader` lists in.
    case name
    /// Newest first; ties in natural name order, undated entries last.
    case dateModified

    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        switch self {
        case .name: return entries
        case .dateModified: return entries.sorted(by: Self.newerFirst)
        }
    }

    /// A checkout stamps many files with one time, so ties are broken by
    /// name here rather than left to the order the entries arrived in.
    private static func newerFirst(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind == .directory }
        switch (lhs.modifiedAt, rhs.modifiedAt) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
