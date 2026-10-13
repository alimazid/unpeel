import XCTest
@testable import UnpeelExplorer

/// `FileOperations` against real temporary trees (spec §5: no mocked file
/// system). The Trash is a plain folder (`FolderTrash`) except in the one
/// round trip through the real one.
final class FileOperationsTests: XCTestCase {
    private var tree: TempTree!
    private var trash: FolderTrash!
    private var ops: FileOperations!

    override func setUpWithError() throws {
        tree = try TempTree()
        trash = try FolderTrash()
        ops = try XCTUnwrap(FileOperations(root: tree.root, trasher: trash))
    }

    override func tearDown() {
        tree.remove()
        trash.remove()
    }

    // MARK: - Create

    func testCreateFileMakesAnEmptyFile() {
        let outcome = ops.createFile("notes.txt", in: tree.root)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.contents("notes.txt"), "")
        XCTAssertEqual(outcome.record?.kind, .newFile)
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("notes.txt")])
        XCTAssertEqual(tree.describe(outcome.record), ["created notes.txt"])
    }

    func testCreateFileWithANestedPathCreatesTheMissingFolders() throws {
        try tree.dir("src")

        let outcome = ops.createFile("src/utils/deep/x.ts", in: tree.root)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(tree.exists("src/utils/deep/x.ts"))
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("src/utils/deep/x.ts")])
        XCTAssertEqual(tree.describe(outcome.record), [
            "created src/utils (if empty)", "created src/utils/deep (if empty)", "created src/utils/deep/x.ts",
        ])
    }

    func testCreateFolderMakesAFolderThatUndoTrashesOnlyWhenEmpty() {
        let outcome = ops.createFolder("build", in: tree.root)

        XCTAssertTrue(tree.isDirectory("build"))
        XCTAssertEqual(outcome.record?.kind, .newFolder)
        XCTAssertEqual(tree.describe(outcome.record), ["created build (if empty)"])
    }

    func testCreateRefusesAnExistingName() throws {
        try tree.file("notes.txt", "keep me")

        let outcome = ops.createFile("notes.txt", in: tree.root)

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.nameCollision(tree.path("notes.txt"))])
        XCTAssertEqual(tree.contents("notes.txt"), "keep me")
    }

    func testCreateRefusesAPathThroughAFile() throws {
        try tree.file("a")

        let outcome = ops.createFile("a/b.txt", in: tree.root)

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.nameCollision(tree.path("a"))])
    }

    func testCreateRefusesAnInvalidName() {
        XCTAssertEqual(
            ops.createFile("../escape.txt", in: tree.root).failures,
            [.invalidName("The name “../escape.txt” is not valid as a file or folder name. Please choose a different name.")]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: (tree.root as NSString).deletingLastPathComponent + "/escape.txt"))
    }

    func testCreateInsideASymlinkedFolderThatLeavesTheRootIsRefused() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try tree.symlink("out", to: outside.root)

        let outcome = ops.createFile("x.txt", in: tree.path("out"))

        XCTAssertEqual(outcome.failures, [.outsideRoot(tree.path("out"))])
        XCTAssertEqual(outside.names(), [])
    }

    func testCreateInsideDotGitIsRefused() throws {
        try tree.dir(".git")

        XCTAssertEqual(ops.createFile("hooks", in: tree.path(".git")).failures, [.insideDotGit(tree.path(".git"))])
        XCTAssertEqual(ops.createFolder(".git/x", in: tree.root).failures, [.insideDotGit(tree.path(".git/x"))])
    }

    // MARK: - Rename

    func testRenameAFile() throws {
        try tree.file("a.txt", "A")

        let outcome = ops.rename(tree.path("a.txt"), to: "b.txt")

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.names(), ["b.txt"])
        XCTAssertEqual(tree.contents("b.txt"), "A")
        XCTAssertEqual(outcome.record?.kind, .rename)
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("b.txt")])
        XCTAssertEqual(tree.describe(outcome.record), ["moved a.txt -> b.txt"])
    }

    func testRenameAFolderKeepsItsContents() throws {
        try tree.file("src/a.swift")

        _ = ops.rename(tree.path("src"), to: "Sources")

        XCTAssertTrue(tree.exists("Sources/a.swift"))
        XCTAssertFalse(tree.exists("src"))
    }

    func testCaseOnlyRenameWorks() throws {
        try tree.file("readme.md", "R")

        let outcome = ops.rename(tree.path("readme.md"), to: "README.md")

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.names(), ["README.md"])
    }

    func testRenameNeverOverwrites() throws {
        try tree.file("a.txt", "A")
        try tree.file("b.txt", "B")

        let outcome = ops.rename(tree.path("a.txt"), to: "b.txt")

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.nameCollision(tree.path("b.txt"))])
        XCTAssertEqual(tree.contents("a.txt"), "A")
        XCTAssertEqual(tree.contents("b.txt"), "B")
    }

    func testRenameToTheSameNameDoesNothing() throws {
        try tree.file("a.txt")

        let outcome = ops.rename(tree.path("a.txt"), to: "a.txt")

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [])
    }

    func testRenameRefusesASlash() throws {
        try tree.file("a.txt")

        XCTAssertEqual(
            ops.rename(tree.path("a.txt"), to: "sub/a.txt").failures,
            [.invalidName("A file or folder name cannot contain a slash.")]
        )
    }

    func testRenameOfAMissingItemFails() {
        XCTAssertEqual(ops.rename(tree.path("gone.txt"), to: "x.txt").failures, [.sourceMissing(tree.path("gone.txt"))])
    }

    func testTheRootAndDotGitCannotBeRenamed() throws {
        try tree.file(".git/HEAD")

        XCTAssertEqual(ops.rename(tree.root, to: "other").failures, [.isRoot])
        XCTAssertEqual(ops.rename(tree.path(".git"), to: "git").failures, [.insideDotGit(tree.path(".git"))])
        XCTAssertEqual(ops.rename(tree.path(".git/HEAD"), to: "x").failures, [.insideDotGit(tree.path(".git/HEAD"))])
    }

    func testRenamingASymlinkRenamesTheLinkNotItsTarget() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try outside.file("target.txt", "T")
        try tree.symlink("link", to: outside.path("target.txt"))

        let outcome = ops.rename(tree.path("link"), to: "renamed")

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.linkDestination("renamed"), outside.path("target.txt"))
        XCTAssertEqual(outside.names(), ["target.txt"])
    }

    // MARK: - Move

    func testMoveItemsIntoAFolder() throws {
        try tree.file("a.txt"); try tree.dir("b"); try tree.file("b/inner.txt"); try tree.dir("dest")

        let outcome = ops.move([tree.path("a.txt"), tree.path("b")], into: tree.path("dest"))

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.names(), ["dest"])
        XCTAssertEqual(tree.names("dest"), ["a.txt", "b"])
        XCTAssertTrue(tree.exists("dest/b/inner.txt"))
        XCTAssertEqual(outcome.record?.kind, .move)
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("dest/a.txt"), tree.path("dest/b")])
        XCTAssertEqual(tree.describe(outcome.record), ["moved a.txt -> dest/a.txt", "moved b -> dest/b"])
    }

    func testMovingIntoTheSameFolderDoesNothing() throws {
        try tree.file("a.txt")

        let outcome = ops.move([tree.path("a.txt")], into: tree.root)

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [])
    }

    func testAFolderCannotMoveIntoItselfOrADescendant() throws {
        try tree.dir("a/b")

        XCTAssertEqual(ops.move([tree.path("a")], into: tree.path("a")).failures, [.intoOwnDescendant(tree.path("a"))])
        XCTAssertEqual(ops.move([tree.path("a")], into: tree.path("a/b")).failures, [.intoOwnDescendant(tree.path("a"))])
        XCTAssertTrue(tree.isDirectory("a/b"))
    }

    func testMoveOutsideTheRootIsRefused() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try tree.file("a.txt")

        XCTAssertEqual(ops.move([tree.path("a.txt")], into: outside.root).failures, [.outsideRoot(outside.root)])
        XCTAssertEqual(
            ops.move([tree.path("a.txt")], into: tree.root + "/../" + (outside.root as NSString).lastPathComponent).failures.count,
            1
        )
        XCTAssertTrue(tree.exists("a.txt"))
    }

    func testAMoveCollisionWithoutAnAnswerFailsAndKeepsBoth() throws {
        try tree.file("a.txt", "new"); try tree.file("dest/a.txt", "old")

        let outcome = ops.move([tree.path("a.txt")], into: tree.path("dest"))

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.nameCollision(tree.path("dest/a.txt"))])
        XCTAssertEqual(tree.contents("a.txt"), "new")
        XCTAssertEqual(tree.contents("dest/a.txt"), "old")
    }

    func testCollidingSourcesAreReportedBeforehand() throws {
        try tree.file("a.txt"); try tree.file("b.txt"); try tree.file("dest/a.txt")

        XCTAssertEqual(
            ops.collidingSources([tree.path("a.txt"), tree.path("b.txt")], into: tree.path("dest")),
            [tree.path("a.txt")]
        )
        // Already in that folder: a move there is a no-op, not a collision.
        XCTAssertEqual(ops.collidingSources([tree.path("dest/a.txt")], into: tree.path("dest")), [])
    }

    func testKeepBothMovesUnderAnIncrementedName() throws {
        try tree.file("a.txt", "new"); try tree.file("dest/a.txt", "old")

        let outcome = ops.move([tree.path("a.txt")], into: tree.path("dest"), resolutions: [tree.path("a.txt"): .keepBoth])

        XCTAssertEqual(tree.names("dest"), ["a copy.txt", "a.txt"])
        XCTAssertEqual(tree.contents("dest/a copy.txt"), "new")
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("dest/a copy.txt")])
    }

    func testReplaceTrashesTheExistingItemFirst() throws {
        try tree.file("a.txt", "new"); try tree.file("dest/a.txt", "old")

        let outcome = ops.move([tree.path("a.txt")], into: tree.path("dest"), resolutions: [tree.path("a.txt"): .replace])

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.contents("dest/a.txt"), "new")
        XCTAssertEqual(trash.contents, ["a.txt"])
        XCTAssertEqual(tree.describe(outcome.record), ["trashed dest/a.txt", "moved a.txt -> dest/a.txt"])
    }

    func testReplaceRefusesToTrashAFolderHoldingTheSource() throws {
        try tree.file("x/x/inner.txt")

        // Moving x/x up into the root would replace x, which holds x/x.
        let outcome = ops.move([tree.path("x/x")], into: tree.root, resolutions: [tree.path("x/x"): .replace])

        XCTAssertEqual(outcome.failures, [.replaceContainsSource(tree.path("x"))])
        XCTAssertTrue(tree.exists("x/x/inner.txt"))
        XCTAssertEqual(trash.contents, [])
    }

    func testSkipLeavesTheSourceWhereItIs() throws {
        try tree.file("a.txt"); try tree.file("b.txt"); try tree.file("dest/a.txt")

        let outcome = ops.move(
            [tree.path("a.txt"), tree.path("b.txt")], into: tree.path("dest"), resolutions: [tree.path("a.txt"): .skip]
        )

        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(tree.exists("a.txt"))
        XCTAssertEqual(tree.names("dest"), ["a.txt", "b.txt"])
        XCTAssertEqual(tree.describe(outcome.record), ["moved b.txt -> dest/b.txt"])
    }

    func testAPartiallyFailedMoveRecordsWhatHappened() throws {
        try tree.file("a.txt"); try tree.dir("dest")

        let outcome = ops.move([tree.path("gone.txt"), tree.path("a.txt")], into: tree.path("dest"))

        XCTAssertEqual(outcome.failures, [.sourceMissing(tree.path("gone.txt"))])
        XCTAssertEqual(tree.describe(outcome.record), ["moved a.txt -> dest/a.txt"])
    }

    func testAMovedSymlinkStaysALink() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try tree.symlink("link", to: outside.root); try tree.dir("dest")

        XCTAssertEqual(ops.move([tree.path("link")], into: tree.path("dest")).failures, [])
        XCTAssertEqual(tree.linkDestination("dest/link"), outside.root)
    }

    // MARK: - Copy and duplicate

    func testCopyAFolderRecursively() throws {
        try tree.file("src/a.txt", "A"); try tree.file("src/sub/b.txt", "B"); try tree.dir("dest")

        let outcome = ops.copy([tree.path("src")], into: tree.path("dest"))

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.contents("dest/src/sub/b.txt"), "B")
        XCTAssertEqual(tree.contents("src/a.txt"), "A")
        XCTAssertEqual(outcome.record?.kind, .copy)
        XCTAssertEqual(tree.describe(outcome.record), ["created dest/src"])
    }

    func testCopyKeepsSymlinksAsLinks() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try outside.file("t.txt")
        try tree.symlink("link", to: outside.path("t.txt")); try tree.dir("dest")

        _ = ops.copy([tree.path("link")], into: tree.path("dest"))

        XCTAssertEqual(tree.linkDestination("dest/link"), outside.path("t.txt"))
    }

    func testCopyNeverOverwrites() throws {
        try tree.file("a.txt", "new"); try tree.file("dest/a.txt", "old")

        XCTAssertEqual(ops.copy([tree.path("a.txt")], into: tree.path("dest")).failures, [.nameCollision(tree.path("dest/a.txt"))])
        XCTAssertEqual(tree.contents("dest/a.txt"), "old")
    }

    func testCopyFromOutsideTheRootIsAllowed() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try outside.file("from-finder.txt", "F")

        XCTAssertEqual(ops.copy([outside.path("from-finder.txt")], into: tree.root).failures, [])
        XCTAssertEqual(tree.contents("from-finder.txt"), "F")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path("from-finder.txt")))
    }

    func testCopyIntoTheSameFolderUsesKeepBothNames() throws {
        try tree.file("a.txt", "A")

        let outcome = ops.copy([tree.path("a.txt")], into: tree.root)

        XCTAssertEqual(tree.names(), ["a copy.txt", "a.txt"])
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("a copy.txt")])
    }

    func testAFolderCannotBeCopiedIntoItself() throws {
        try tree.dir("a/b")

        XCTAssertEqual(ops.copy([tree.path("a")], into: tree.path("a/b")).failures, [.intoOwnDescendant(tree.path("a"))])
    }

    func testDuplicateCopiesBesideTheOriginals() throws {
        try tree.file("a.txt"); try tree.file("a copy.txt"); try tree.dir("lib/v1.2")

        let outcome = ops.duplicate([tree.path("a.txt"), tree.path("lib/v1.2")])

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.record?.kind, .duplicate)
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("a copy 2.txt"), tree.path("lib/v1.2 copy")])
        XCTAssertTrue(tree.isDirectory("lib/v1.2 copy"))
    }

    // MARK: - Trash

    func testTrashMovesItemsToTheTrashAndRecordsWhere() throws {
        try tree.file("a.txt"); try tree.file("b/c.txt")

        let outcome = ops.trash([tree.path("a.txt"), tree.path("b")])

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.names(), [])
        XCTAssertEqual(trash.contents, ["a.txt", "b"])
        XCTAssertEqual(outcome.record?.kind, .trash)
        XCTAssertEqual(tree.describe(outcome.record), ["trashed a.txt", "trashed b"])
        guard case let .trashed(_, location, _, _)? = outcome.record?.steps.first else {
            return XCTFail("expected a trashed step")
        }
        XCTAssertEqual(location, (trash.folder as NSString).appendingPathComponent("a.txt"))
    }

    func testTrashRefusesTheRootAndDotGit() throws {
        try tree.dir(".git")

        XCTAssertEqual(ops.trash([tree.root, tree.path(".git")]).failures, [.isRoot, .insideDotGit(tree.path(".git"))])
        XCTAssertTrue(tree.exists(".git"))
    }

    func testAVolumeWithoutATrashDeletesNothing() throws {
        try tree.file("a.txt")
        let ops = try XCTUnwrap(FileOperations(root: tree.root, trasher: NoTrash()))

        let outcome = ops.trash([tree.path("a.txt")])

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures.count, 1)
        guard case .noTrash(let path)? = outcome.failures.first else { return XCTFail("expected noTrash") }
        XCTAssertEqual(path, tree.path("a.txt"))
        XCTAssertTrue(tree.exists("a.txt"))
    }

    func testTheSystemTrashRoundTrip() throws {
        let name = "unpeel-explorer-test-\(UUID().uuidString).txt"
        try tree.file(name, "T")
        let ops = try XCTUnwrap(FileOperations(root: tree.root))

        let outcome = ops.trash([tree.path(name)])

        guard case let .trashed(_, location, _, _)? = outcome.record?.steps.first else {
            return XCTFail("expected a trashed step, got \(outcome.failures)")
        }
        defer { try? FileManager.default.removeItem(atPath: location) }
        XCTAssertFalse(tree.exists(name))
        XCTAssertEqual(try String(contentsOfFile: location, encoding: .utf8), "T")
        XCTAssertTrue(SystemTrasher().holds(location))
        XCTAssertFalse(SystemTrasher().holds(tree.path("a.txt")))
    }

    // MARK: - Failures

    func testFailuresDescribeThemselvesForTheMessageStrip() {
        XCTAssertEqual(
            FileOperationFailure.nameCollision("/p/a.txt").localizedDescription,
            "“a.txt” already exists in this folder."
        )
        XCTAssertEqual(FileOperationFailure.sourceMissing("/p/a.txt").localizedDescription, "“a.txt” no longer exists.")
        XCTAssertEqual(FileOperationFailure.isRoot.localizedDescription, "The project folder itself can’t be changed here.")
    }

    func testFileOperationsNeedAnExistingRoot() {
        XCTAssertNil(FileOperations(root: "/nonexistent-\(UUID().uuidString)"))
    }
}
