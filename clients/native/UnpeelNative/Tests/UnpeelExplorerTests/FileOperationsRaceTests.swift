import XCTest
@testable import UnpeelExplorer

/// Agents write while the user works: what appears or vanishes between a
/// check and the act must never be overwritten, merged into, or lost.
final class FileOperationsRaceTests: XCTestCase {
    private var tree: TempTree!
    private var trash: FolderTrash!

    override func setUpWithError() throws {
        tree = try TempTree()
        trash = try FolderTrash()
    }

    override func tearDown() {
        tree.remove()
        trash.remove()
    }

    private func operations(_ trasher: any Trasher) throws -> FileOperations {
        try XCTUnwrap(FileOperations(root: tree.root, trasher: trasher))
    }

    func testACopyNeverMergesIntoAFolderThatAppearedAtTheDestination() throws {
        try tree.file("src/a.txt", "A"); try tree.file("dest/src/agent.txt", "agent")
        let ops = try operations(trash)

        XCTAssertThrowsError(try ops.copyItem(tree.path("src"), to: tree.path("dest/src"))) { error in
            XCTAssertEqual(error as? FileOperationFailure, .nameCollision(tree.path("dest/src")))
        }
        XCTAssertEqual(tree.names("dest/src"), ["agent.txt"])
        XCTAssertEqual(tree.names("dest"), ["src"])
    }

    func testACopyNeverWritesThroughASymlinkThatAppearedAtTheDestination() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try tree.file("src/a.txt"); try tree.dir("dest")
        try tree.symlink("dest/src", to: outside.root)
        let ops = try operations(trash)

        XCTAssertThrowsError(try ops.copyItem(tree.path("src"), to: tree.path("dest/src")))
        XCTAssertEqual(outside.names(), [])
    }

    func testAFailedCopyLeavesNothingBehind() throws {
        try tree.dir("dest")
        let ops = try operations(trash)

        XCTAssertThrowsError(try ops.copyItem(tree.path("missing"), to: tree.path("dest/missing"))) { error in
            XCTAssertEqual(error as? FileOperationFailure, .sourceMissing(tree.path("missing")))
        }
        XCTAssertEqual(tree.names("dest"), [])
    }

    func testAReplaceWhoseMoveFailsPutsTheReplacedItemBack() throws {
        try tree.file("a.txt", "new"); try tree.file("dest/a.txt", "old")
        let source = tree.path("a.txt")
        // The agent deletes the source right after the old item is trashed.
        let ops = try operations(HookTrash(trash: trash) { _ in try? FileManager.default.removeItem(atPath: source) })

        let outcome = ops.move([source], into: tree.path("dest"), resolutions: [source: .replace])

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.sourceMissing(source)])
        XCTAssertEqual(tree.contents("dest/a.txt"), "old")
        XCTAssertEqual(trash.contents, [])
    }

    func testAReplaceThatCannotPutTheItemBackKeepsTheTrashStep() throws {
        try tree.file("a.txt", "new"); try tree.file("dest/a.txt", "old")
        let source = tree.path("a.txt")
        let target = tree.path("dest/a.txt")
        // The agent writes a new file at the destination right after the
        // old one is trashed: neither the move nor the put-back can land.
        let ops = try operations(HookTrash(trash: trash) { _ in
            try? "agent".write(toFile: target, atomically: false, encoding: .utf8)
        })

        let outcome = ops.move([source], into: tree.path("dest"), resolutions: [source: .replace])

        XCTAssertEqual(outcome.failures, [.nameCollision(target)])
        XCTAssertEqual(tree.describe(outcome.record), ["trashed dest/a.txt"])
        XCTAssertEqual(tree.contents("a.txt"), "new")
        XCTAssertEqual(tree.contents("dest/a.txt"), "agent")
        XCTAssertEqual(trash.contents, ["a.txt"])
    }

    func testRenameNeverCreatesADotGit() throws {
        try tree.dir("src")
        let ops = try operations(trash)

        XCTAssertEqual(ops.rename(tree.path("src"), to: ".git").failures, [.insideDotGit(tree.path(".git"))])
        XCTAssertTrue(tree.isDirectory("src"))
    }

    func testOnlyANameDifferingByCaseCountsAsACaseOnlyRename() {
        XCTAssertTrue(FileOperations.isCaseOnlyRename("/p/readme.md", "/p/README.md"))
        XCTAssertFalse(FileOperations.isCaseOnlyRename("/p/a", "/p/b"))
        XCTAssertFalse(FileOperations.isCaseOnlyRename("/p/a", "/q/A"))
        XCTAssertFalse(FileOperations.isCaseOnlyRename("/p/a", "/p/a"))
    }

    func testAHardLinkIsNeverRenamedOverItsTwin() throws {
        try tree.file("a.txt", "A")
        try FileManager.default.linkItem(atPath: tree.path("a.txt"), toPath: tree.path("b.txt"))
        let ops = try operations(trash)

        let outcome = ops.rename(tree.path("a.txt"), to: "b.txt")

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.nameCollision(tree.path("b.txt"))])
        XCTAssertEqual(tree.names(), ["a.txt", "b.txt"])
    }
}
