import XCTest
@testable import UnpeelNative

/// Fork-only: git support. A changed file opened from Git History is
/// revealed in the EXPLORER first, then opened through the EXPLORER's own
/// open-with path (`ExplorerHostActions`, covered by its own tests).
@MainActor
final class GitHistoryHostActionsTests: XCTestCase {
    func testOpeningAChangedFileRevealsItInTheExplorer() {
        let actions = GitHistoryHostActions()
        var revealed: [String] = []
        actions.reveal = { revealed.append($0) }

        actions.openChangedFile(path: "/repo/docs/readme.md")

        XCTAssertEqual(revealed, ["/repo/docs/readme.md"])
    }
}
