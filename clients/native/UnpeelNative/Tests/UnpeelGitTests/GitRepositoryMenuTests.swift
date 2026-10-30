import XCTest
@testable import UnpeelGit

/// Fork-only: nested repositories. When Git History offers the nested
/// repositories of an Explorer Root that is not one, and how it names them.
@MainActor
final class GitRepositoryMenuTests: XCTestCase {
    private func state(
        _ folder: GitRepositoryRootState.Folder, nested: [String] = [], chosen: String? = nil
    ) -> GitRepositoryRootState {
        GitRepositoryRootState(explorerRoot: "/p", directory: "/p", folder: folder, nested: nested, chosen: chosen)
    }

    func testTheMenuShowsOnlyForAFolderWithNestedRepositories() {
        XCTAssertTrue(GitRepositoryMenu.isShown(for: state(.notARepository, nested: ["/p/app"], chosen: "/p/app")))
        XCTAssertTrue(GitRepositoryMenu.isShown(for: state(.notARepository, nested: ["/p/a", "/p/b"])))
        XCTAssertFalse(GitRepositoryMenu.isShown(for: state(.notARepository)))
        XCTAssertFalse(GitRepositoryMenu.isShown(for: state(.repository)))
        XCTAssertFalse(GitRepositoryMenu.isShown(for: nil))
    }

    func testTheMenuNamesTheRepositoryInUse() {
        XCTAssertEqual(GitRepositoryMenu.title(for: state(.notARepository, nested: ["/p/web/app"], chosen: "/p/web/app")), "web/app")
        XCTAssertEqual(GitRepositoryMenu.title(for: state(.notARepository, nested: ["/p/a", "/p/b"])), GitRepositoryMenu.noneTitle)
    }

    func testTheEmptyStateListsTheChoicesOnlyWhileNoneIsInUse() {
        let waiting = state(.notARepository, nested: ["/p/a", "/p/b"])
        XCTAssertEqual(GitHistoryPanelView.choices(status: .notARepository, repository: waiting), ["/p/a", "/p/b"])
        XCTAssertEqual(GitHistoryPanelView.choices(status: .notARepository, repository: state(.notARepository)), [])
        XCTAssertEqual(GitHistoryPanelView.choices(status: .notARepository, repository: nil), [])
        XCTAssertEqual(GitHistoryPanelView.choices(status: .noCommits, repository: waiting), [])
        // A chosen repository that is unreadable is not offered again as
        // if nothing were chosen; the menu above still switches.
        let chosen = state(.notARepository, nested: ["/p/a", "/p/b"], chosen: "/p/a")
        XCTAssertEqual(GitHistoryPanelView.choices(status: .notARepository, repository: chosen), [])
    }
}
