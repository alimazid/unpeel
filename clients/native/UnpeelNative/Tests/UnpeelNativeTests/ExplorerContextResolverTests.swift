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

    func testAgentReferenceIsRelativeInsideTheRoot() {
        XCTAssertEqual(ExplorerContextResolver.agentReference(for: "/p/src/a b.swift", root: "/p"), "src/a b.swift")
        XCTAssertEqual(ExplorerContextResolver.agentReference(for: "/elsewhere/x", root: "/p"), "/elsewhere/x")
    }
}
