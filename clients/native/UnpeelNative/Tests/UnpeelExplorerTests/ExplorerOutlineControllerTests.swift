import AppKit
import XCTest
@testable import UnpeelExplorer

@MainActor
private final class RecordingHandler: ExplorerActionHandler {
    var canSendToAgent = true
    var opened: [String] = []
    var sent: [String] = []
    func openInEditor(path: String) { opened.append(path) }
    func sendPathToAgent(path: String) { sent.append(path) }
}

@MainActor
final class ExplorerOutlineControllerTests: XCTestCase {
    private let root = "/r"

    private func makeController() -> (ExplorerOutlineController, ExplorerViewModel, String) {
        let suite = "unpeel.explorer.outlinetests.\(UUID().uuidString)"
        let viewModel = ExplorerViewModel(
            services: ExplorerServices(scan: { _, _ in DirectoryListing(entries: []) }, makeWatcher: { _, _ in nil }),
            stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!)
        )
        return (ExplorerOutlineController(viewModel: viewModel, palette: .system), viewModel, suite)
    }

    private func sampleModel(truncated: Int = 0) -> FileTreeModel {
        FileTreeModel(root: root)
            .settingContents(
                .loaded(DirectoryListing(
                    entries: [
                        FileEntry(path: "/r/src", name: "src", kind: .directory),
                        FileEntry(path: "/r/.env", name: ".env", kind: .file, isHidden: true),
                        FileEntry(path: "/r/a.txt", name: "a.txt", kind: .file),
                    ],
                    truncatedCount: truncated
                )),
                for: root
            )
            .settingContents(.failed("Permission denied"), for: "/r/src")
            .expanding("/r/src")
    }

    func testChildrenFollowTheFilter() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        XCTAssertEqual(controller.children(of: root).map(\.path), ["/r/src", "/r/a.txt"])

        controller.apply(model: sampleModel(), filter: VisibilityFilter(showHidden: true), selection: [])
        XCTAssertEqual(controller.children(of: root).map(\.path), ["/r/src", "/r/.env", "/r/a.txt"])
    }

    func testTruncatedAndFailedDirectoriesGetANoteRow() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        controller.apply(model: sampleModel(truncated: 12), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.children(of: root).last?.role, .note("… 12 more items not shown"))
        XCTAssertEqual(controller.children(of: "/r/src").map(\.role), [.note("Permission denied")])
    }

    func testItemsKeepTheirIdentityAcrossReloads() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        let before = controller.children(of: root).first

        let grown = sampleModel().settingContents(
            .loaded(DirectoryListing(entries: [
                FileEntry(path: "/r/src", name: "src", kind: .directory),
                FileEntry(path: "/r/a.txt", name: "a.txt", kind: .file),
                FileEntry(path: "/r/b.txt", name: "b.txt", kind: .file),
            ])),
            for: root
        )
        controller.apply(model: grown, filter: VisibilityFilter(), selection: [])

        XCTAssertTrue(before === controller.children(of: root).first)
        XCTAssertEqual(controller.children(of: root).count, 3)
    }

    func testDataSourceAnswersForAnAttachedOutlineView() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.attach(to: outline)

        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.outlineView(outline, numberOfChildrenOfItem: nil), 2)
        let first = controller.outlineView(outline, child: 0, ofItem: nil)
        XCTAssertEqual((first as? ExplorerItem)?.path, "/r/src")
        XCTAssertTrue(controller.outlineView(outline, isItemExpandable: first))
        let second = controller.outlineView(outline, child: 1, ofItem: nil)
        XCTAssertFalse(controller.outlineView(outline, isItemExpandable: second))
    }

    func testMenuActionsDependOnTheTarget() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.menuActions(for: nil), [.refresh])
        XCTAssertEqual(
            controller.menuActions(for: "/r/a.txt"),
            [.openInEditor, .revealInFinder, .quickLook, nil, .sendToAgent, nil, .copyPath, .copyRelativePath, nil, .refresh]
        )
        XCTAssertEqual(
            controller.menuActions(for: "/r/src"),
            [.revealInFinder, nil, .sendToAgent, nil, .copyPath, .copyRelativePath, nil, .refresh, .collapse]
        )

        handler.canSendToAgent = false
        XCTAssertFalse(controller.menuActions(for: "/r/a.txt").contains(.sendToAgent))
    }

    func testPerformRoutesToTheHandlerAndPasteboard() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        controller.actionHandler = handler
        controller.pasteboard = pasteboard
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.perform(.openInEditor, on: ["/r/a.txt"])
        controller.perform(.sendToAgent, on: ["/r/a.txt"])
        XCTAssertEqual(handler.opened, ["/r/a.txt"])
        XCTAssertEqual(handler.sent, ["/r/a.txt"])

        controller.perform(.copyPath, on: ["/r/a.txt", "/r/src"])
        XCTAssertEqual(pasteboard.string(forType: .string), "/r/a.txt\n/r/src")

        controller.perform(.copyRelativePath, on: ["/r/a.txt"])
        XCTAssertEqual(pasteboard.string(forType: .string), "a.txt")
    }

    func testOpenKeyCommandOpensSelectedFiles() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        viewModel.selection = ["/r/a.txt"]

        XCTAssertTrue(controller.handleKeyCommand(.open))
        XCTAssertEqual(handler.opened, ["/r/a.txt"])
    }
}
