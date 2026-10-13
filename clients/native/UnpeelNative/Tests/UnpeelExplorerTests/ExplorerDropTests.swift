import AppKit
import XCTest
@testable import UnpeelExplorer

/// Dragging rows within the tree: move by default, ⌥ copies; a file row
/// stands for its folder; nothing drops into itself.
final class ExplorerDropRuleTests: XCTestCase {
    private let all: NSDragOperation = [.copy, .move, .generic]

    func testTheDropFolder() {
        XCTAssertEqual(ExplorerDrop.folder(on: "/r/src", isFolder: true, root: "/r"), "/r/src")
        XCTAssertEqual(ExplorerDrop.folder(on: "/r/src/a.txt", isFolder: false, root: "/r"), "/r/src")
        XCTAssertEqual(ExplorerDrop.folder(on: nil, isFolder: false, root: "/r"), "/r")
    }

    func testRowsMoveAndOptionCopies() {
        XCTAssertEqual(ExplorerDrop.operation(sources: ["/r/a"], into: "/r/dest", sourceMask: all, isInternal: true), .move)
        XCTAssertEqual(ExplorerDrop.operation(sources: ["/r/a"], into: "/r/dest", sourceMask: .copy, isInternal: true), .copy)
        XCTAssertEqual(ExplorerDrop.operation(sources: ["/r/a"], into: "/r/dest", sourceMask: .generic, isInternal: true), .move)
    }

    func testNothingDropsIntoItselfOrADescendant() {
        XCTAssertEqual(ExplorerDrop.operation(sources: ["/r/a"], into: "/r/a", sourceMask: all, isInternal: true), [])
        XCTAssertEqual(ExplorerDrop.operation(sources: ["/r/a"], into: "/r/a/b", sourceMask: .copy, isInternal: true), [])
        XCTAssertEqual(
            ExplorerDrop.operation(sources: ["/r/x", "/r/a"], into: "/r/a/b", sourceMask: all, isInternal: true), []
        )
    }

    func testAMoveIntoTheFolderItIsInIsNoDropButACopyIs() {
        XCTAssertEqual(ExplorerDrop.operation(sources: ["/r/a"], into: "/r", sourceMask: all, isInternal: true), [])
        XCTAssertEqual(ExplorerDrop.operation(sources: ["/r/a"], into: "/r", sourceMask: .copy, isInternal: true), .copy)
    }

    func testDragsFromOutsideTheTreeAreNotAcceptedYet() {
        XCTAssertEqual(ExplorerDrop.operation(sources: ["/x/a"], into: "/r", sourceMask: all, isInternal: false), [])
    }
}

@MainActor
final class ExplorerDropTests: ExplorerOperationTestCase {
    private func drag(_ paths: [String], from source: AnyObject?, mask: NSDragOperation = [.copy, .move, .generic]) -> FakeDrag {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        return FakeDrag(pasteboard: board, source: source, mask: mask)
    }

    func testARowDroppedOnAFolderMovesThereAsOneUndoStep() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("b.txt"); try tree.dir("dest")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        let info = drag([tree.path("a.txt"), tree.path("b.txt")], from: outline)
        let dest = controller.items[tree.path("dest")]

        XCTAssertEqual(controller.outlineView(outline, validateDrop: info, proposedItem: dest, proposedChildIndex: -1), .move)
        XCTAssertTrue(controller.outlineView(outline, acceptDrop: info, item: dest, childIndex: -1))
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names("dest"), ["a.txt", "b.txt"])
        XCTAssertEqual(Set(viewModel.selection), [tree.path("dest/a.txt"), tree.path("dest/b.txt")])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Move")
        await viewModel.undo().value
        XCTAssertEqual(tree.names(), ["a.txt", "b.txt", "dest"])
    }

    func testOptionDragCopies() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.dir("dest")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        let info = drag([tree.path("a.txt")], from: outline, mask: .copy)
        let dest = controller.items[tree.path("dest")]

        XCTAssertEqual(controller.outlineView(outline, validateDrop: info, proposedItem: dest, proposedChildIndex: -1), .copy)
        XCTAssertTrue(controller.outlineView(outline, acceptDrop: info, item: dest, childIndex: -1))
        await settle(controller, viewModel)

        XCTAssertTrue(tree.exists("a.txt"))
        XCTAssertTrue(tree.exists("dest/a.txt"))
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Copy")
    }

    func testAFileRowStandsForItsFolder() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("dest/b.txt")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        await viewModel.expand(tree.path("dest")).value
        sync(controller, viewModel)
        let info = drag([tree.path("a.txt")], from: outline)
        let fileRow = controller.items[tree.path("dest/b.txt")]

        XCTAssertEqual(controller.outlineView(outline, validateDrop: info, proposedItem: fileRow, proposedChildIndex: -1), .move)
        XCTAssertTrue(controller.outlineView(outline, acceptDrop: info, item: fileRow, childIndex: -1))
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names("dest"), ["a.txt", "b.txt"])
    }

    func testTheSpaceBelowTheRowsIsTheRoot() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        await viewModel.expand(tree.path("src")).value
        sync(controller, viewModel)
        let info = drag([tree.path("src/a.txt")], from: outline)

        XCTAssertTrue(controller.outlineView(outline, acceptDrop: info, item: nil, childIndex: -1))
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names(), ["a.txt", "src"])
    }

    func testAFolderOntoItsOwnDescendantShowsNoDrop() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("a/b")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        await viewModel.expand(tree.path("a")).value
        sync(controller, viewModel)
        let info = drag([tree.path("a")], from: outline)

        XCTAssertEqual(
            controller.outlineView(outline, validateDrop: info, proposedItem: controller.items[tree.path("a/b")], proposedChildIndex: -1),
            []
        )
        XCTAssertFalse(controller.outlineView(outline, acceptDrop: info, item: controller.items[tree.path("a/b")], childIndex: -1))
        XCTAssertTrue(tree.isDirectory("a/b"))
    }

    func testDragsFromElsewhereAreRefusedInThisCut() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let finder = try TempTree(); defer { finder.remove() }
        try finder.file("x.txt"); try tree.dir("dest")
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        let info = drag([finder.path("x.txt")], from: nil)

        XCTAssertEqual(
            controller.outlineView(outline, validateDrop: info, proposedItem: controller.items[tree.path("dest")], proposedChildIndex: -1),
            []
        )
    }

    func testTheTreeAcceptsFileDrags() {
        XCTAssertTrue(ExplorerOutlineView.makeOutlineView().registeredDraggedTypes.contains(.fileURL))
    }
}

/// The parts of a drag the tree reads.
@MainActor
final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSourceOperationMask: NSDragOperation

    init(pasteboard: NSPasteboard, source: AnyObject?, mask: NSDragOperation) {
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingSourceOperationMask = mask
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to _: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions = [], for _: NSView?, classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
