import Foundation
import UnpeelGit

/// Fork-only: git support. The Git Status Decorations for one Explorer
/// Root, by absolute path: each changed file's state, and for each folder
/// the strongest state beneath it (`GitChangeKind.precedence`), so a change
/// inside a collapsed folder still shows. A deleted file has no row but
/// still marks its folder; a rename's original path marks nothing.
public struct GitDecorations: Equatable, Sendable {
    public static let none = GitDecorations(kinds: [:], untrackedFolders: [])

    private let kinds: [String: GitChangeKind]
    /// Folders git listed once because everything in them is untracked.
    private let untrackedFolders: Set<String>

    private init(kinds: [String: GitChangeKind], untrackedFolders: Set<String>) {
        self.kinds = kinds
        self.untrackedFolders = untrackedFolders
    }

    /// `root` is the folder the tree shows. When it holds the repository
    /// (Fork-only: nested repositories), the repository's own folder and
    /// those between it and `root` carry its strongest state too.
    public init(snapshot: GitRepositorySnapshot, shownFrom root: String? = nil) {
        let workTree = snapshot.location.workTree
        let ceiling = root.flatMap { workTree.hasPrefix($0 + "/") ? $0 : nil } ?? workTree
        var kinds: [String: GitChangeKind] = [:]
        var untrackedFolders: Set<String> = []
        for entry in snapshot.status.entries {
            let path = (workTree as NSString).appendingPathComponent(entry.path)
            if entry.isDirectory { untrackedFolders.insert(path) }
            kinds[path] = kinds[path].map { GitChangeKind.strongest($0, entry.kind) } ?? entry.kind
            Self.propagate(entry.kind, above: path, below: ceiling, into: &kinds)
        }
        self.init(kinds: kinds, untrackedFolders: untrackedFolders)
    }

    /// Raises every folder between `path` and `ceiling` to at least
    /// `kind`. Stops at the first folder already that strong: every folder
    /// above it was raised at least as far when it was.
    private static func propagate(
        _ kind: GitChangeKind, above path: String, below ceiling: String, into kinds: inout [String: GitChangeKind]
    ) {
        let prefix = ceiling + "/"
        var folder = (path as NSString).deletingLastPathComponent
        while folder.hasPrefix(prefix) {
            if let existing = kinds[folder], existing.precedence >= kind.precedence { return }
            kinds[folder] = kind
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    public var isEmpty: Bool { kinds.isEmpty }

    /// The state a row at `path` shows, if any.
    public func kind(at path: String) -> GitChangeKind? {
        if let kind = kinds[path] { return kind }
        guard !untrackedFolders.isEmpty else { return nil }
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count > 1 {
            if untrackedFolders.contains(folder) { return .untracked }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }
}
