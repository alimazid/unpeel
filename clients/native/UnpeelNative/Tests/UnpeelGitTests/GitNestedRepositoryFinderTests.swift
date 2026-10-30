import Foundation
import XCTest
@testable import UnpeelGit

/// Fork-only: nested repositories. Finding the repositories inside a folder
/// that is not one, against real throwaway folders (a `.git` folder or file
/// is all the finder looks for, so no git runs here).
final class GitNestedRepositoryFinderTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("unpeel-nested-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = try XCTUnwrap(realpath(base.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func path(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    private func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    /// A repository: a folder holding a `.git` folder.
    private func repository(_ relative: String) throws {
        try folder(relative + "/.git")
    }

    func testFindsRepositoriesOneAndTwoLevelsDownInNameOrder() throws {
        try repository("web")
        try repository("api")
        try repository("services/billing")
        try folder("docs")

        let found = GitNestedRepositoryFinder().repositories(in: root)

        XCTAssertEqual(found, [path("api"), path("services/billing"), path("web")])
    }

    func testDoesNotLookDeeperThanTheDepth() throws {
        try repository("a/b/c")

        XCTAssertEqual(GitNestedRepositoryFinder().repositories(in: root), [])
        XCTAssertEqual(GitNestedRepositoryFinder(maxDepth: 3).repositories(in: root), [path("a/b/c")])
    }

    func testDoesNotLookInsideARepository() throws {
        try repository("app")
        try repository("app/vendor")

        XCTAssertEqual(GitNestedRepositoryFinder().repositories(in: root), [path("app")])
    }

    func testAWorktreeLinkFileCountsAsARepository() throws {
        try folder("linked")
        try "gitdir: /elsewhere/.git/worktrees/linked\n".write(toFile: path("linked/.git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitNestedRepositoryFinder().repositories(in: root), [path("linked")])
    }

    func testSkipsHiddenFoldersDependenciesAndSymlinks() throws {
        try repository(".cache/tool")
        try repository("node_modules/pkg")
        try repository("real")
        try FileManager.default.createSymbolicLink(atPath: path("alias"), withDestinationPath: path("real"))

        XCTAssertEqual(GitNestedRepositoryFinder().repositories(in: root), [path("real")])
    }

    /// Looking into a privacy-protected folder (Documents, Desktop, …)
    /// would ask the user for access out of nowhere.
    func testSkipsProtectedFolders() throws {
        try repository("Documents/notes")
        try repository("Documents")
        try repository("code")

        let finder = GitNestedRepositoryFinder(protectedFolders: [path("Documents")])

        XCTAssertEqual(finder.repositories(in: root), [path("code")])
    }

    func testStopsAtTheLimitKeepingTheShallowestFirst() throws {
        try repository("z-top")
        try repository("a/deep")
        try repository("b/deep")

        let found = GitNestedRepositoryFinder(limit: 2).repositories(in: root)

        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.contains(path("z-top")))
    }

    func testAFolderThatCannotBeReadHasNone() {
        XCTAssertEqual(GitNestedRepositoryFinder().repositories(in: path("missing")), [])
    }

    func testIsRepository() throws {
        try repository("app")
        try folder("plain")

        XCTAssertTrue(GitNestedRepositoryFinder.isRepository(path("app")))
        XCTAssertFalse(GitNestedRepositoryFinder.isRepository(path("plain")))
        XCTAssertFalse(GitNestedRepositoryFinder.isRepository(path("missing")))
    }
}
