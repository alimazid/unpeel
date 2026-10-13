import AppKit
import XCTest
@testable import UnpeelExplorer

/// The app's Edit menu reaching the tree through the responder chain:
/// "Undo <operation>" while the tree has focus, the text's own undo while a
/// name field is being edited.
@MainActor
final class ExplorerEditMenuTests: ExplorerOperationTestCase {
    private func attached(_ tree: TempTree) async -> (ExplorerNSOutlineView, ExplorerViewModel) {
        let viewModel = await opened(tree)
        return (attach(viewModel).1, viewModel)
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    func testUndoAndRedoAreTitledAfterTheOperationAndWalkTheHistory() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (outline, viewModel) = await attached(tree)
        let undo = item(#selector(ExplorerNSOutlineView.undo(_:)))
        let redo = item(#selector(ExplorerNSOutlineView.redo(_:)))

        XCTAssertFalse(outline.validateUserInterfaceItem(undo))
        XCTAssertEqual(undo.title, "Undo")

        await viewModel.rename(tree.path("a.txt"), to: "b.txt").value
        XCTAssertTrue(outline.validateUserInterfaceItem(undo))
        XCTAssertEqual(undo.title, "Undo Rename")
        XCTAssertFalse(outline.validateUserInterfaceItem(redo))
        XCTAssertEqual(redo.title, "Redo")

        outline.undo(nil)
        await viewModel.operationTail?.value
        XCTAssertEqual(tree.names(), ["a.txt"])
        XCTAssertTrue(outline.validateUserInterfaceItem(redo))
        XCTAssertEqual(redo.title, "Redo Rename")

        outline.redo(nil)
        await viewModel.operationTail?.value
        XCTAssertEqual(tree.names(), ["b.txt"])
    }

    func testClipboardCommandsNeedASelectionOrFilesToPaste() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (outline, viewModel) = await attached(tree)
        let cut = item(#selector(ExplorerNSOutlineView.cut(_:)))
        let copy = item(#selector(ExplorerNSOutlineView.copy(_:)))
        let paste = item(#selector(ExplorerNSOutlineView.paste(_:)))

        XCTAssertFalse(outline.validateUserInterfaceItem(cut))
        XCTAssertFalse(outline.validateUserInterfaceItem(copy))
        XCTAssertFalse(outline.validateUserInterfaceItem(paste))

        viewModel.selection = [tree.path("a.txt")]
        XCTAssertTrue(outline.validateUserInterfaceItem(copy))
        XCTAssertEqual(copy.title, "Copy")
        outline.copy(nil)
        XCTAssertTrue(outline.validateUserInterfaceItem(paste))
    }

    func testOtherItemsKeepTheTablesOwnValidation() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (outline, _) = await attached(tree)

        XCTAssertTrue(outline.validateUserInterfaceItem(item(#selector(NSTableView.selectAll(_:)))))
    }

    func testWhileANameIsEditedUndoBelongsToTheText() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (outline, viewModel) = await attached(tree)
        await viewModel.rename(tree.path("a.txt"), to: "b.txt").value
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = ExplorerOutlineView.makeScrollView(documentView: outline)
        let field = NSTextField(string: "name")
        field.isEditable = true
        outline.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let undo = item(#selector(ExplorerNSOutlineView.undo(_:)))

        XCTAssertFalse(outline.validateUserInterfaceItem(undo), "the field has nothing to undo")
        outline.undo(nil)
        await viewModel.operationTail?.value

        XCTAssertEqual(tree.names(), ["b.txt"], "⌘Z in a name field never undoes a file operation")
    }
}
