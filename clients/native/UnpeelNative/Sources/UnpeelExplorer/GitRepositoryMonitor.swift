import Foundation
import UnpeelGit

/// Fork-only: git support. Watches one repository's git directory with the
/// EXPLORER's FSEvents watcher and signals when what Git History shows can
/// have changed: HEAD or the index (a commit, checkout, merge), refs or
/// packed-refs (a branch created or deleted, a fetch, a push). Objects,
/// logs, lock files and other worktrees' state are ignored, and working-tree
/// edits never reach it — those are the EXPLORER's watcher's business.
public final class GitRepositoryMonitor: GitChangeMonitoring, @unchecked Sendable {
    /// The monitor factory Git History's live services use.
    public static let make: GitHistoryServices.MakeMonitor = { location, handler in
        GitRepositoryMonitor(location: location, handler: handler)
    }

    /// Files directly in a git directory whose change means HEAD, the index
    /// or the upstream counts may have moved.
    private static let headFiles: Set<String> = [
        "HEAD", "index", "ORIG_HEAD", "FETCH_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REBASE_HEAD",
    ]

    private let watchers: [FileSystemWatcher]

    /// Nil when FSEvents could not start a stream; Git History then simply
    /// does not refresh by itself.
    public init?(location: GitRepositoryLocation, latency: TimeInterval = 0.15, handler: @escaping @Sendable () -> Void) {
        watchers = Self.watchedRoots(for: location).map { root in
            FileSystemWatcher(root: root, latency: latency) { change in
                if Self.isRelevant(change, in: location) { handler() }
            }
        }
        guard watchers.allSatisfy({ $0.start() }) else {
            watchers.forEach { $0.stop() }
            return nil
        }
    }

    deinit {
        stop()
    }

    public func stop() {
        watchers.forEach { $0.stop() }
    }

    /// The common directory (shared refs; it also holds a linked worktree's
    /// own git dir under `worktrees/`), plus the git dir when it lives
    /// elsewhere.
    static func watchedRoots(for location: GitRepositoryLocation) -> [String] {
        let common = location.commonDirectory
        let git = location.gitDirectory
        return git == common || git.hasPrefix(common + "/") ? [common] : [common, git]
    }

    static func isRelevant(_ change: FileSystemChange, in location: GitRepositoryLocation) -> Bool {
        change.needsFullRescan || change.directories.contains { isRelevant($0, in: location) }
    }

    static func isRelevant(_ path: String, in location: GitRepositoryLocation) -> Bool {
        guard !path.hasSuffix(".lock") else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == location.gitDirectory, headFiles.contains((path as NSString).lastPathComponent) {
            return true
        }
        for directory in [location.commonDirectory, location.gitDirectory] {
            if path == directory + "/packed-refs" || path == directory + "/refs" || path.hasPrefix(directory + "/refs/") {
                return true
            }
        }
        return false
    }
}
