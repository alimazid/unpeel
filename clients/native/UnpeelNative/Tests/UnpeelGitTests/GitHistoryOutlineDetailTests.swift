import AppKit
import XCTest
@testable import UnpeelGit

@MainActor
private final class RecordingHandler: GitHistoryActionHandler {
    private(set) var opened: [String] = []

    func openChangedFile(path: String) {
        opened.append(path)
    }
}

@MainActor
final class GitHistoryOutlineDetailTests: XCTestCase {
    private var tree: GitTestRepo!
    /// Keeps the outline alive: the controller only holds it weakly.
    private var scroll: NSScrollView?

    override func setUpWithError() throws {
        tree = try GitTestRepo(initialize: false)
        try tree.write("docs/readme.md", "# hi")
        try tree.write("src/main.swift", "print()")
    }

    override func tearDown() {
        tree.delete()
        scroll = nil
    }

    private let files = [
        GitChangedFile(kind: .modified, path: "docs/readme.md"),
        GitChangedFile(kind: .deleted, path: "gone.txt"),
        GitChangedFile(kind: .renamed, path: "src/main.swift", oldPath: "main.swift"),
    ]

    private func make() async -> (GitHistoryViewModel, GitHistoryOutlineController, GitHistoryNSOutlineView, RecordingHandler) {
        let fake = FakeGitHistory()
        fake.setHead(.success(GitHead(oid: "c-2", branch: "main")), for: "/repo")
        fake.setCommits(fakeCommits(3), for: "/repo")
        fake.setLocation(GitRepositoryLocation(workTree: tree.root, gitDirectory: "", commonDirectory: ""), for: "/repo")
        fake.setDetail(.success(GitCommitDetail(sha: "c-1", message: "subject 1\n\nA longer body.", files: files)), for: "c-1")
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(.local(root: "/repo", projectRoot: "/repo")).value
        let controller = GitHistoryOutlineController(viewModel: viewModel, palette: .system)
        let handler = RecordingHandler()
        controller.actionHandler = handler
        let outline = GitHistoryOutlineView.makeOutlineView()
        controller.attach(to: outline)
        let scroll = GitHistoryOutlineView.makeScrollView(documentView: outline)
        scroll.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        self.scroll = scroll
        controller.apply(commits: viewModel.commits, expanded: viewModel.expanded)
        return (viewModel, controller, outline, handler)
    }

    private func sync(_ viewModel: GitHistoryViewModel, _ controller: GitHistoryOutlineController) {
        controller.apply(commits: viewModel.commits, expanded: viewModel.expanded)
    }

    func testExpandedCommitShowsItsMessageThenItsFiles() async throws {
        let (viewModel, controller, outline, _) = await make()

        await viewModel.toggleExpanded("c-1").value
        sync(viewModel, controller)

        XCTAssertEqual(outline.numberOfRows, 3 + 1 + files.count)
        let message = try XCTUnwrap(controller.outlineView(outline, viewFor: nil, item: try XCTUnwrap(outline.item(atRow: 2))) as? GitMessageCellView)
        XCTAssertEqual(message.messageField.stringValue, "subject 1\n\nA longer body.")
        let rename = try XCTUnwrap(controller.outlineView(outline, viewFor: nil, item: try XCTUnwrap(outline.item(atRow: 5))) as? GitChangedFileCellView)
        XCTAssertEqual(rename.letterField.stringValue, "R")
        XCTAssertEqual(rename.nameField.stringValue, "main.swift")
        XCTAssertEqual(rename.detailField.stringValue, "src ← main.swift")
    }

    func testFileLettersUseTheSharedPalette() async throws {
        let (viewModel, controller, outline, _) = await make()
        await viewModel.toggleExpanded("c-1").value
        sync(viewModel, controller)

        for (offset, file) in files.enumerated() {
            let cell = try XCTUnwrap(controller.outlineView(outline, viewFor: nil, item: try XCTUnwrap(outline.item(atRow: 3 + offset))) as? GitChangedFileCellView)
            XCTAssertEqual(cell.letterField.stringValue, file.kind.letter)
            XCTAssertEqual(cell.letterField.textColor, file.kind.color)
        }
    }

    func testLoadingDetailShowsAPlaceholderRow() async throws {
        let (viewModel, controller, outline, _) = await make()

        let pending = viewModel.toggleExpanded("c-0")
        sync(viewModel, controller)

        XCTAssertEqual(outline.numberOfRows, 4)
        let message = try XCTUnwrap(controller.outlineView(outline, viewFor: nil, item: try XCTUnwrap(outline.item(atRow: 3))) as? GitMessageCellView)
        XCTAssertEqual(message.messageField.stringValue, "Loading…")
        await pending.value
    }

    func testExpandingAnotherCommitCollapsesTheFirstInTheOutline() async {
        let (viewModel, controller, outline, _) = await make()
        await viewModel.toggleExpanded("c-1").value
        sync(viewModel, controller)

        await viewModel.toggleExpanded("c-2").value
        sync(viewModel, controller)

        XCTAssertEqual(outline.numberOfRows, 3 + 1)
        XCTAssertFalse(outline.isItemExpanded(outline.item(atRow: 2)))
    }

    func testClickingACommitRowTogglesIt() async {
        let (viewModel, controller, outline, _) = await make()

        await controller.activate(row: 1)?.value
        XCTAssertEqual(viewModel.expanded?.sha, "c-1")
        sync(viewModel, controller)
        XCTAssertEqual(outline.numberOfRows, 3 + 1 + files.count)

        await controller.activate(row: 1)?.value
        XCTAssertNil(viewModel.expanded)
    }

    func testClickingAnExistingFileOpensItAndAMissingOneDoesNothing() async {
        let (viewModel, controller, _, handler) = await make()
        await viewModel.toggleExpanded("c-1").value
        sync(viewModel, controller)

        controller.activate(row: 3)
        controller.activate(row: 4)
        controller.activate(row: 5)
        controller.activate(row: 2)

        XCTAssertEqual(handler.opened, [tree.path("docs/readme.md"), tree.path("src/main.swift")])
    }

    /// → / ← in the outline expand and collapse through the view model, so
    /// keyboard and click agree on the one expanded commit.
    func testOutlineExpansionReachesTheViewModel() async {
        let (viewModel, controller, outline, _) = await make()

        outline.expandItem(outline.item(atRow: 0))
        XCTAssertEqual(viewModel.expanded?.sha, "c-2")

        outline.collapseItem(outline.item(atRow: 0))
        XCTAssertNil(viewModel.expanded)
        XCTAssertNotNil(controller.outlineView)
    }

    func testCommitMenuWorksFromItsDetailRows() async {
        let (viewModel, controller, _, _) = await make()
        await viewModel.toggleExpanded("c-1").value
        sync(viewModel, controller)
        let menu = NSMenu()

        controller.rebuildMenuItems(menu, forRow: 4)

        XCTAssertEqual(menu.items.map(\.title), ["Copy SHA", "Copy Subject"])
    }
}
