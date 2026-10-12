import Combine
import UnpeelGit
import XCTest
@testable import UnpeelExplorer

/// Git Status Decorations in the EXPLORER's view model, against real
/// throwaway repositories (no mocked git).
@MainActor
final class ExplorerDecorationTests: ExplorerViewModelTestCase {
    private func hub(reader: GitReader = GitReader(), log: SnapshotReadLog? = nil) -> GitRepositoryHub {
        GitRepositoryHub(services: GitRepositoryHubServices(read: { root in
            if let delay = log?.record(root) { Thread.sleep(forTimeInterval: delay) }
            return reader.snapshot(at: root)
        }))
    }

    private func makeViewModel(_ hub: GitRepositoryHub, debounce: TimeInterval = 0) -> ExplorerViewModel {
        makeViewModel(services(repositories: hub), decorationDebounce: debounce)
    }

    func testChangedFilesAndTheirFoldersAreDecorated() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a"); try tree.file("src/b.swift", "b")
        try tree.initRepository()
        try tree.file("a.txt", "edited")
        try tree.file("src/new.swift", "new")
        let viewModel = makeViewModel(hub())

        await viewModel.setContext(local(tree)).value

        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("a.txt")), .modified)
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("src/new.swift")), .untracked)
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("src")), .untracked)
        XCTAssertNil(viewModel.decorations.kind(at: tree.path("src/b.swift")))
    }

    func testADeletedFileAddsNoRowButMarksItsFolder() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("lib/gone.c", "x"); try tree.file("lib/kept.c", "y")
        try tree.initRepository()
        try FileManager.default.removeItem(atPath: tree.path("lib/gone.c"))
        let viewModel = makeViewModel(hub())

        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("lib")).value

        XCTAssertEqual(viewModel.model?.visibleChildren(of: tree.path("lib"), filter: everything).map(\.name), ["kept.c"])
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("lib")), .deleted)
    }

    func testANonRepositoryLeavesTheTreeAsBefore() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = makeViewModel(hub())

        await viewModel.setContext(local(tree)).value

        XCTAssertTrue(viewModel.decorations.isEmpty)
        XCTAssertNil(viewModel.rootError)
        XCTAssertEqual(viewModel.model?.visibleChildren(of: tree.root, filter: everything).map(\.name), ["a.txt"])
    }

    func testWithoutGitTheTreeIsAsBefore() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.initRepository(); try tree.file("a.txt", "edited")
        let noGit = GitReader(runner: GitRunner(resolver: GitExecutableResolver { nil }))
        let viewModel = makeViewModel(hub(reader: noGit))

        await viewModel.setContext(local(tree)).value

        XCTAssertTrue(viewModel.decorations.isEmpty)
        XCTAssertNil(viewModel.rootError)
        XCTAssertEqual(viewModel.model?.visibleChildren(of: tree.root, filter: everything).map(\.name), ["a.txt"])
    }

    func testDecorationsFollowEditsAndRefresh() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a"); try tree.file("b.txt", "b")
        try tree.initRepository()
        let viewModel = makeViewModel(hub())
        await viewModel.setContext(local(tree)).value
        XCTAssertTrue(viewModel.decorations.isEmpty)

        try tree.file("a.txt", "edited")
        await viewModel.handleChange(FileSystemChange(directories: [tree.root, tree.path("a.txt")], touchedGitignore: false)).value
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("a.txt")), .modified)

        try tree.file("b.txt", "edited")
        await viewModel.refresh().value
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("b.txt")), .modified)
    }

    /// A burst of watcher batches costs one status read, not one per batch.
    func testABurstOfChangesIsOneStatusRead() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.initRepository()
        let log = SnapshotReadLog()
        let viewModel = makeViewModel(hub(log: log), debounce: 0.05)
        await viewModel.setContext(local(tree)).value
        XCTAssertEqual(log.roots.count, 1)

        let tasks = (0..<5).map { index in
            viewModel.handleChange(FileSystemChange(directories: [tree.path("f\(index).txt"), tree.root], touchedGitignore: false))
        }
        for task in tasks { await task.value }

        XCTAssertEqual(log.roots.count, 2)
    }

    /// Collapsing the EXPLORER stops its watcher, but Git History can keep
    /// following the root (and its last read) meanwhile. Edits made while
    /// collapsed must show when it opens again.
    func testReopeningWhileAnotherViewFollowsTheRootShowsEditsMadeMeanwhile() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a"); try tree.initRepository()
        let hub = hub()
        let history = hub.subscribe(root: tree.root)
        defer { history.cancel() }
        _ = await hub.status(root: tree.root)
        let viewModel = makeViewModel(hub)
        await viewModel.setContext(local(tree)).value
        await viewModel.setContext(.none).value

        try tree.file("a.txt", "edited while collapsed")
        await viewModel.setContext(local(tree)).value

        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("a.txt")), .modified)
    }

    /// A root that fails to load shows no decorations, even when its
    /// status read finishes afterwards.
    func testAFailedRootShowsNoDecorations() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.initRepository(); try tree.file("a.txt", "edited")
        let log = SnapshotReadLog()
        log.setDelay(0.3, for: tree.root)
        let viewModel = makeViewModel(ExplorerServices(
            scan: { _, _ in throw CocoaError(.fileReadNoPermission) },
            makeWatcher: { _, _ in nil },
            repositories: hub(log: log)
        ))

        await viewModel.setContext(local(tree)).value
        XCTAssertNotNil(viewModel.rootError)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(viewModel.decorations.isEmpty)
    }

    /// A slow read for the root being left is never shown for the next one.
    func testSwitchingRootsNeverShowsThePreviousRootsDecorations() async throws {
        let slow = try TempTree(); defer { slow.remove() }
        let next = try TempTree(); defer { next.remove() }
        try slow.file("a.txt"); try slow.initRepository(); try slow.file("a.txt", "edited")
        try next.file("b.txt")
        let log = SnapshotReadLog()
        log.setDelay(0.3, for: slow.root)
        let viewModel = makeViewModel(hub(log: log))
        var shown: [GitDecorations] = []
        let observation = viewModel.$decorations.sink { shown.append($0) }
        defer { observation.cancel() }

        let first = viewModel.setContext(local(slow))
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = viewModel.setContext(local(next))
        await first.value
        await second.value

        XCTAssertTrue(viewModel.decorations.isEmpty)
        XCTAssertTrue(shown.allSatisfy { $0.kind(at: slow.path("a.txt")) == nil })
    }
}
