import AppKit
import XCTest
@testable import UnpeelExplorer

/// Drops from Finder or another app: copied by default (the green ＋), ⌘
/// moves; onto a folder row, a file row (its folder) or the space below the
/// rows (the root). The result is selected; ⌘Z trashes the copies or puts
/// moved items back.
@MainActor
final class ExplorerFinderDropTests: ExplorerOperationTestCase {
    private var finder: TempTree!

    override func setUp() async throws {
        try await super.setUp()
        finder = try TempTree()
    }

    override func tearDown() async throws {
        finder.remove()
        try await super.tearDown()
    }

    /// A drag from another app: no source in this process.
    private func finderDrag(_ paths: [String], mask: NSDragOperation = .every) -> FakeDrag {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        return FakeDrag(pasteboard: board, source: nil, mask: mask)
    }

    private func drop(
        _ info: FakeDrag, on item: ExplorerItem?, _ controller: ExplorerOutlineController,
        _ outline: ExplorerNSOutlineView, _ viewModel: ExplorerViewModel
    ) async -> NSDragOperation {
        let operation = controller.outlineView(outline, validateDrop: info, proposedItem: item, proposedChildIndex: -1)
        guard !operation.isEmpty else { return operation }
        XCTAssertTrue(controller.outlineView(outline, acceptDrop: info, item: item, childIndex: -1))
        await settle(controller, viewModel)
        return operation
    }

    func testAFinderDropOnAFolderCopiesAndSelectsTheCopies() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("dest"); try finder.file("a.txt", "A"); try finder.file("pics/p.png", "P")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        let info = finderDrag([finder.path("a.txt"), finder.path("pics")])

        let operation = await drop(info, on: controller.items[tree.path("dest")], controller, outline, viewModel)

        XCTAssertEqual(operation, .copy)
        XCTAssertEqual(tree.names("dest"), ["a.txt", "pics"])
        XCTAssertEqual(finder.names(), ["a.txt", "pics"], "the source is never altered")
        XCTAssertEqual(Set(viewModel.selection), [tree.path("dest/a.txt"), tree.path("dest/pics")])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Copy")

        await viewModel.undo().value
        XCTAssertEqual(tree.names("dest"), [])
        XCTAssertEqual(finder.names(), ["a.txt", "pics"])
    }

    func testCommandDropFromFinderMovesAndUndoPutsItBack() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("dest"); try finder.file("a.txt", "A")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        let info = finderDrag([finder.path("a.txt")], mask: .generic)

        let operation = await drop(info, on: controller.items[tree.path("dest")], controller, outline, viewModel)

        XCTAssertEqual(operation, .move)
        XCTAssertEqual(tree.contents("dest/a.txt"), "A")
        XCTAssertEqual(finder.names(), [])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Move")

        await viewModel.undo().value
        XCTAssertEqual(finder.contents("a.txt"), "A")
        XCTAssertEqual(tree.names("dest"), [])
        await viewModel.redo().value
        XCTAssertEqual(tree.contents("dest/a.txt"), "A")
    }

    func testAFinderDropOnAFileRowLandsInItsFolderAndBelowTheRowsInTheRoot() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/main.swift"); try finder.file("a.txt"); try finder.file("b.txt")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        await viewModel.expand(tree.path("src")).value
        sync(controller, viewModel)

        _ = await drop(finderDrag([finder.path("a.txt")]), on: controller.items[tree.path("src/main.swift")],
                       controller, outline, viewModel)
        _ = await drop(finderDrag([finder.path("b.txt")]), on: nil, controller, outline, viewModel)

        XCTAssertEqual(tree.names("src"), ["a.txt", "main.swift"])
        XCTAssertEqual(tree.names(), ["b.txt", "src"])
    }

    func testAFinderDropMeetingANameAsksTheCollisionPrompt() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "mine"); try finder.file("a.txt", "theirs")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        let prompt = ScriptedPrompt([CollisionAnswer(.keepBoth)])
        controller.collisionPrompt = prompt

        _ = await drop(finderDrag([finder.path("a.txt")]), on: nil, controller, outline, viewModel)

        XCTAssertEqual(prompt.asked, ["a.txt (0 more)"])
        XCTAssertEqual(tree.contents("a.txt"), "mine")
        XCTAssertEqual(tree.contents("a copy.txt"), "theirs")
    }

    func testALinkOnlyDropFromFinderIsRefused() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try finder.file("a.txt")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)

        let operation = await drop(finderDrag([finder.path("a.txt")], mask: .link), on: nil, controller, outline, viewModel)

        XCTAssertEqual(operation, [])
        XCTAssertEqual(tree.names(), [])
    }

    func testAFinderPathThroughASymlinkStillCountsAsAlreadyThere() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        let viaVar = tree.path("a.txt").replacingOccurrences(of: "/private/var/", with: "/var/")

        let operation = await drop(finderDrag([viaVar], mask: .generic), on: nil, controller, outline, viewModel)

        XCTAssertEqual(operation, [], "moving an item into the folder it is in is no drop")
    }
}
