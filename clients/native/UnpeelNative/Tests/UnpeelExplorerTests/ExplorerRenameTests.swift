import AppKit
import XCTest
@testable import UnpeelExplorer

/// Inline rename: Return or "Rename…" turns the row into a name field with
/// the stem selected; VS Code's validation while typing; Return commits,
/// Escape cancels.
@MainActor
final class ExplorerRenameTests: ExplorerOperationTestCase {
    func testReturnOpensTheFieldWithTheStemSelected() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("archive.tar.gz")
        let (controller, _, viewModel) = await windowed(tree)
        viewModel.selection = [tree.path("archive.tar.gz")]
        sync(controller, viewModel)

        XCTAssertTrue(controller.handleKeyCommand(.rename))

        let field = try XCTUnwrap(controller.nameEditor?.field)
        XCTAssertTrue(field.isEditable)
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 0, length: 11))
    }

    func testTheDefaultSelectionFollowsVSCode() {
        XCTAssertEqual(ExplorerNameEditor.defaultSelection(for: "a.txt"), NSRange(location: 0, length: 1))
        XCTAssertEqual(ExplorerNameEditor.defaultSelection(for: ".env"), NSRange(location: 0, length: 4))
        XCTAssertEqual(ExplorerNameEditor.defaultSelection(for: "Makefile"), NSRange(location: 0, length: 8))
        XCTAssertEqual(ExplorerNameEditor.defaultSelection(for: "v1.2", isFolder: true), NSRange(location: 0, length: 4))
    }

    func testReturnCommitsTheRenameAndSelectsIt() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, outline, viewModel) = await windowed(tree)
        XCTAssertTrue(controller.beginRename(tree.path("a.txt")))

        type("b.txt", into: controller)
        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertNil(controller.nameEditor)
        XCTAssertEqual(tree.names(), ["b.txt"])
        XCTAssertEqual(viewModel.selection, [tree.path("b.txt")])
        XCTAssertTrue(outline.window?.firstResponder === outline, "the tree keeps the keyboard")
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Rename")
    }

    func testEscapeCancels() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        controller.beginRename(tree.path("a.txt"))

        type("b.txt", into: controller)
        press(escapeKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertNil(controller.nameEditor)
        XCTAssertEqual(tree.names(), ["a.txt"])
        XCTAssertNil(viewModel.undoActionTitle)
    }

    func testAnErrorShowsAndBlocksTheCommit() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("b.txt")
        let (controller, outline, viewModel) = await windowed(tree)
        controller.beginRename(tree.path("a.txt"))

        type("b.txt", into: controller)
        XCTAssertEqual(controller.nameEditor?.issue?.severity, .error)
        XCTAssertEqual(
            controller.nameEditor?.issue?.message,
            "A file or folder “b.txt” already exists at this location. Please choose a different name."
        )
        let bubble = outline.subviews.compactMap { $0 as? ExplorerNameMessageView }.first
        XCTAssertEqual(bubble?.text, controller.nameEditor?.issue?.message)
        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertNotNil(controller.nameEditor, "the field stays open")
        XCTAssertEqual(tree.names(), ["a.txt", "b.txt"])

        type("", into: controller)
        XCTAssertEqual(controller.nameEditor?.issue?.message, "A file or folder name must be provided.")
        type("a/b", into: controller)
        XCTAssertEqual(controller.nameEditor?.issue?.message, "A file or folder name cannot contain a slash.")
        press(escapeKey, in: controller)
        XCTAssertTrue(outline.subviews.allSatisfy { !($0 is ExplorerNameMessageView) }, "the bubble goes with the field")
    }

    func testAWhitespaceWarningDoesNotBlock() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        controller.beginRename(tree.path("a.txt"))

        type("b.txt ", into: controller)
        XCTAssertEqual(controller.nameEditor?.issue?.severity, .warning)
        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names(), ["b.txt "])
    }

    func testACaseOnlyRenameIsNotACollision() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("readme.md")
        let (controller, _, viewModel) = await windowed(tree)
        controller.beginRename(tree.path("readme.md"))

        type("README.md", into: controller)
        XCTAssertNil(controller.nameEditor?.issue)
        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names(), ["README.md"])
    }

    func testAnUnchangedNameRecordsNothing() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        controller.beginRename(tree.path("a.txt"))

        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertNil(viewModel.undoActionTitle)
    }

    func testAReloadOfTheFolderWaitsForTheFieldToClose() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        controller.beginRename(tree.path("a.txt"))
        type("typed", into: controller)
        let field = try XCTUnwrap(controller.nameEditor?.field)

        // An agent writes a file beside it; the watcher's reload arrives.
        try tree.file("agent.txt")
        await viewModel.refresh().value
        sync(controller, viewModel)

        XCTAssertTrue(controller.nameEditor?.field === field)
        XCTAssertEqual(field.currentEditor()?.string, "typed")
        press(escapeKey, in: controller)
        XCTAssertEqual(controller.children(of: tree.root).map(\.path), [tree.path("a.txt"), tree.path("agent.txt")])
    }

    func testAMultipleSelectionCannotBeRenamed() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("b.txt")
        let (controller, _, viewModel) = await windowed(tree)
        viewModel.selection = [tree.path("a.txt"), tree.path("b.txt")]
        sync(controller, viewModel)

        XCTAssertFalse(controller.handleKeyCommand(.rename))
        XCTAssertNil(controller.nameEditor)
        XCTAssertFalse(controller.menuActions(forTargets: viewModel.selection).contains(.rename))
    }

    func testAnExpandedFolderStaysExpandedAfterARename() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/x.txt")
        let (controller, _, viewModel) = await windowed(tree)
        await viewModel.expand(tree.path("src")).value
        sync(controller, viewModel)
        controller.beginRename(tree.path("src"))

        type("lib", into: controller)
        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("lib")])
        XCTAssertEqual(controller.children(of: tree.path("lib")).map(\.path), [tree.path("lib/x.txt")])
    }
}
