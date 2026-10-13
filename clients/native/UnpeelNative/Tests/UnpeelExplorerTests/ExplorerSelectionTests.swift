import XCTest
@testable import UnpeelExplorer

final class ExplorerSelectionTests: XCTestCase {
    private let rows = ["/r/a", "/r/b", "/r/b/x", "/r/b/y", "/r/c", "/r/d"]

    func testTheNextRowAfterTheRemovedOnesIsSelected() {
        XCTAssertEqual(ExplorerSelection.afterRemoving(["/r/a"], rows: rows), "/r/b")
        XCTAssertEqual(ExplorerSelection.afterRemoving(["/r/a", "/r/c"], rows: rows), "/r/d")
    }

    func testAFolderTakesItsRowsWithIt() {
        XCTAssertEqual(ExplorerSelection.afterRemoving(["/r/b"], rows: rows), "/r/c")
    }

    func testAtTheEndThePreviousRowIsSelected() {
        XCTAssertEqual(ExplorerSelection.afterRemoving(["/r/d"], rows: rows), "/r/c")
        XCTAssertEqual(ExplorerSelection.afterRemoving(["/r/c", "/r/d"], rows: rows), "/r/b/y")
    }

    func testRemovingEverythingSelectsNothing() {
        XCTAssertNil(ExplorerSelection.afterRemoving(["/r/a", "/r/b", "/r/c", "/r/d"], rows: rows))
        XCTAssertNil(ExplorerSelection.afterRemoving(["/r/zzz"], rows: rows))
    }
}
