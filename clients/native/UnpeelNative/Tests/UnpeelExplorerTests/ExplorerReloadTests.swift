import XCTest
@testable import UnpeelExplorer

/// Fork-only: git support (#2). Watcher reloads coalesce under a burst of
/// agent writes and skip folders that are not on screen; opening and
/// expanding wait for a reload that superseded their own scan.
@MainActor
final class ExplorerReloadTests: ExplorerViewModelTestCase {
    /// Batches that arrive while a reload is still scanning do not each
    /// start a chain of their own: the chain in flight gives way, and one
    /// reload covers the union of everything that changed.
    func testABurstOfBatchesDuringAReloadIsOneCoalescedReload() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a/x.txt"); try tree.file("b/x.txt"); try tree.file("c/x.txt")
        let log = ScanLog()
        let counter = ScanCallCounter()
        let viewModel = makeViewModel(ExplorerServices(
            scan: { directory, root in
                log.record(directory)
                if directory == root, counter.next(for: directory) == 2 {
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { _, _ in nil }
        ))
        await viewModel.setContext(local(tree)).value
        for name in ["a", "b", "c"] { await viewModel.expand(tree.path(name)).value }
        let before = log.directories.count

        let first = viewModel.handleChange(FileSystemChange(directories: [tree.root, tree.path("a")], touchedGitignore: false))
        try await Task.sleep(nanoseconds: 100_000_000)
        let burst = [
            viewModel.handleChange(FileSystemChange(directories: [tree.path("a")], touchedGitignore: false)),
            viewModel.handleChange(FileSystemChange(directories: [tree.path("b")], touchedGitignore: false)),
            viewModel.handleChange(FileSystemChange(directories: [tree.path("a"), tree.path("c")], touchedGitignore: false)),
        ]
        await first.value
        for task in burst { await task.value }

        let reloads = Array(log.directories.dropFirst(before))
        XCTAssertEqual(reloads.first, tree.root)
        XCTAssertEqual(reloads.dropFirst().sorted(), [tree.path("a"), tree.path("b"), tree.path("c")])
    }

    /// Switching roots mid-reload ends the chain: nothing more of the old
    /// root is scanned, and what was in flight is never applied.
    func testAReloadInFlightStopsWhenTheRootChanges() async throws {
        let first = try TempTree(); defer { first.remove() }
        let second = try TempTree(); defer { second.remove() }
        try first.file("a/x.txt"); try second.file("y.txt")
        let log = ScanLog()
        let counter = ScanCallCounter()
        let viewModel = makeViewModel(ExplorerServices(
            scan: { directory, root in
                log.record(directory)
                if directory == root, counter.next(for: directory) == 2 {
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { _, _ in nil }
        ))
        await viewModel.setContext(local(first)).value
        await viewModel.expand(first.path("a")).value

        let reload = viewModel.refresh()
        try await Task.sleep(nanoseconds: 100_000_000)
        await viewModel.setContext(local(second)).value
        await reload.value

        XCTAssertEqual(log.directories.filter { $0 == first.path("a") }.count, 1)
        XCTAssertEqual(viewModel.model?.root, second.root)
        XCTAssertEqual(viewModel.model?.visibleChildren(of: second.root, filter: everything).map(\.name), ["y.txt"])
    }

    /// A watcher batch can reload the root while its first scan is still
    /// running; that first result is then stale and dropped. Opening must
    /// wait for the reload's contents rather than replay the saved
    /// expansions (or a pending reveal) against a root still loading.
    func testOpeningWaitsForAReloadThatSupersedesTheFirstScan() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt")
        let defaults = makeDefaults()
        ExplorerStateStore(defaults: defaults).save(
            RootViewState(expanded: [tree.path("sub")], selection: [tree.path("sub/a.txt")], scrollOffset: 0),
            forRoot: tree.root
        )
        let counter = ScanCallCounter()
        let viewModel = makeViewModel(ExplorerServices(
            scan: { directory, root in
                if directory == root {
                    switch counter.next(for: directory) {
                    case 1: Thread.sleep(forTimeInterval: 0.2)
                    case 2: Thread.sleep(forTimeInterval: 0.4)
                    default: break
                    }
                }
                return try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { _, _ in nil }
        ), defaults: defaults)

        let opening = viewModel.setContext(local(tree))
        try await Task.sleep(nanoseconds: 100_000_000)
        let reload = viewModel.handleChange(FileSystemChange(directories: [tree.root], touchedGitignore: false))
        await opening.value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("sub")])
        XCTAssertEqual(viewModel.selection, [tree.path("sub/a.txt")])
        await reload.value
    }

    /// The same race on an expansion: a reveal right after it must find the
    /// folder's contents, not a folder still loading.
    func testExpandingWaitsForAReloadThatSupersedesItsScan() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let target = try tree.file("sub/a.txt")
        let counter = ScanCallCounter()
        let viewModel = makeViewModel(ExplorerServices(
            scan: { directory, root in
                if directory.hasSuffix("/sub") {
                    switch counter.next(for: directory) {
                    case 1: Thread.sleep(forTimeInterval: 0.2)
                    case 2: Thread.sleep(forTimeInterval: 0.4)
                    default: break
                    }
                }
                return try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { _, _ in nil }
        ))
        await viewModel.setContext(local(tree)).value

        let revealing = viewModel.reveal(target)
        try await Task.sleep(nanoseconds: 100_000_000)
        let reload = viewModel.handleChange(FileSystemChange(directories: [tree.path("sub")], touchedGitignore: false))
        await revealing.value

        XCTAssertEqual(viewModel.selection, [target])
        await reload.value
    }

    /// A collapsed folder keeps its contents for an instant re-expand, but
    /// watcher reloads and Refresh skip it; expanding it rescans it.
    func testCollapsedFoldersAreSkippedAndRescannedWhenExpanded() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt")
        let log = ScanLog()
        let viewModel = makeViewModel(services(log: log))
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("sub")).value
        viewModel.collapse(tree.path("sub"))
        try tree.file("sub/b.txt")
        let before = log.directories.count

        await viewModel.handleChange(
            FileSystemChange(directories: [tree.root, tree.path("sub")], touchedGitignore: false)
        ).value
        await viewModel.refresh().value
        XCTAssertEqual(Array(log.directories.dropFirst(before)), [tree.root, tree.root])

        await viewModel.expand(tree.path("sub")).value

        XCTAssertEqual(log.directories.last, tree.path("sub"))
        XCTAssertEqual(
            viewModel.model?.visibleChildren(of: tree.path("sub"), filter: everything).map(\.name),
            ["a.txt", "b.txt"]
        )
    }

    /// A folder that stays expanded under a collapsed parent is not on
    /// screen either; it is rescanned once its parent shows it again.
    func testAnExpandedFolderUnderACollapsedParentIsRescannedWhenShownAgain() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a/b/old.txt")
        let log = ScanLog()
        let viewModel = makeViewModel(services(log: log))
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("a")).value
        await viewModel.expand(tree.path("a/b")).value
        viewModel.collapse(tree.path("a"))
        try tree.file("a/b/new.txt")
        let before = log.directories.count

        await viewModel.handleChange(FileSystemChange(directories: [tree.path("a/b")], touchedGitignore: false)).value
        XCTAssertEqual(log.directories.count, before)

        await viewModel.expand(tree.path("a")).value

        XCTAssertEqual(Array(log.directories.dropFirst(before)), [tree.path("a/b")])
        XCTAssertEqual(
            viewModel.model?.visibleChildren(of: tree.path("a/b"), filter: everything).map(\.name),
            ["new.txt", "old.txt"]
        )
    }
}
