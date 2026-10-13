import XCTest
@testable import UnpeelExplorer

/// The EXPLORER applying its own File Operations: results on screen without
/// a watcher, expansion and selection following the result, failures in the
/// message strip, and each Explorer Root's Operation History.
@MainActor
final class ExplorerOperationsTests: ExplorerViewModelTestCase {
    private var trash: FolderTrash!

    override func setUp() async throws {
        trash = try FolderTrash()
    }

    override func tearDown() async throws {
        trash.remove()
        try await super.tearDown()
    }

    /// Real scans, no watcher (so anything on screen came from the view
    /// model applying the operation itself), and a folder Trash.
    private func operationServices(trasher: (any Trasher)? = nil, log: ScanLog? = nil) -> ExplorerServices {
        let trasher = trasher ?? trash!
        return ExplorerServices(
            scan: { directory, root in
                log?.record(directory)
                return try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { _, _ in nil },
            makeOperations: { root in FileOperations(root: root, trasher: trasher) }
        )
    }

    private func names(_ viewModel: ExplorerViewModel, _ directory: String) -> [String] {
        viewModel.model?.visibleChildren(of: directory, filter: everything).map(\.name) ?? []
    }

    private func opened(_ tree: TempTree, trasher: (any Trasher)? = nil) async -> ExplorerViewModel {
        let viewModel = makeViewModel(operationServices(trasher: trasher))
        await viewModel.setContext(local(tree)).value
        return viewModel
    }

    // MARK: - Showing results

    func testANewFileIsShownAndSelectedWithoutAWatcher() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let viewModel = await opened(tree)

        await viewModel.createFile("notes.txt", in: tree.root).value

        XCTAssertEqual(names(viewModel, tree.root), ["notes.txt"])
        XCTAssertEqual(viewModel.selection, [tree.path("notes.txt")])
        XCTAssertNil(viewModel.operationMessage)
    }

    func testANestedNewFileIsRevealedWithItsFoldersExpanded() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let viewModel = await opened(tree)

        await viewModel.createFile("src/utils/x.ts", in: tree.root).value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("src"), tree.path("src/utils")])
        XCTAssertEqual(names(viewModel, tree.path("src/utils")), ["x.ts"])
        XCTAssertEqual(viewModel.selection, [tree.path("src/utils/x.ts")])
    }

    func testARenamedExpandedFolderKeepsItsExpansion() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/sub/x.txt"); try tree.file("src/y.txt")
        let viewModel = await opened(tree)
        await viewModel.expand(tree.path("src")).value
        await viewModel.expand(tree.path("src/sub")).value

        await viewModel.rename(tree.path("src"), to: "lib").value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("lib"), tree.path("lib/sub")])
        XCTAssertEqual(names(viewModel, tree.root), ["lib"])
        XCTAssertEqual(names(viewModel, tree.path("lib/sub")), ["x.txt"])
        XCTAssertEqual(viewModel.selection, [tree.path("lib")])
    }

    func testAFileMovedIntoACollapsedFolderIsRevealed() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("dest/b.txt")
        let viewModel = await opened(tree)

        await viewModel.move([tree.path("a.txt")], into: tree.path("dest")).value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("dest")])
        XCTAssertEqual(names(viewModel, tree.path("dest")), ["a.txt", "b.txt"])
        XCTAssertEqual(viewModel.selection, [tree.path("dest/a.txt")])
    }

    func testTheWatchersOwnBatchAfterAnOperationChangesNothing() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt")
        let viewModel = await opened(tree)
        await viewModel.expand(tree.path("src")).value
        await viewModel.createFile("src/b.txt", in: tree.root).value
        let shown = viewModel.model

        await viewModel.handleChange(FileSystemChange(directories: [tree.path("src")], touchedGitignore: false)).value

        XCTAssertEqual(viewModel.model, shown)
    }

    // MARK: - Failures

    func testAFailureIsPublishedAndTheNextSuccessClearsIt() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("b.txt")
        let viewModel = await opened(tree)

        await viewModel.rename(tree.path("a.txt"), to: "b.txt").value
        XCTAssertEqual(viewModel.operationMessage, "“b.txt” already exists in this folder.")

        await viewModel.createFile("c.txt", in: tree.root).value
        XCTAssertNil(viewModel.operationMessage)
    }

    func testSeveralFailuresAreCounted() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("dest")
        let viewModel = await opened(tree)

        await viewModel.move([tree.path("x"), tree.path("y"), tree.path("z")], into: tree.path("dest")).value

        XCTAssertEqual(viewModel.operationMessage, "“x” no longer exists. (and 2 more)")
    }

    func testTheMessageCanBeDismissedAndGoesAwayWithTheRoot() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let other = try TempTree(); defer { other.remove() }
        try tree.file("a.txt"); try tree.file("b.txt")
        let viewModel = await opened(tree)

        await viewModel.rename(tree.path("a.txt"), to: "b.txt").value
        viewModel.dismissOperationMessage()
        XCTAssertNil(viewModel.operationMessage)

        await viewModel.rename(tree.path("a.txt"), to: "b.txt").value
        await viewModel.setContext(local(other)).value
        XCTAssertNil(viewModel.operationMessage)
    }

    // MARK: - Operation History

    func testUndoAndRedoWalkTheHistory() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "A")
        let viewModel = await opened(tree)
        XCTAssertNil(viewModel.undoActionTitle)

        await viewModel.rename(tree.path("a.txt"), to: "b.txt").value
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Rename")
        XCTAssertNil(viewModel.redoActionTitle)

        await viewModel.undo().value
        XCTAssertEqual(names(viewModel, tree.root), ["a.txt"])
        XCTAssertEqual(viewModel.selection, [tree.path("a.txt")])
        XCTAssertNil(viewModel.undoActionTitle)
        XCTAssertEqual(viewModel.redoActionTitle, "Redo Rename")

        await viewModel.redo().value
        XCTAssertEqual(names(viewModel, tree.root), ["b.txt"])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Rename")
    }

    func testAnUndoBlockedByAnAgentReportsAndDropsTheStep() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = await opened(tree)
        await viewModel.rename(tree.path("a.txt"), to: "b.txt").value
        try tree.file("a.txt", "agent")

        await viewModel.undo().value

        XCTAssertEqual(viewModel.operationMessage, "“a.txt” already exists in this folder.")
        XCTAssertNil(viewModel.undoActionTitle)
        XCTAssertNil(viewModel.redoActionTitle)
    }

    func testEachRootKeepsItsOwnHistory() async throws {
        let first = try TempTree(); defer { first.remove() }
        let second = try TempTree(); defer { second.remove() }
        try first.file("a.txt")
        let viewModel = await opened(first)
        await viewModel.rename(first.path("a.txt"), to: "b.txt").value

        await viewModel.setContext(local(second)).value
        XCTAssertNil(viewModel.undoActionTitle)
        await viewModel.undo().value
        XCTAssertTrue(first.exists("b.txt"))

        await viewModel.setContext(local(first)).value
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Rename")
        await viewModel.undo().value
        XCTAssertTrue(first.exists("a.txt"))
    }

    func testOperationsRunInTheOrderTheyWereAskedFor() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = await opened(tree)

        viewModel.rename(tree.path("a.txt"), to: "b.txt")
        viewModel.undo()
        await viewModel.redo().value

        XCTAssertEqual(tree.names(), ["b.txt"])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Rename")
    }

    func testAnOperationFinishingAfterTheRootChangedIsRecordedButNotShown() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let other = try TempTree(); defer { other.remove() }
        try tree.file("a.txt"); try other.file("o.txt")
        let slow = HookTrash(trash: trash) { _ in Thread.sleep(forTimeInterval: 0.3) }
        let viewModel = await opened(tree, trasher: slow)

        let trashing = viewModel.trash([tree.path("a.txt")])
        await viewModel.setContext(local(other)).value
        await trashing.value

        XCTAssertEqual(names(viewModel, other.root), ["o.txt"])
        XCTAssertEqual(viewModel.selection, [])
        await viewModel.setContext(local(tree)).value
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Move to Trash")
    }

    // MARK: - Selection reconciliation

    func testCollapsingAFolderDropsItsHiddenDescendantsFromTheSelection() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt"); try tree.file("b.txt")
        let viewModel = await opened(tree)
        await viewModel.expand(tree.path("src")).value
        viewModel.selection = [tree.path("src/a.txt"), tree.path("b.txt")]

        viewModel.collapse(tree.path("src"))

        XCTAssertEqual(viewModel.selection, [tree.path("b.txt")])
    }

    func testCollapseAllKeepsOnlyTopLevelSelection() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt"); try tree.file("b.txt")
        let viewModel = await opened(tree)
        await viewModel.expand(tree.path("src")).value
        viewModel.selection = [tree.path("src/a.txt"), tree.path("b.txt"), tree.path("src")]

        viewModel.collapseAll()

        XCTAssertEqual(viewModel.selection, [tree.path("b.txt"), tree.path("src")])
    }
}
