import XCTest
@testable import UnpeelExplorer

@MainActor
final class ExplorerPanelViewTests: XCTestCase {
    func testTitleIsTheRootFolderNameUppercased() {
        XCTAssertEqual(ExplorerPanelView.title(for: .local(root: "/Users/me/my-proj", projectRoot: "/Users/me/my-proj")), "MY-PROJ")
        XCTAssertEqual(ExplorerPanelView.title(for: .none), "EXPLORER")
        XCTAssertEqual(ExplorerPanelView.title(for: .remote), "EXPLORER")
    }

    func testEmptyStateMessages() {
        XCTAssertEqual(
            ExplorerPanelView.message(for: .none, rootError: nil),
            "Select a session to browse its files."
        )
        XCTAssertEqual(
            ExplorerPanelView.message(for: .remote, rootError: nil),
            "The explorer is available for sessions running on this Mac."
        )
        XCTAssertNil(ExplorerPanelView.message(for: .local(root: "/r", projectRoot: "/r"), rootError: nil))
        XCTAssertEqual(
            ExplorerPanelView.message(for: .local(root: "/r", projectRoot: "/r"), rootError: "Gone"),
            "Gone"
        )
    }

    func testRootNameIsTheLastPathComponentOrNil() {
        XCTAssertEqual(
            ExplorerPanelView.rootName(for: .local(root: "/Users/me/my-proj", projectRoot: "/Users/me/my-proj")),
            "my-proj"
        )
        XCTAssertNil(ExplorerPanelView.rootName(for: .none))
        XCTAssertNil(ExplorerPanelView.rootName(for: .remote))
    }

    func testPanelMenuItemsInOrder() {
        XCTAssertEqual(
            ExplorerPanelMenu.itemTitles,
            ["Refresh", "Collapse All", "Show Hidden Files", "Show Git-Ignored Files", "New File…", "New Folder…"]
        )
    }
}
