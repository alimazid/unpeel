import AppKit
import XCTest
@testable import UnpeelExplorer

/// New File… / New Folder…: a Draft Row in the target folder; the committed
/// name is created there, selected and revealed, and never opened.
@MainActor
final class ExplorerDraftTests: ExplorerOperationTestCase {
    private func startDraft(
        _ kind: ExplorerDraft.Kind, in folder: String,
        _ controller: ExplorerOutlineController, _ viewModel: ExplorerViewModel
    ) async {
        await viewModel.beginDraft(kind, in: folder).value
        sync(controller, viewModel)
        await drainMainQueue()
    }

    func testTheDraftFolderFollowsTheTargets() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt"); try tree.file("b.txt")
        let viewModel = await opened(tree)
        await viewModel.expand(tree.path("src")).value

        XCTAssertEqual(viewModel.draftFolder(for: []), tree.root)
        XCTAssertEqual(viewModel.draftFolder(for: [tree.path("src")]), tree.path("src"))
        XCTAssertEqual(viewModel.draftFolder(for: [tree.path("src/a.txt")]), tree.path("src"))
        XCTAssertEqual(viewModel.draftFolder(for: [tree.path("b.txt")]), tree.root)
    }

    func testANewFileDraftSitsFirstAmongTheFilesAndANewFolderFirstOfAll() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("lib"); try tree.file("a.txt")
        let (controller, _, viewModel) = await windowed(tree)

        await startDraft(.file, in: tree.root, controller, viewModel)
        XCTAssertEqual(controller.children(of: tree.root).map(\.role), [.entry, .draft, .entry])

        press(escapeKey, in: controller)
        sync(controller, viewModel)
        await startDraft(.folder, in: tree.root, controller, viewModel)
        XCTAssertEqual(controller.children(of: tree.root).map(\.role), [.draft, .entry, .entry])
    }

    func testCommittingCreatesTheFileSelectsItAndOpensNothing() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let handler = OpenRecorder()
        let (controller, _, viewModel) = await windowed(tree)
        controller.actionHandler = handler
        await startDraft(.file, in: tree.root, controller, viewModel)
        XCTAssertNotNil(controller.nameEditor)

        type("notes.md", into: controller)
        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names(), ["notes.md"])
        XCTAssertNil(viewModel.draft)
        XCTAssertEqual(controller.children(of: tree.root).map(\.role), [.entry])
        XCTAssertEqual(viewModel.selection, [tree.path("notes.md")])
        XCTAssertEqual(handler.opened, [])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo New File")
    }

    func testANestedNameCreatesItsFoldersAndRevealsTheFile() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let (controller, _, viewModel) = await windowed(tree)
        await startDraft(.file, in: tree.root, controller, viewModel)

        type("src/utils/x.ts", into: controller)
        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertTrue(tree.exists("src/utils/x.ts"))
        XCTAssertEqual(viewModel.model?.expanded, [tree.path("src"), tree.path("src/utils")])
        XCTAssertEqual(viewModel.selection, [tree.path("src/utils/x.ts")])

        await viewModel.undo().value
        XCTAssertEqual(tree.names(), [], "undo takes the folders it made too")
    }

    func testANewFolderInACollapsedFolderExpandsIt() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        await startDraft(.folder, in: tree.path("src"), controller, viewModel)

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("src")])
        type("lib", into: controller)
        press(returnKey, in: controller)
        await settle(controller, viewModel)

        XCTAssertTrue(tree.isDirectory("src/lib"))
        XCTAssertEqual(viewModel.selection, [tree.path("src/lib")])
    }

    func testEscapeOrAnEmptyNameRemovesTheDraft() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, _, viewModel) = await windowed(tree)

        await startDraft(.file, in: tree.root, controller, viewModel)
        press(escapeKey, in: controller)
        sync(controller, viewModel)
        XCTAssertNil(viewModel.draft)
        XCTAssertEqual(controller.children(of: tree.root).map(\.role), [.entry])

        await startDraft(.file, in: tree.root, controller, viewModel)
        press(returnKey, in: controller)
        sync(controller, viewModel)
        XCTAssertNil(viewModel.draft)
        XCTAssertEqual(tree.names(), ["a.txt"])
    }

    func testATakenNameIsAnError() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        await startDraft(.file, in: tree.root, controller, viewModel)

        type("a.txt", into: controller)
        XCTAssertEqual(controller.nameEditor?.issue?.severity, .error)
        press(returnKey, in: controller)
        XCTAssertNotNil(viewModel.draft, "the field stays open")
    }

    func testTheDraftSurvivesAReloadOfItsFolder() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let (controller, _, viewModel) = await windowed(tree)
        await startDraft(.file, in: tree.root, controller, viewModel)
        type("typed", into: controller)
        let field = try XCTUnwrap(controller.nameEditor?.field)

        try tree.file("agent.txt")
        await viewModel.refresh().value
        sync(controller, viewModel)

        XCTAssertTrue(controller.nameEditor?.field === field)
        XCTAssertEqual(field.currentEditor()?.string, "typed")
    }

    func testASecondRequestReplacesTheFirstDraft() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("src")
        let (controller, _, viewModel) = await windowed(tree)
        await startDraft(.file, in: tree.root, controller, viewModel)

        await startDraft(.folder, in: tree.path("src"), controller, viewModel)

        XCTAssertEqual(viewModel.draft?.folder, tree.path("src"))
        XCTAssertEqual(controller.children(of: tree.root).map(\.role), [.entry])
        XCTAssertEqual(controller.children(of: tree.path("src")).map(\.role), [.draft])
        XCTAssertNotNil(controller.nameEditor)
    }

    func testTheMenusStartADraft() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt")
        let (controller, _, viewModel) = await windowed(tree)
        await viewModel.expand(tree.path("src")).value
        sync(controller, viewModel)

        controller.perform(.newFolder, on: [tree.path("src/a.txt")])
        await waitUntil { viewModel.draft != nil }

        XCTAssertEqual(viewModel.draft?.folder, tree.path("src"))
        XCTAssertEqual(viewModel.draft?.kind, .folder)
    }

    func testARootChangeDropsTheDraft() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let other = try TempTree(); defer { other.remove() }
        let (controller, _, viewModel) = await windowed(tree)
        await startDraft(.file, in: tree.root, controller, viewModel)

        await viewModel.setContext(local(other)).value
        sync(controller, viewModel)

        XCTAssertNil(viewModel.draft)
        XCTAssertNil(controller.nameEditor)
    }
}

@MainActor
private final class OpenRecorder: ExplorerActionHandler {
    var opened: [String] = []
    var canSendToAgent: Bool { false }
    func openFile(path: String) { opened.append(path) }
    func openMarkdownEditor(path: String) { opened.append(path) }
    func openInEditor(path: String) { opened.append(path) }
    func sendPathToAgent(path _: String) {}
}
