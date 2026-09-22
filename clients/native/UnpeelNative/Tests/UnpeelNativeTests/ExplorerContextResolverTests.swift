import UnpeelExplorer
import XCTest
@testable import UnpeelNative

final class ExplorerContextResolverTests: XCTestCase {
    func testRemoteScopeWinsOverEverything() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: false, hasSession: true,
                worktreePath: "/w", projectPath: "/p", fallbackDirectory: "/c"
            ),
            .remote
        )
    }

    func testNoSessionMeansNoContext() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: false,
                worktreePath: nil, projectPath: "/p", fallbackDirectory: nil
            ),
            .none
        )
    }

    func testWorktreeBeatsProjectButProjectStaysTheProjectRoot() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: true,
                worktreePath: "/p/.worktrees/fix", projectPath: "/p", fallbackDirectory: "/c"
            ),
            .local(root: "/p/.worktrees/fix", projectRoot: "/p")
        )
    }

    func testBlankWorktreeFallsBackToProjectThenDirectory() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: true,
                worktreePath: "  ", projectPath: "/p", fallbackDirectory: "/c"
            ),
            .local(root: "/p", projectRoot: "/p")
        )
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: true,
                worktreePath: nil, projectPath: nil, fallbackDirectory: "/c"
            ),
            .local(root: "/c", projectRoot: "/c")
        )
    }

    func testNothingUsableMeansNoContext() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: true,
                worktreePath: nil, projectPath: "", fallbackDirectory: nil
            ),
            .none
        )
    }

    // MARK: - targetSessionID

    func testActivePaneWinsOverEverything() {
        XCTAssertEqual(
            ExplorerContextResolver.targetSessionID(activePane: "a", focusedSolo: "b", selected: "c"),
            "a"
        )
    }

    func testFocusedSoloWinsWhenNoActivePane() {
        XCTAssertEqual(
            ExplorerContextResolver.targetSessionID(activePane: nil, focusedSolo: "b", selected: "c"),
            "b"
        )
    }

    func testSelectedIsTheLastResort() {
        XCTAssertEqual(
            ExplorerContextResolver.targetSessionID(activePane: nil, focusedSolo: nil, selected: "c"),
            "c"
        )
    }

    func testNoneOfTheThreeMeansNoTarget() {
        XCTAssertNil(ExplorerContextResolver.targetSessionID(activePane: nil, focusedSolo: nil, selected: nil))
    }

    // MARK: - dropReference

    /// Fixed so `dropReference`'s home-relative tier is exercised without
    /// depending on the machine running the tests.
    private let fakeHome = "/Users/faketester"

    func testDropReferenceInsideTheRootIsRelative() {
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(
                for: "/p/.worktrees/fix/src/a.swift",
                dropRoot: "/p/.worktrees/fix",
                homeDirectory: fakeHome
            ),
            "src/a.swift"
        )
    }

    func testDropReferenceForAnImageStaysAbsolute() {
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(
                for: "/p/.worktrees/fix/img.png",
                dropRoot: "/p/.worktrees/fix",
                homeDirectory: fakeHome
            ),
            "/p/.worktrees/fix/img.png"
        )
    }

    func testDropReferenceOutsideTheRootFallsBackToHomeRelative() {
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(
                for: fakeHome + "/Documents/notes.txt",
                dropRoot: "/p/.worktrees/fix",
                homeDirectory: fakeHome
            ),
            "~/Documents/notes.txt"
        )
    }

    func testDropReferenceWithNoRootStaysAbsolute() {
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(
                for: "/opt/agent/reference.md",
                dropRoot: nil,
                homeDirectory: fakeHome
            ),
            "/opt/agent/reference.md"
        )
    }

    // MARK: - dropRoot

    func testDropRootPrefersThePaneDirectoryOverTheExplorerRoot() {
        XCTAssertEqual(
            ExplorerContextResolver.dropRoot(
                targetPaneDirectory: "/repo/.worktrees/b",
                explorerRoot: "/repo/.worktrees/a"
            ),
            "/repo/.worktrees/b"
        )
    }

    func testDropRootFallsBackToTheExplorerRootWhenPaneDirectoryIsBlank() {
        XCTAssertEqual(
            ExplorerContextResolver.dropRoot(targetPaneDirectory: nil, explorerRoot: "/repo/.worktrees/a"),
            "/repo/.worktrees/a"
        )
        XCTAssertEqual(
            ExplorerContextResolver.dropRoot(targetPaneDirectory: "   ", explorerRoot: "/repo/.worktrees/a"),
            "/repo/.worktrees/a"
        )
    }

    func testDropRootIsNilWhenNeitherIsKnown() {
        XCTAssertNil(ExplorerContextResolver.dropRoot(targetPaneDirectory: nil, explorerRoot: nil))
    }

    /// End-to-end: reproduces the defect the review reported — a file from
    /// worktree A's tree, sent while a pane rooted in worktree B has focus,
    /// must NOT resolve to the bare relative path (which would silently name
    /// B's mirrored copy instead of A's).
    func testSendingAFileToAPaneFocusedOnAnotherWorktreeDoesNotYieldTheBareRelativePath() {
        let path = "/repo/.worktrees/a/src/a.swift"

        let sameWorktree = ExplorerContextResolver.dropRoot(
            targetPaneDirectory: "/repo/.worktrees/a",
            explorerRoot: "/repo/.worktrees/a"
        )
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(for: path, dropRoot: sameWorktree, homeDirectory: fakeHome),
            "src/a.swift"
        )

        let otherWorktree = ExplorerContextResolver.dropRoot(
            targetPaneDirectory: "/repo/.worktrees/b",
            explorerRoot: "/repo/.worktrees/a"
        )
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(for: path, dropRoot: otherWorktree, homeDirectory: fakeHome),
            path
        )
    }

    /// `openFile` goes through the open-with rules only when there is a
    /// session to attach a plugin pane to; without one the editor is the
    /// fallback so the gesture never silently does nothing.
    func testOpenRouteNeedsASessionForTheRules() {
        XCTAssertEqual(ExplorerContextResolver.openRoute(sessionID: "s1"), .rules(sessionID: "s1"))
        XCTAssertEqual(ExplorerContextResolver.openRoute(sessionID: nil), .editor)
        XCTAssertEqual(ExplorerContextResolver.openRoute(sessionID: ""), .editor)
    }

    /// With no store attached (the panel before its first body pass) every
    /// handler member must be a safe no-op rather than a crash, even once a
    /// tree session is known (`rootSessionID` alone must not reach the
    /// unowned `store`).
    @MainActor
    func testHostActionsWithoutAStoreAreNoOps() {
        let actions = ExplorerHostActions()
        actions.rootSessionID = "s1"
        actions.openFile(path: "/tmp/README.md")
        actions.openMarkdownEditor(path: "/tmp/README.md")
        actions.openInEditor(path: "/tmp/README.md")
        actions.sendPathToAgent(path: "/tmp/README.md")
        XCTAssertFalse(actions.canSendToAgent)
    }
}
