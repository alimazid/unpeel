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

    func testTheFieldTextIsTheTextColourOnASelectedRow() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, _, _) = await windowed(tree)
        XCTAssertTrue(controller.beginRename(tree.path("a.txt")))
        let field = try XCTUnwrap(controller.nameEditor?.field)
        let cell = try XCTUnwrap(field.superview as? ExplorerRowCellView)

        // The row is drawn with the accent fill while the field is open.
        cell.backgroundStyle = .emphasized
        XCTAssertEqual(field.textColor, .textColor, "never the white meant for the accent fill, on a white field")

        press(escapeKey, in: controller)
        XCTAssertEqual(field.textColor, .alternateSelectedControlTextColor)
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

    func testTheBubbleOfTheLastVisibleRowOpensAboveIt() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        for index in 0..<40 { try tree.file(String(format: "f%02d.txt", index)) }
        let (controller, outline, _) = await windowed(tree)
        let visible = outline.visibleRect
        let lastVisible = try XCTUnwrap((0..<outline.numberOfRows).last { outline.rect(ofRow: $0).maxY <= visible.maxY })
        let path = try XCTUnwrap((outline.item(atRow: lastVisible) as? ExplorerItem)?.path)
        XCTAssertTrue(controller.beginRename(path))

        type("f00.txt", into: controller)

        let bubble = try XCTUnwrap(outline.subviews.compactMap { $0 as? ExplorerNameMessageView }.first)
        XCTAssertTrue(outline.visibleRect.contains(bubble.frame), "\(bubble.frame) is clipped by \(outline.visibleRect)")
        let field = try XCTUnwrap(controller.nameEditor?.field)
        XCTAssertEqual(bubble.frame.maxY, field.convert(field.bounds, to: outline).minY, "above the field")
        press(escapeKey, in: controller)
    }

    func testTheBubbleOpensBelowTheRowWhenThereIsRoom() {
        let anchor = NSRect(x: 20, y: 100, width: 200, height: 22)
        let visible = NSRect(x: 0, y: 0, width: 300, height: 400)
        let size = NSSize(width: 200, height: 40)

        let below = ExplorerNameMessageView.placement(of: size, around: anchor, within: visible, flipped: true)
        XCTAssertEqual(below, NSRect(x: 20, y: 122, width: 200, height: 40))
        let above = ExplorerNameMessageView.placement(
            of: size, around: anchor.offsetBy(dx: 0, dy: 260), within: visible, flipped: true
        )
        XCTAssertEqual(above, NSRect(x: 20, y: 320, width: 200, height: 40))
        let tooShort = ExplorerNameMessageView.placement(
            of: size, around: anchor.offsetBy(dx: 0, dy: -90), within: NSRect(x: 0, y: 0, width: 300, height: 50),
            flipped: true
        )
        XCTAssertEqual(tooShort.minY, 32, "below when it fits neither way")
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

    func testAReloadOfAFolderAboveTheFieldNeverCommitsAHalfTypedName() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("p/f/a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        await viewModel.expand(tree.path("p")).value
        await viewModel.expand(tree.path("p/f")).value
        sync(controller, viewModel)
        XCTAssertTrue(controller.beginRename(tree.path("p/f/a.txt")))
        type("typ", into: controller)

        try tree.file("p/agent.txt")
        try tree.file("root-agent.txt")
        await viewModel.refresh().value
        sync(controller, viewModel)

        XCTAssertNotNil(controller.nameEditor, "the field is still open")
        XCTAssertEqual(tree.names("p/f"), ["a.txt"])
        press(escapeKey, in: controller)
        XCTAssertEqual(controller.children(of: tree.path("p")).map(\.path), [tree.path("p/f"), tree.path("p/agent.txt")])
    }

    func testAHeldBackReloadKeepsTheSelectionAndExpansion() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("p/a.txt"); try tree.file("p/sub/x.txt")
        let (controller, outline, viewModel) = await windowed(tree)
        await viewModel.expand(tree.path("p")).value
        await viewModel.expand(tree.path("p/sub")).value
        sync(controller, viewModel)
        XCTAssertTrue(controller.beginRename(tree.path("p/a.txt")))
        type("typ", into: controller)

        try tree.file("p/agent.txt")
        await viewModel.refresh().value
        sync(controller, viewModel)
        press(escapeKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertEqual(controller.children(of: tree.path("p")).map(\.path).last, tree.path("p/agent.txt"))
        XCTAssertEqual(viewModel.selection, [tree.path("p/a.txt")])
        XCTAssertEqual(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ExplorerItem)?.path }, [tree.path("p/a.txt")])
        XCTAssertEqual(viewModel.model?.expanded, [tree.path("p"), tree.path("p/sub")])
        XCTAssertTrue(outline.isItemExpanded(controller.items[tree.path("p/sub")]))
    }

    func testARenameStartedWhileADraftIsOpenSurvivesTheDraftGoing() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        await viewModel.beginDraft(.file, in: tree.root).value
        sync(controller, viewModel)
        await drainMainQueue()
        XCTAssertEqual(controller.nameEditor?.purpose, .create)

        XCTAssertTrue(controller.beginRename(tree.path("a.txt")))
        sync(controller, viewModel)

        XCTAssertEqual(controller.nameEditor?.purpose, .rename(currentName: "a.txt"))
        XCTAssertEqual(controller.children(of: tree.root).map(\.role), [.entry])
        type("b.txt", into: controller)
        press(returnKey, in: controller)
        await settle(controller, viewModel)
        XCTAssertEqual(tree.names(), ["b.txt"])
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
