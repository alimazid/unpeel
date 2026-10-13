import Foundation
import os
import UnpeelGit

/// Fork-only: git support. Watches one repository's git directory with the
/// EXPLORER's FSEvents watcher and signals when the repository's git state
/// can have changed: HEAD or the index (a commit, checkout, stage, merge),
/// refs or packed-refs (a branch created or deleted, a fetch, a push).
/// Objects, logs, lock files and other worktrees' state are ignored, and
/// working-tree edits never reach it — those are the EXPLORER's watcher's
/// business. A folder that is not a repository is watched for a `.git`
/// appearing in it instead.
public final class GitRepositoryMonitor: GitChangeMonitoring, @unchecked Sendable {
    /// The monitor factories `GitRepositoryHub`'s live services use.
    public static let make: GitRepositoryHubServices.MakeMonitor = { location, handler in
        GitRepositoryMonitor(location: location, handler: handler)
    }

    public static let makeFolder: GitRepositoryHubServices.MakeFolderMonitor = { folder, handler in
        GitRepositoryMonitor(awaitingRepositoryIn: folder, handler: handler)
    }

    /// Files directly in a git directory whose change means HEAD, the index
    /// or the upstream counts may have moved.
    private static let headFiles: Set<String> = [
        "HEAD", "index", "ORIG_HEAD", "FETCH_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REBASE_HEAD",
    ]

    private static let logger = Logger(subsystem: "com.unpeel.git", category: "monitor")

    private let watchers: [FileSystemWatcher]

    /// Nil when FSEvents could not start a stream; the repository's views
    /// then simply do not refresh by themselves.
    public convenience init?(location: GitRepositoryLocation, latency: TimeInterval = FileSystemWatcher.defaultLatency, handler: @escaping @Sendable () -> Void) {
        self.init(roots: Self.watchedRoots(for: location), latency: latency, handler: handler) { change in
            Self.isRelevant(change, in: location)
        }
    }

    /// Watches `folder`, not a repository, for a `.git` (a directory, or a
    /// worktree's link file) appearing or changing in it — `git init`, a
    /// clone into it. Nil when the folder cannot be resolved or watched.
    public convenience init?(awaitingRepositoryIn folder: String, latency: TimeInterval = FileSystemWatcher.defaultLatency, handler: @escaping @Sendable () -> Void) {
        guard let root = CanonicalPath.resolve(folder) else { return nil }
        self.init(roots: [root], latency: latency, handler: handler) { change in
            Self.isGitAppearing(change, in: root)
        }
    }

    private init?(
        roots: [String], latency: TimeInterval, handler: @escaping @Sendable () -> Void,
        isRelevant: @escaping @Sendable (FileSystemChange) -> Bool
    ) {
        watchers = roots.map { root in
            FileSystemWatcher(root: root, latency: latency) { change in
                if isRelevant(change) { handler() }
            }
        }
        guard watchers.allSatisfy({ $0.start() }) else {
            watchers.forEach { $0.stop() }
            Self.logger.error("git watch did not start; the repository views will not refresh by themselves")
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

    /// `FileSystemChange.directories` holds every event path itself as well
    /// as its parent, so the changed files are in there to test.
    static func isRelevant(_ change: FileSystemChange, in location: GitRepositoryLocation) -> Bool {
        change.needsFullRescan || change.directories.contains { isRelevant($0, in: location) }
    }

    static func isGitAppearing(_ change: FileSystemChange, in folder: String) -> Bool {
        let dotGit = folder + "/.git"
        return change.needsFullRescan || change.directories.contains { $0 == dotGit || $0.hasPrefix(dotGit + "/") }
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
