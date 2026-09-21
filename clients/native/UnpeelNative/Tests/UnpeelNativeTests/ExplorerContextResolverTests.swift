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

    func testDropReferenceInsideTheRootIsRelative() {
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(
                for: "/p/.worktrees/fix/src/a.swift",
                dropRoot: "/p/.worktrees/fix"
            ),
            "src/a.swift"
        )
    }

    func testDropReferenceForAnImageStaysAbsolute() {
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(
                for: "/p/.worktrees/fix/img.png",
                dropRoot: "/p/.worktrees/fix"
            ),
            "/p/.worktrees/fix/img.png"
        )
    }

    func testDropReferenceOutsideTheRootFallsBackToHomeRelative() {
        let path = NSHomeDirectory() + "/Documents/notes.txt"
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(for: path, dropRoot: "/p/.worktrees/fix"),
            "~/Documents/notes.txt"
        )
    }

    func testDropReferenceWithNoRootStaysAbsolute() {
        XCTAssertEqual(
            ExplorerContextResolver.dropReference(for: "/opt/agent/reference.md", dropRoot: nil),
            "/opt/agent/reference.md"
        )
    }
}
