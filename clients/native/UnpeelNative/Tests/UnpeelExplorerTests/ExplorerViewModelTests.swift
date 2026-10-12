import XCTest
@testable import UnpeelExplorer

@MainActor
final class ExplorerViewModelTests: ExplorerViewModelTestCase {
    /// Services with a REAL watcher, so watcher lifecycle is observed
    /// through the view model's own `hasActiveWatcher` rather than a fake.
    private func watchingServices() -> ExplorerServices {
        ExplorerServices(
            scan: { directory, root in
                try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { root, handler in FileSystemWatcher(root: root, handler: handler) }
        )
    }

    func testLocalContextLoadsTheRoot() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.dir("src")
        let viewModel = makeViewModel()

        await viewModel.setContext(local(tree)).value

        let model = try XCTUnwrap(viewModel.model)
        XCTAssertEqual(model.root, tree.root)
        XCTAssertEqual(model.visibleChildren(of: tree.root, filter: everything).map(\.name), ["src", "a.txt"])
        XCTAssertNil(viewModel.rootError)
    }

    func testRemoteAndNoneContextsHaveNoModel() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.setContext(.remote).value
        XCTAssertNil(viewModel.model)
        XCTAssertEqual(viewModel.context, .remote)

        await viewModel.setContext(.none).value
        XCTAssertNil(viewModel.model)
    }

    func testMissingRootReportsAnError() async {
        let viewModel = makeViewModel()

        await viewModel.setContext(.local(root: "/definitely/not/here", projectRoot: "/definitely")).value

        XCTAssertNil(viewModel.model)
        XCTAssertNotNil(viewModel.rootError)
    }

    func testExpandLoadsChildrenExactlyOnce() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/main.swift")
        let log = ScanLog()
        let viewModel = makeViewModel(services(log: log))
        await viewModel.setContext(local(tree)).value

        await viewModel.expand(tree.path("src")).value
        viewModel.collapse(tree.path("src"))
        await viewModel.expand(tree.path("src")).value

        XCTAssertEqual(log.directories, [tree.root, tree.path("src")])
        XCTAssertEqual(viewModel.model?.expanded, [tree.path("src")])
        XCTAssertEqual(
            viewModel.model?.visibleChildren(of: tree.path("src"), filter: everything).map(\.name),
            ["main.swift"]
        )
    }

    func testExpandingAFileOrUnknownPathDoesNothing() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.expand(tree.path("a.txt")).value
        await viewModel.expand(tree.path("ghost")).value

        XCTAssertEqual(viewModel.model?.expanded, [])
    }

    func testSwitchingRootsRestoresExpansionSelectionAndScroll() async throws {
        let first = try TempTree(); defer { first.remove() }
        let second = try TempTree(); defer { second.remove() }
        try first.file("src/views/App.swift")
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults)
        await viewModel.setContext(local(first)).value
        await viewModel.expand(first.path("src")).value
        await viewModel.expand(first.path("src/views")).value
        viewModel.selection = [first.path("src/views/App.swift")]
        viewModel.scrollOffset = 120

        await viewModel.setContext(local(second)).value
        XCTAssertEqual(viewModel.model?.expanded, [])
        XCTAssertEqual(viewModel.selection, [])
        let tokenBefore = viewModel.restoreToken

        await viewModel.setContext(local(first)).value

        XCTAssertEqual(viewModel.model?.expanded, [first.path("src"), first.path("src/views")])
        XCTAssertEqual(viewModel.selection, [first.path("src/views/App.swift")])
        XCTAssertEqual(viewModel.scrollOffset, 120)
        XCTAssertGreaterThan(viewModel.restoreToken, tokenBefore)
    }

    func testRestoreSkipsFoldersThatNoLongerExist() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let other = try TempTree(); defer { other.remove() }
        try tree.dir("gone/inner"); try tree.dir("kept")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("gone")).value
        await viewModel.expand(tree.path("gone/inner")).value
        await viewModel.expand(tree.path("kept")).value
        await viewModel.setContext(local(other)).value
        try FileManager.default.removeItem(atPath: tree.path("gone"))

        await viewModel.setContext(local(tree)).value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("kept")])
    }

    func testALoadFromAPreviousRootIsDiscarded() async throws {
        let slow = try TempTree(); defer { slow.remove() }
        let fast = try TempTree(); defer { fast.remove() }
        try slow.file("slow.txt"); try fast.file("fast.txt")
        let viewModel = makeViewModel(services(delay: [slow.root: 0.4]))

        let first = viewModel.setContext(local(slow))
        // Let the slow root's scan actually start, so this exercises the
        // discard in `load`, not just the early generation check in `open`.
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = viewModel.setContext(local(fast))
        await first.value
        await second.value

        XCTAssertEqual(viewModel.model?.root, fast.root)
        XCTAssertEqual(viewModel.model?.visibleChildren(of: fast.root, filter: everything).map(\.name), ["fast.txt"])
        XCTAssertNil(viewModel.model?.directories[slow.root])
    }

    func testChangesReloadOnlyTrackedDirectories() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/old.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value
        try tree.file("new.txt"); try tree.file("sub/new.txt")

        await viewModel.handleChange(
            FileSystemChange(directories: [tree.root, tree.path("sub")], touchedGitignore: false)
        ).value

        XCTAssertEqual(viewModel.model?.visibleChildren(of: tree.root, filter: everything).map(\.name), ["sub", "new.txt"])
        XCTAssertNil(viewModel.model?.directories[tree.path("sub")])
    }

    func testGitignoreChangeRescansEveryExpandedDirectory() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt"); try tree.file("other/b.txt")
        let log = ScanLog()
        let viewModel = makeViewModel(services(log: log))
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("sub")).value
        await viewModel.expand(tree.path("other")).value
        viewModel.collapse(tree.path("other"))

        await viewModel.handleChange(FileSystemChange(directories: [], touchedGitignore: true)).value

        XCTAssertEqual(
            log.directories,
            [tree.root, tree.path("sub"), tree.path("other"), tree.root, tree.path("sub")]
        )
    }

    func testADroppedEventRescansEveryExpandedDirectory() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt")
        let log = ScanLog()
        let viewModel = makeViewModel(services(log: log))
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("sub")).value

        // FSEvents names no usable directory when it drops events, so the
        // expanded set — not `directories` — is what must be reloaded.
        await viewModel.handleChange(
            FileSystemChange(directories: [], touchedGitignore: false, needsFullRescan: true)
        ).value

        XCTAssertEqual(log.directories, [tree.root, tree.path("sub"), tree.root, tree.path("sub")])
    }

    func testAVanishedExpandedFolderIsDropped() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("sub")).value
        try FileManager.default.removeItem(atPath: tree.path("sub"))

        await viewModel.handleChange(
            FileSystemChange(directories: [tree.root, tree.path("sub")], touchedGitignore: false)
        ).value

        XCTAssertEqual(viewModel.model?.loadedDirectories, [tree.root])
        XCTAssertEqual(viewModel.model?.expanded, [])
    }

    func testUnreadableFolderFailsInlineAndRetriesOnReExpand() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let locked = try tree.dir("locked")
        try tree.file("locked/secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.expand(locked).value
        guard case .failed? = viewModel.model?.directories[locked] else {
            return XCTFail("expected a failed directory")
        }
        XCTAssertNil(viewModel.rootError)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        viewModel.collapse(locked)
        await viewModel.expand(locked).value

        XCTAssertEqual(viewModel.model?.visibleChildren(of: locked, filter: everything).map(\.name), ["secret.txt"])
    }

    func testRevealExpandsAncestorsAndSelects() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let target = try tree.file("a/b/c.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.reveal(target).value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("a"), tree.path("a/b")])
        XCTAssertEqual(viewModel.selection, [target])
    }

    func testRevealOutsideTheRootIsIgnored() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.reveal("/etc/hosts").value

        XCTAssertEqual(viewModel.selection, [])
    }

    func testCollapseAllAndRefresh() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("sub")).value
        try tree.file("sub/b.txt")

        await viewModel.refresh().value
        XCTAssertEqual(viewModel.model?.visibleChildren(of: tree.path("sub"), filter: everything).map(\.name), ["a.txt", "b.txt"])

        viewModel.collapseAll()
        XCTAssertEqual(viewModel.model?.expanded, [])
    }

    func testFilterIsPersisted() {
        let defaults = makeDefaults()
        makeViewModel(defaults: defaults).setFilter(VisibilityFilter(showHidden: true, showIgnored: true))

        XCTAssertEqual(makeViewModel(defaults: defaults).filter, VisibilityFilter(showHidden: true, showIgnored: true))
    }

    func testPathHelpers() {
        XCTAssertEqual(ExplorerPaths.relative("/r/src/a.swift", to: "/r"), "src/a.swift")
        XCTAssertEqual(ExplorerPaths.relative("/r", to: "/r"), ".")
        XCTAssertEqual(ExplorerPaths.relative("/r-other/a", to: "/r"), "/r-other/a")
        XCTAssertEqual(ExplorerPaths.depth("/r/src/a.swift"), 3)
    }

    func testIsInsideDotGitMatchesWholeComponentsBelowTheRoot() {
        XCTAssertTrue(ExplorerPaths.isInsideDotGit("/r/.git", root: "/r"))
        XCTAssertTrue(ExplorerPaths.isInsideDotGit("/r/.git/refs/heads/main", root: "/r"))
        XCTAssertTrue(ExplorerPaths.isInsideDotGit("/r/sub/.git/config", root: "/r"))
        XCTAssertFalse(ExplorerPaths.isInsideDotGit("/r/src/.gitignore", root: "/r"))
        XCTAssertFalse(ExplorerPaths.isInsideDotGit("/r/.github/workflows", root: "/r"))
        XCTAssertFalse(ExplorerPaths.isInsideDotGit("/r/git/objects", root: "/r"))
        XCTAssertFalse(ExplorerPaths.isInsideDotGit("/r", root: "/r"))
        // Only components BELOW the root count: a root that itself lives in
        // a `.git` directory still lists its own contents.
        XCTAssertFalse(ExplorerPaths.isInsideDotGit("/r/.git/hooks", root: "/r/.git"))
    }

    // MARK: - Review fixes

    func testFastContextSwitchDoesNotWipeSavedViewState() async throws {
        let a = try TempTree(); defer { a.remove() }
        let b = try TempTree(); defer { b.remove() }
        try a.file("src/App.swift")
        let defaults = makeDefaults()

        // Establish A's saved state with an ordinary (non-racing) view model.
        let setup = makeViewModel(defaults: defaults)
        await setup.setContext(local(a)).value
        await setup.expand(a.path("src")).value
        setup.selection = [a.path("src/App.swift")]
        setup.scrollOffset = 42
        setup.persistState()

        // A's own root scan is slow, so switching to B lands while `open(A)`
        // is still publishing its `.loading` placeholder — before A ever
        // reaches `restoreState`.
        let viewModel = makeViewModel(services(delay: [a.root: 0.4]), defaults: defaults)
        let openA = viewModel.setContext(local(a))
        try await Task.sleep(nanoseconds: 100_000_000)
        let openB = viewModel.setContext(local(b))
        await openA.value
        await openB.value

        await viewModel.setContext(local(a)).value

        XCTAssertEqual(viewModel.model?.expanded, [a.path("src")])
        XCTAssertEqual(viewModel.selection, [a.path("src/App.swift")])
        XCTAssertEqual(viewModel.scrollOffset, 42)
    }

    func testAbandonedRestoreDoesNotCorruptEitherRootsSavedState() async throws {
        let a = try TempTree(); defer { a.remove() }
        let b = try TempTree(); defer { b.remove() }
        try a.file("src/views/App.swift")
        try b.file("lib/utils/Helper.swift")
        let defaults = makeDefaults()

        let setupA = makeViewModel(defaults: defaults)
        await setupA.setContext(local(a)).value
        await setupA.expand(a.path("src")).value
        await setupA.expand(a.path("src/views")).value
        setupA.selection = [a.path("src/views/App.swift")]
        setupA.scrollOffset = 10
        setupA.persistState()
        let savedA = RootViewState(
            expanded: [a.path("src"), a.path("src/views")],
            selection: [a.path("src/views/App.swift")],
            scrollOffset: 10
        )

        let setupB = makeViewModel(defaults: defaults)
        await setupB.setContext(local(b)).value
        await setupB.expand(b.path("lib")).value
        await setupB.expand(b.path("lib/utils")).value
        setupB.selection = [b.path("lib/utils/Helper.swift")]
        setupB.scrollOffset = 20
        setupB.persistState()
        let savedB = RootViewState(
            expanded: [b.path("lib"), b.path("lib/utils")],
            selection: [b.path("lib/utils/Helper.swift")],
            scrollOffset: 20
        )

        // A's restore starts expanding "src" (slow); B is opened before that
        // finishes, and B's own restore (also slow, on "lib") is still in
        // flight when A's abandoned expand finally completes.
        let viewModel = makeViewModel(
            services(delay: [a.path("src"): 0.25, b.path("lib"): 0.3, b.path("lib/utils"): 0.05]),
            defaults: defaults
        )

        let openA = viewModel.setContext(local(a))
        try await Task.sleep(nanoseconds: 100_000_000)
        let openB = viewModel.setContext(local(b))
        await openA.value
        await openB.value

        let freshStore = ExplorerStateStore(defaults: defaults)
        XCTAssertEqual(freshStore.state(forRoot: a.root), savedA)
        XCTAssertEqual(freshStore.state(forRoot: b.root), savedB)
    }

    func testAStaleLoadOfTheSameDirectoryIsDiscarded() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let counter = ScanCallCounter()
        let viewModel = makeViewModel(ExplorerServices(
            scan: { directory, root in
                // Capture the listing before sleeping, so a "stale" result
                // reflects the directory's contents at the time the scan
                // started, not when it finishes.
                let listing = try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
                if directory == root, counter.next(for: directory) == 2 {
                    Thread.sleep(forTimeInterval: 0.4)
                }
                return listing
            },
            makeWatcher: { _, _ in nil }
        ))
        await viewModel.setContext(local(tree)).value // call #1: fast initial load

        // call #2: slow reload, started before "b.txt" exists
        let slow = viewModel.handleChange(FileSystemChange(directories: [tree.root], touchedGitignore: false))
        try await Task.sleep(nanoseconds: 100_000_000)
        try tree.file("b.txt")
        // call #3: fast reload, started after "b.txt" exists
        let fast = viewModel.handleChange(FileSystemChange(directories: [tree.root], touchedGitignore: false))

        await slow.value
        await fast.value

        XCTAssertEqual(
            viewModel.model?.visibleChildren(of: tree.root, filter: everything).map(\.name).sorted(),
            ["a.txt", "b.txt"]
        )
    }

    func testRevealCanonicalizesANonCanonicalPath() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        guard tree.root.hasPrefix("/private/") else {
            throw XCTSkip("temp root is not under /private, cannot build a non-canonical alias")
        }
        let target = try tree.file("a/b/c.txt")
        let alias = String(target.dropFirst("/private".count))
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.reveal(alias).value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("a"), tree.path("a/b")])
        XCTAssertEqual(viewModel.selection, [target])
    }

    func testRetryRecoversAfterTheRootIsCreated() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let missing = tree.path("not-yet")
        let viewModel = makeViewModel()

        await viewModel.setContext(.local(root: missing, projectRoot: tree.root)).value
        XCTAssertNotNil(viewModel.rootError)
        XCTAssertNil(viewModel.model)

        try FileManager.default.createDirectory(atPath: missing, withIntermediateDirectories: true)
        await viewModel.retry().value

        XCTAssertNil(viewModel.rootError)
        XCTAssertEqual(viewModel.model?.root, missing)
    }

    func testRefreshReportsAnErrorWhenTheRootBecomesUnreadableAndRetryRecovers() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tree.root)
        await viewModel.refresh().value

        XCTAssertNotNil(viewModel.rootError)
        XCTAssertNil(viewModel.model)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.root)
        await viewModel.retry().value

        XCTAssertNil(viewModel.rootError)
        XCTAssertEqual(viewModel.model?.visibleChildren(of: tree.root, filter: everything).map(\.name), ["a.txt"])
    }

    func testRestoreTokenAdvancesEvenWithNoSavedState() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let viewModel = makeViewModel()
        let before = viewModel.restoreToken

        await viewModel.setContext(local(tree)).value

        XCTAssertGreaterThan(viewModel.restoreToken, before)
    }

    /// `.git` is never listed: `expand`/`reveal` must refuse it outright,
    /// not merely hide its rows — expanding it would scan it into the model
    /// and persist it into the saved expansion set.
    func testRevealIntoDotGitDoesNothing() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let target = try tree.file(".git/refs/heads/main")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.reveal(target).value

        XCTAssertEqual(viewModel.model?.expanded, [])
        XCTAssertEqual(viewModel.selection, [])
        XCTAssertNil(viewModel.model?.directories[tree.path(".git")])
    }

    func testASavedDotGitExpansionIsNotReplayed() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file(".git/config")
        try tree.file("src/a.txt")
        let defaults = makeDefaults()
        ExplorerStateStore(defaults: defaults).save(
            RootViewState(expanded: [tree.path(".git"), tree.path("src")], selection: [], scrollOffset: 0),
            forRoot: tree.root
        )
        let viewModel = makeViewModel(defaults: defaults)

        await viewModel.setContext(local(tree)).value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("src")])
        XCTAssertNil(viewModel.model?.directories[tree.path(".git")])
    }

    /// Spec §3.5: a failed root leaves no FSEvents stream running, and a
    /// successful retry builds a new one.
    func testAFailedRootLoadTearsDownTheWatcherAndRetryRebuildsIt() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = makeViewModel(watchingServices())

        await viewModel.setContext(local(tree)).value
        XCTAssertTrue(viewModel.hasActiveWatcher)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tree.root)
        await viewModel.refresh().value
        XCTAssertNotNil(viewModel.rootError)
        XCTAssertFalse(viewModel.hasActiveWatcher)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.root)
        await viewModel.retry().value

        XCTAssertNil(viewModel.rootError)
        XCTAssertTrue(viewModel.hasActiveWatcher)
    }

    func testRootUnavailableUsesTheSameMessageShapeForMissingAndUnreadableRoots() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let missingRoot = tree.path("nope")
        let missingViewModel = makeViewModel()
        await missingViewModel.setContext(.local(root: missingRoot, projectRoot: tree.root)).value

        let unreadableViewModel = makeViewModel()
        await unreadableViewModel.setContext(local(tree)).value
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tree.root)
        await unreadableViewModel.refresh().value
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.root)

        XCTAssertEqual(missingViewModel.rootError, ExplorerError.rootUnavailable(missingRoot).localizedDescription)
        XCTAssertEqual(unreadableViewModel.rootError, ExplorerError.rootUnavailable(tree.root).localizedDescription)
    }
}
