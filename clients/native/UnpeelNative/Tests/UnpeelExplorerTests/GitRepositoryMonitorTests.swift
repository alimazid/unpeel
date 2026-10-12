import UnpeelGit
import XCTest
@testable import UnpeelExplorer

private final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

final class GitRepositoryMonitorTests: XCTestCase {
    private let main = GitRepositoryLocation(workTree: "/r", gitDirectory: "/r/.git", commonDirectory: "/r/.git")
    private let worktree = GitRepositoryLocation(
        workTree: "/wt", gitDirectory: "/r/.git/worktrees/wt", commonDirectory: "/r/.git"
    )

    func testIndexHeadAndRefsAreRelevant() {
        for path in ["/r/.git/index", "/r/.git/HEAD", "/r/.git/FETCH_HEAD", "/r/.git/ORIG_HEAD",
                     "/r/.git/packed-refs", "/r/.git/refs/heads/main", "/r/.git/refs/remotes/origin/main",
                     "/r/.git/refs/tags/v1"] {
            XCTAssertTrue(GitRepositoryMonitor.isRelevant(path, in: main), path)
        }
    }

    func testObjectsLogsLocksAndTheWorkTreeAreNot() {
        for path in ["/r/.git/objects/ab/cdef", "/r/.git/logs/HEAD", "/r/.git/index.lock",
                     "/r/.git/refs/heads/main.lock", "/r/.git", "/r/.git/hooks/pre-commit",
                     "/r/src/main.swift", "/r/.git/worktrees/wt/HEAD"] {
            XCTAssertFalse(GitRepositoryMonitor.isRelevant(path, in: main), path)
        }
    }

    /// A worktree's own HEAD and index live in its git dir; branches are
    /// shared through the common dir. Another worktree's HEAD or index is
    /// not this Explorer Root's business.
    func testAWorktreeWatchesItsOwnHeadAndTheSharedRefs() {
        XCTAssertTrue(GitRepositoryMonitor.isRelevant("/r/.git/worktrees/wt/HEAD", in: worktree))
        XCTAssertTrue(GitRepositoryMonitor.isRelevant("/r/.git/worktrees/wt/index", in: worktree))
        XCTAssertTrue(GitRepositoryMonitor.isRelevant("/r/.git/refs/heads/feature", in: worktree))
        XCTAssertFalse(GitRepositoryMonitor.isRelevant("/r/.git/HEAD", in: worktree))
        XCTAssertFalse(GitRepositoryMonitor.isRelevant("/r/.git/index", in: worktree))
        XCTAssertFalse(GitRepositoryMonitor.isRelevant("/r/.git/worktrees/other/HEAD", in: worktree))
    }

    func testADroppedEventBatchIsRelevant() {
        let dropped = FileSystemChange(directories: ["/r/.git/objects"], touchedGitignore: false, needsFullRescan: true)
        XCTAssertTrue(GitRepositoryMonitor.isRelevant(dropped, in: main))
        let objects = FileSystemChange.from(eventPaths: ["/r/.git/objects/ab/cdef"])
        XCTAssertFalse(GitRepositoryMonitor.isRelevant(objects, in: main))
        let commit = FileSystemChange.from(eventPaths: ["/r/.git/objects/ab/cdef", "/r/.git/refs/heads/main"])
        XCTAssertTrue(GitRepositoryMonitor.isRelevant(commit, in: main))
    }

    /// A folder that is not a repository only cares about a `.git` in it.
    func testAFolderAwaitingARepositoryHearsOnlyItsDotGit() {
        XCTAssertTrue(GitRepositoryMonitor.isGitAppearing(.from(eventPaths: ["/p/.git"]), in: "/p"))
        XCTAssertTrue(GitRepositoryMonitor.isGitAppearing(.from(eventPaths: ["/p/.git/HEAD"]), in: "/p"))
        XCTAssertFalse(GitRepositoryMonitor.isGitAppearing(.from(eventPaths: ["/p/notes.txt"]), in: "/p"))
        XCTAssertFalse(GitRepositoryMonitor.isGitAppearing(.from(eventPaths: ["/p/sub/.git/HEAD"]), in: "/p"))
        XCTAssertFalse(GitRepositoryMonitor.isGitAppearing(.from(eventPaths: ["/p/.github/ci.yml"]), in: "/p"))
        let dropped = FileSystemChange(directories: [], touchedGitignore: false, needsFullRescan: true)
        XCTAssertTrue(GitRepositoryMonitor.isGitAppearing(dropped, in: "/p"))
    }

    func testOneWatchCoversAWorktreeInsideItsCommonDirectory() {
        XCTAssertEqual(GitRepositoryMonitor.watchedRoots(for: main), ["/r/.git"])
        XCTAssertEqual(GitRepositoryMonitor.watchedRoots(for: worktree), ["/r/.git"])
        let separate = GitRepositoryLocation(workTree: "/w", gitDirectory: "/elsewhere/git", commonDirectory: "/r/.git")
        XCTAssertEqual(GitRepositoryMonitor.watchedRoots(for: separate), ["/r/.git", "/elsewhere/git"])
    }

    // MARK: - Real FSEvents

    private func git(_ arguments: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "T"; environment["GIT_AUTHOR_EMAIL"] = "t@example.com"
        environment["GIT_COMMITTER_NAME"] = "T"; environment["GIT_COMMITTER_EMAIL"] = "t@example.com"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testACommitSignalsAndAWorkTreeEditDoesNot() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try git(["init", "-q", "-b", "main"], in: tree.root)
        try tree.file("a.txt", "a")
        try git(["add", "-A"], in: tree.root)
        try git(["commit", "-q", "-m", "first"], in: tree.root)
        let location = try GitReader().repository(at: tree.root).get()
        let counter = SignalCounter()
        let monitor = try XCTUnwrap(GitRepositoryMonitor(location: location, latency: 0.05) { counter.record() })
        defer { monitor.stop() }

        try tree.file("a.txt", "edited")
        try tree.file("b.txt", "new")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(counter.value, 0, "working-tree edits are the EXPLORER's business")

        try git(["commit", "-q", "-am", "second"], in: tree.root)
        waitFor { counter.value > 0 }
        XCTAssertGreaterThan(counter.value, 0)
    }

    func testStoppedMonitorStaysQuiet() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try git(["init", "-q", "-b", "main"], in: tree.root)
        let location = try GitReader().repository(at: tree.root).get()
        let counter = SignalCounter()
        let monitor = try XCTUnwrap(GitRepositoryMonitor(location: location, latency: 0.05) { counter.record() })

        monitor.stop()
        try git(["commit", "-q", "--allow-empty", "-m", "first"], in: tree.root)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        XCTAssertEqual(counter.value, 0)
    }
}
