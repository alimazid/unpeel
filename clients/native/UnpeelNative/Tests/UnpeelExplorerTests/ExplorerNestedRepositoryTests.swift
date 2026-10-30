import AppKit
import UnpeelGit
import XCTest
@testable import UnpeelExplorer

/// Fork-only: nested repositories. Git Status Decorations for an Explorer
/// Root that is not a repository come from the nested repository chosen in
/// it, against real throwaway repositories. The tree itself never changes.
@MainActor
final class ExplorerNestedRepositoryTests: ExplorerViewModelTestCase {
    private var choiceDefaults: UserDefaults!

    override func setUp() async throws {
        choiceDefaults = makeDefaults()
    }

    private func makeViewModel(log: ScanLog? = nil) -> (ExplorerViewModel, GitRepositoryRoots) {
        let hub = GitRepositoryHub(services: .reading(GitReader()))
        let roots = GitRepositoryRoots(hub: hub, choices: GitRepositoryChoiceStore(defaults: choiceDefaults))
        let viewModel = makeViewModel(services(log: log, repositories: hub, roots: roots))
        return (viewModel, roots)
    }

    /// A repository at `relative` with `a.txt` committed, then edited, and
    /// `new.txt` untracked.
    private func nestedRepository(_ tree: TempTree, _ relative: String) throws {
        try tree.file("\(relative)/a.txt", "a")
        let folder = tree.path(relative)
        try tree.git("init", "-q", "-b", "main", in: folder)
        try tree.git("add", "-A", in: folder)
        try tree.git("commit", "-q", "-m", "first", in: folder)
        try tree.file("\(relative)/a.txt", "edited")
        try tree.file("\(relative)/new.txt", "new")
    }

    func testALoneNestedRepositoryDecoratesItsFilesAndItsFolder() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("notes.txt", "n")
        try nestedRepository(tree, "app")
        let (viewModel, _) = makeViewModel()

        await viewModel.setContext(local(tree)).value

        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("app/a.txt")), .modified)
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("app/new.txt")), .untracked)
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("app")), .modified)
        XCTAssertNil(viewModel.decorations.kind(at: tree.path("notes.txt")))
        XCTAssertEqual(viewModel.repositoryState?.chosen, tree.path("app"))
    }

    func testADeeperFolderOfTheNestedRepositoryCarriesItsStateUpToTheRoot() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try nestedRepository(tree, "work/app")
        let (viewModel, _) = makeViewModel()

        await viewModel.setContext(local(tree)).value

        XCTAssertEqual(viewModel.repositoryState?.chosen, tree.path("work/app"))
        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("work")), .modified)
    }

    func testSeveralNestedRepositoriesDecorateNothingUntilOneIsChosen() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try nestedRepository(tree, "api")
        try nestedRepository(tree, "web")
        try tree.dir("plain")
        let log = ScanLog()
        let (viewModel, _) = makeViewModel(log: log)
        await viewModel.setContext(local(tree)).value
        XCTAssertTrue(viewModel.decorations.isEmpty)
        XCTAssertTrue(viewModel.canUseAsGitRepository(tree.path("web")))
        XCTAssertFalse(viewModel.canUseAsGitRepository(tree.path("plain")))
        let scans = log.directories
        let generation = viewModel.generation

        await viewModel.useAsGitRepository(tree.path("web")).value

        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("web/a.txt")), .modified)
        XCTAssertNil(viewModel.decorations.kind(at: tree.path("api/a.txt")))
        XCTAssertFalse(viewModel.canUseAsGitRepository(tree.path("web")))
        XCTAssertTrue(viewModel.canUseAsGitRepository(tree.path("api")))
        XCTAssertEqual(log.directories, scans, "choosing a repository must not rescan the tree")
        XCTAssertEqual(viewModel.generation, generation)
    }

    func testAChoiceMadeElsewhereIsFollowed() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try nestedRepository(tree, "api")
        try nestedRepository(tree, "web")
        let (viewModel, roots) = makeViewModel()
        await viewModel.setContext(local(tree)).value

        XCTAssertTrue(roots.choose(tree.path("api"), in: tree.root))
        await waitUntil { !viewModel.decorations.isEmpty }

        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("api/a.txt")), .modified)
        XCTAssertNil(viewModel.decorations.kind(at: tree.path("web/a.txt")))
    }

    func testARepositoryRootKeepsItsOwnDecorationsAndOffersNoChoice() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("top.txt", "t")
        try tree.initRepository()
        try tree.file("top.txt", "edited")
        try nestedRepository(tree, "vendor")
        let (viewModel, _) = makeViewModel()

        await viewModel.setContext(local(tree)).value

        XCTAssertEqual(viewModel.decorations.kind(at: tree.path("top.txt")), .modified)
        XCTAssertFalse(viewModel.canUseAsGitRepository(tree.path("vendor")))
    }

    func testOnlyChangesInsideTheNestedRepositoryCountAsItsWorkingTree() {
        let nested = "/p/app"

        XCTAssertTrue(ExplorerViewModel.touchesWorkingTree(
            FileSystemChange(directories: ["/p/app/src", "/p/app/src/a.swift"], touchedGitignore: false), root: nested
        ))
        XCTAssertFalse(ExplorerViewModel.touchesWorkingTree(
            FileSystemChange(directories: ["/p", "/p/notes.txt"], touchedGitignore: false), root: nested
        ))
        XCTAssertFalse(ExplorerViewModel.touchesWorkingTree(
            FileSystemChange(directories: ["/p/app", "/p/app/.git", "/p/app/.git/refs/heads"], touchedGitignore: false), root: nested
        ))
    }

    func testTheFolderMenuOffersTheRepository() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try nestedRepository(tree, "api")
        try nestedRepository(tree, "web")
        let (viewModel, _) = makeViewModel()
        await viewModel.setContext(local(tree)).value
        let controller = ExplorerOutlineController(viewModel: viewModel, palette: .system)
        controller.pasteboard = NSPasteboard.withUniqueName()
        controller.apply(model: try XCTUnwrap(viewModel.model), filter: everything, selection: [])

        XCTAssertEqual(Array(controller.menuActions(for: tree.path("web")).prefix(3)), [.revealInFinder, .useAsGitRepository, nil])
        controller.perform(.useAsGitRepository, on: [tree.path("web")])
        await waitUntil { !viewModel.decorations.isEmpty }

        XCTAssertEqual(viewModel.repositoryState?.chosen, tree.path("web"))
        XCTAssertFalse(controller.menuActions(for: tree.path("web")).contains(.useAsGitRepository))
        XCTAssertFalse(controller.menuActions(for: tree.path("web/a.txt")).contains(.useAsGitRepository))
    }

    /// Refresh in an ordinary repository has nothing to search for, and
    /// must not make Git History reload.
    func testRefreshInARepositoryDoesNotTellTheOtherViews() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a")
        try tree.initRepository()
        let (viewModel, roots) = makeViewModel()
        await viewModel.setContext(local(tree)).value
        var heard = 0
        let subscription = roots.subscribe(explorerRoot: tree.root) { heard += 1 }
        defer { subscription.cancel() }

        await viewModel.refresh().value

        XCTAssertEqual(heard, 0)
    }

    func testRefreshSearchesTheFolderAgain() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try nestedRepository(tree, "api")
        let (viewModel, _) = makeViewModel()
        await viewModel.setContext(local(tree)).value
        XCTAssertEqual(viewModel.repositoryState?.chosen, tree.path("api"))

        try nestedRepository(tree, "web")
        await viewModel.refresh().value
        await waitUntil { viewModel.repositoryState?.nested.count == 2 }

        XCTAssertEqual(viewModel.repositoryState?.nested, [tree.path("api"), tree.path("web")])
        XCTAssertNil(viewModel.repositoryState?.chosen)
        await waitUntil { viewModel.decorations.isEmpty }
        XCTAssertTrue(viewModel.decorations.isEmpty)
    }
}
