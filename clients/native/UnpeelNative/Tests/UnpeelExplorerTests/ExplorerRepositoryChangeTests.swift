import UnpeelGit
import XCTest
@testable import UnpeelExplorer

/// A monitor that only records whether it was stopped.
private final class RecordedMonitor: GitChangeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

/// Fork-only: git support. Git Status Decorations stay right after changes
/// that touch only the repository (#5): the hub's repository-change signal,
/// driven by real FSEvents on real repositories, with the EXPLORER's own
/// watcher off so no working-tree event can be what refreshed them.
@MainActor
final class ExplorerRepositoryChangeTests: ExplorerViewModelTestCase {
    private func liveHub(log: SnapshotReadLog? = nil) -> GitRepositoryHub {
        let reader = GitReader()
        return GitRepositoryHub(services: GitRepositoryHubServices(
            read: { root in
                _ = log?.record(root)
                return reader.snapshot(at: root)
            },
            makeMonitor: GitRepositoryMonitor.make,
            makeFolderMonitor: GitRepositoryMonitor.makeFolder
        ))
    }

    private func makeViewModel(_ hub: GitRepositoryHub) -> ExplorerViewModel {
        makeViewModel(services(repositories: hub), decorationDebounce: 0.05)
    }

    func testAnExternalCommitClearsTheCommittedFiles() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a"); try tree.initRepository()
        try tree.file("a.txt", "edited")
        let viewModel = makeViewModel(liveHub())
        await viewModel.setContext(local(tree.root)).value
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("a.txt")), .modified)

        try tree.git("commit", "-q", "-am", "agent commit")
        await waitUntil { viewModel.decorations.isEmpty }

        XCTAssertTrue(viewModel.decorations.isEmpty)
    }

    func testAnExternalCheckoutShowsTheNewBranchsTree() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a"); try tree.initRepository()
        try tree.git("checkout", "-q", "-b", "topic")
        try tree.file("topic.txt", "t"); try tree.git("add", "-A"); try tree.git("commit", "-q", "-m", "topic")
        try tree.git("checkout", "-q", "main")
        try tree.file("a.txt", "edited")
        try tree.file("notes.txt", "untracked")
        let viewModel = makeViewModel(liveHub())
        await viewModel.setContext(local(tree.root)).value
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("a.txt")), .modified)

        try tree.git("checkout", "-q", "-f", "topic")
        await waitUntil { viewModel.decorations.kind(at: tree.path("a.txt")) == nil }

        XCTAssertNil(viewModel.decorations.kind(at: tree.path("a.txt")))
        XCTAssertNil(viewModel.decorations.kind(at: tree.path("topic.txt")))
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("notes.txt")), .untracked)
    }

    /// A worktree's decorations follow its own HEAD and index; the main
    /// checkout staging something is not its business.
    func testAWorktreeFollowsItsOwnGitDirectoryOnly() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let parent = try TempTree(); defer { parent.remove() }
        try tree.file("a.txt", "a"); try tree.file("b.txt", "b"); try tree.initRepository()
        let worktree = parent.path("wt")
        try tree.git("worktree", "add", "-q", worktree, "-b", "feature")
        try "edited".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        let log = SnapshotReadLog()
        let viewModel = makeViewModel(liveHub(log: log))
        await viewModel.setContext(local(worktree)).value
        XCTAssertEqual(viewModel.decorations.kind(at: worktree + "/a.txt"), .modified)
        let reads = log.roots.count

        try tree.file("b.txt", "main edit"); try tree.git("add", "b.txt")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(log.roots.count, reads, "the main checkout's index is not the worktree's")

        try tree.git("commit", "-q", "-am", "in the worktree", in: worktree)
        await waitUntil { viewModel.decorations.isEmpty }
        XCTAssertTrue(viewModel.decorations.isEmpty)
    }

    /// A folder that becomes a repository is noticed without reselecting
    /// the Session.
    func testGitInitInTheFolderIsNoticed() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a"); try tree.file("notes.txt", "n")
        let viewModel = makeViewModel(liveHub())
        await viewModel.setContext(local(tree.root)).value
        XCTAssertTrue(viewModel.decorations.isEmpty)

        try tree.git("init", "-q", "-b", "main")
        try tree.git("add", "a.txt"); try tree.git("commit", "-q", "-m", "first")
        await waitUntil { viewModel.decorations.kind(at: tree.path("notes.txt")) == .untracked }

        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("notes.txt")), .untracked)
        XCTAssertNil(viewModel.decorations.kind(at: tree.path("a.txt")))
    }

    /// A repository removed from under the root is noticed too; the folder
    /// is then watched for a new one.
    func testRemovingTheRepositoryClearsTheDecorationsAndANewOneIsNoticed() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a"); try tree.initRepository()
        try tree.file("a.txt", "edited")
        let viewModel = makeViewModel(liveHub())
        await viewModel.setContext(local(tree.root)).value
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("a.txt")), .modified)

        try FileManager.default.removeItem(atPath: tree.path(".git"))
        await waitUntil { viewModel.decorations.isEmpty }
        XCTAssertTrue(viewModel.decorations.isEmpty)

        try tree.git("init", "-q", "-b", "main")
        await waitUntil { viewModel.decorations.kind(at: tree.path("a.txt")) == .untracked }
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("a.txt")), .untracked)
    }

    /// One watch per Explorer Root, released when the root changes.
    func testTheWatchIsReleasedWhenTheRootChanges() async throws {
        let first = try TempTree(); defer { first.remove() }
        let second = try TempTree(); defer { second.remove() }
        try first.file("a.txt"); try first.initRepository()
        try second.file("b.txt"); try second.initRepository()
        let monitors = MonitorLog()
        let hub = GitRepositoryHub(services: GitRepositoryHubServices(
            read: { GitReader().snapshot(at: $0) },
            makeMonitor: { location, _ in monitors.make(location.workTree) },
            makeFolderMonitor: { folder, _ in monitors.make(folder) }
        ))
        let viewModel = makeViewModel(hub)

        await viewModel.setContext(local(first.root)).value
        await viewModel.refresh().value
        XCTAssertEqual(monitors.active, [first.root])

        await viewModel.setContext(local(second.root)).value
        XCTAssertEqual(monitors.active, [second.root])

        await viewModel.setContext(.none).value
        XCTAssertEqual(monitors.active, [])
    }

    /// The EXPLORER's own watcher also sees the root's `.git`; a batch only
    /// inside it is left to the repository signal rather than read twice.
    func testABatchOnlyInsideDotGitDoesNotReadTheStatus() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.initRepository()
        let log = SnapshotReadLog()
        let viewModel = makeViewModel(liveHub(log: log))
        await viewModel.setContext(local(tree.root)).value
        let reads = log.roots.count

        await viewModel.handleChange(FileSystemChange.from(eventPaths: [
            tree.path(".git/index"), tree.path(".git/refs/heads/main"), tree.path(".git"),
        ])).value
        XCTAssertEqual(log.roots.count, reads)

        await viewModel.handleChange(FileSystemChange.from(eventPaths: [tree.path(".git/index"), tree.path("a.txt")])).value
        XCTAssertEqual(log.roots.count, reads + 1)
    }
}

/// Monitors handed out by a hub, by the path they watch.
private final class MonitorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [(path: String, monitor: RecordedMonitor)] = []

    func make(_ path: String) -> RecordedMonitor {
        let monitor = RecordedMonitor()
        lock.lock(); defer { lock.unlock() }
        made.append((path, monitor))
        return monitor
    }

    var active: [String] {
        lock.lock(); defer { lock.unlock() }
        return made.filter { !$0.monitor.isStopped }.map(\.path)
    }
}
