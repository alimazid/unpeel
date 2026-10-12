import XCTest
@testable import UnpeelGit

final class GitHistoryHeaderTests: XCTestCase {
    func testCountsShowOnlyWithAUsableUpstream() {
        XCTAssertEqual(
            GitHistoryHeaderView.countsText(for: GitHead(oid: "a", branch: "main", upstream: "origin/main", ahead: 2, behind: 0)),
            "↑2 ↓0"
        )
        // In sync is still shown: it is a fact, unlike "no upstream".
        XCTAssertEqual(
            GitHistoryHeaderView.countsText(for: GitHead(oid: "a", branch: "main", upstream: "origin/main", ahead: 0, behind: 0)),
            "↑0 ↓0"
        )
        XCTAssertNil(GitHistoryHeaderView.countsText(for: GitHead(oid: "a", branch: "topic")))
        XCTAssertNil(GitHistoryHeaderView.countsText(for: GitHead(oid: "a", branch: "main", upstream: "origin/gone")))
    }

    func testCountsHelpNamesTheUpstream() {
        let head = GitHead(oid: "a", branch: "main", upstream: "origin/main", ahead: 1, behind: 3)
        XCTAssertEqual(
            GitHistoryHeaderView.countsHelp(for: head),
            "main is 1 ahead of and 3 behind origin/main, as of the last fetch."
        )
    }
}
