import XCTest
@testable import UnpeelExplorer

/// Move to Trash: ⌘⌫ and the context menu, no confirmation, one undo step.
@MainActor
final class ExplorerTrashTests: ExplorerOperationTestCase {
    func testCommandDeleteTrashesTheSelectionAndSelectsTheNextRow() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("b.txt"); try tree.file("c.txt")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        viewModel.selection = [tree.path("a.txt"), tree.path("b.txt")]
        sync(controller, viewModel)

        XCTAssertTrue(controller.handleKeyCommand(.trash))
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names(), ["c.txt"])
        XCTAssertEqual(trash.contents, ["a.txt", "b.txt"])
        XCTAssertEqual(names(viewModel, tree.root), ["c.txt"])
        XCTAssertEqual(viewModel.selection, [tree.path("c.txt")])
    }

    func testTheLastRowTrashedSelectsThePreviousOne() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("b.txt")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)

        controller.perform(.trash, on: [tree.path("b.txt")])
        await settle(controller, viewModel)

        XCTAssertEqual(viewModel.selection, [tree.path("a.txt")])
    }

    func testUndoPutsEverythingBackAsOneStepAndRedoTrashesItAgain() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "A"); try tree.file("src/b.txt", "B")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        controller.perform(.trash, on: [tree.path("a.txt"), tree.path("src")])
        await settle(controller, viewModel)
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Move to Trash")

        await viewModel.undo().value

        XCTAssertEqual(tree.contents("a.txt"), "A")
        XCTAssertEqual(tree.contents("src/b.txt"), "B")
        XCTAssertEqual(Set(viewModel.selection), [tree.path("a.txt"), tree.path("src")])
        XCTAssertNil(viewModel.undoActionTitle)

        await viewModel.redo().value
        XCTAssertEqual(tree.names(), [])
    }

    func testTheMenuOffersMoveToTrashForEntriesOnly() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)

        XCTAssertTrue(controller.menuActions(for: tree.path("a.txt")).contains(.trash))
        XCTAssertFalse(controller.menuActions(for: nil).contains(.trash))
        XCTAssertEqual(ExplorerOutlineController.MenuAction.trash.title, "Move to Trash")
    }

    func testADiskWithoutATrashDeletesNothingAndSaysSo() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = await opened(tree, trasher: NoTrash())
        let (controller, _) = attach(viewModel)

        controller.perform(.trash, on: [tree.path("a.txt")])
        await settle(controller, viewModel)

        XCTAssertTrue(tree.exists("a.txt"))
        XCTAssertEqual(viewModel.operationMessage, "“a.txt” can’t be moved to the Trash on this disk.")
        XCTAssertNil(viewModel.undoActionTitle)
    }
}
