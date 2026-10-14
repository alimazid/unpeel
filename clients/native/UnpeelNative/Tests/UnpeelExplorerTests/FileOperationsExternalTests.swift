import XCTest
@testable import UnpeelExplorer

/// Items dropped from Finder: from outside the root, copied by default and
/// moved with ⌘ — on one volume a rename, across volumes a copy that is
/// checked before the original goes to the Trash. Undo puts them back.
final class FileOperationsExternalTests: XCTestCase {
    private var tree: TempTree!
    private var finder: TempTree!
    private var trash: FolderTrash!

    override func setUpWithError() throws {
        tree = try TempTree()
        finder = try TempTree()
        trash = try FolderTrash()
    }

    override func tearDown() {
        tree.remove()
        finder.remove()
        trash.remove()
    }

    private func operations(_ copier: any ItemCopier = SystemCopier(), trasher: (any Trasher)? = nil) throws -> FileOperations {
        try XCTUnwrap(FileOperations(root: tree.root, trasher: trasher ?? trash, copier: copier))
    }

    // MARK: - Copy

    func testACopyFromOutsideLeavesTheSourceAloneAndUndoTrashesTheCopy() throws {
        try finder.file("report.pdf", "R")
        let ops = try operations()

        let outcome = ops.copy([finder.path("report.pdf")], into: tree.root)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.contents("report.pdf"), "R")
        XCTAssertEqual(finder.contents("report.pdf"), "R")
        XCTAssertEqual(outcome.record?.outsidePaths, [])
        _ = ops.reverse(try XCTUnwrap(outcome.record))
        XCTAssertEqual(tree.names(), [])
        XCTAssertEqual(finder.names(), ["report.pdf"])
    }

    // MARK: - Move on one volume

    func testAMoveFromOutsideTakesTheItemAndUndoPutsItBack() throws {
        try finder.file("notes/a.txt", "A")
        let ops = try operations()

        let outcome = ops.move([finder.path("notes")], into: tree.root)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.contents("notes/a.txt"), "A")
        XCTAssertEqual(finder.names(), [])
        XCTAssertEqual(outcome.record?.outsidePaths, [finder.path("notes")])
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("notes")])

        let undo = ops.reverse(try XCTUnwrap(outcome.record))
        XCTAssertEqual(undo.failures, [])
        XCTAssertEqual(finder.contents("notes/a.txt"), "A")
        XCTAssertEqual(tree.names(), [])

        let redo = ops.reverse(try XCTUnwrap(undo.record))
        XCTAssertEqual(redo.failures, [])
        XCTAssertEqual(tree.contents("notes/a.txt"), "A")
        XCTAssertEqual(finder.names(), [])
    }

    func testUndoOfAMoveFromOutsideStopsWhenItsOldPlaceIsTaken() throws {
        try finder.file("a.txt", "A")
        let ops = try operations()
        let record = try XCTUnwrap(ops.move([finder.path("a.txt")], into: tree.root).record)
        try finder.file("a.txt", "new")

        let undo = ops.reverse(record)

        XCTAssertEqual(undo.failures, [.nameCollision(finder.path("a.txt"))])
        XCTAssertEqual(finder.contents("a.txt"), "new")
        XCTAssertEqual(tree.contents("a.txt"), "A")
    }

    func testARecordTouchesNoOutsidePathItDidNotTakeFrom() throws {
        try finder.file("a.txt", "A"); try finder.file("victim.txt", "V")
        let ops = try operations()
        let record = try XCTUnwrap(ops.move([finder.path("a.txt")], into: tree.root).record)
        let forged = FileOperationRecord(
            kind: .move,
            steps: [.moved(from: tree.path("x"), to: finder.path("victim.txt"),
                           identity: try XCTUnwrap(ItemIdentity.of(finder.path("victim.txt"))))],
            resultPaths: [], outsidePaths: record.outsidePaths
        )

        XCTAssertEqual(ops.reverse(forged).failures, [.outsideRoot(finder.path("victim.txt"))])
        XCTAssertEqual(finder.names(), ["victim.txt"])
    }

    func testAMoveFromOutsideIntoGitIsRefused() throws {
        try finder.file("a.txt"); try tree.dir(".git")

        let outcome = try operations().move([finder.path("a.txt")], into: tree.path(".git"))

        XCTAssertEqual(outcome.failures, [.insideDotGit(tree.path(".git"))])
        XCTAssertEqual(finder.names(), ["a.txt"])
    }

    func testAnAncestorOfTheRootIsNotMovedIntoIt() throws {
        let parent = FileOperations.parent(of: tree.root)

        let outcome = try operations().move([parent], into: tree.root)

        XCTAssertEqual(outcome.failures, [.intoOwnDescendant(parent)])
    }

    // MARK: - Move across volumes

    func testAMoveAcrossVolumesCopiesThenTrashesTheOriginal() throws {
        try finder.file("photos/a.jpg", "A"); try finder.file("photos/sub/b.jpg", "BB")
        try FileManager.default.createSymbolicLink(atPath: finder.path("photos/link"), withDestinationPath: "a.jpg")
        let ops = try operations(CrossVolumeCopier())

        let outcome = ops.move([finder.path("photos")], into: tree.root)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.contents("photos/sub/b.jpg"), "BB")
        XCTAssertEqual(tree.linkDestination("photos/link"), "a.jpg")
        XCTAssertEqual(finder.names(), [])
        XCTAssertEqual(trash.contents, ["photos"])
        XCTAssertEqual(outcome.record?.kind, .move)
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("photos")])
        XCTAssertEqual(outcome.record?.outsidePaths, [finder.path("photos")])
        XCTAssertEqual(tree.describe(outcome.record).first, "created photos")
    }

    func testUndoOfAMoveAcrossVolumesRestoresTheOriginalAndTrashesTheCopy() throws {
        try finder.file("photos/a.jpg", "A")
        let ops = try operations(CrossVolumeCopier())
        let record = try XCTUnwrap(ops.move([finder.path("photos")], into: tree.root).record)

        let undo = ops.reverse(record)

        XCTAssertEqual(undo.failures, [])
        XCTAssertEqual(finder.contents("photos/a.jpg"), "A")
        XCTAssertEqual(tree.names(), [])

        let redo = ops.reverse(try XCTUnwrap(undo.record))
        XCTAssertEqual(redo.failures, [])
        XCTAssertEqual(tree.contents("photos/a.jpg"), "A")
        XCTAssertEqual(finder.names(), [])
    }

    func testUndoOfAMoveAcrossVolumesKeepsTheCopyWhenTheOriginalIsGoneFromTheTrash() throws {
        try finder.file("photos/a.jpg", "A")
        let ops = try operations(CrossVolumeCopier())
        let record = try XCTUnwrap(ops.move([finder.path("photos")], into: tree.root).record)
        try FileManager.default.removeItem(atPath: (trash.folder as NSString).appendingPathComponent("photos"))

        let undo = ops.reverse(record)

        XCTAssertEqual(undo.failures, [.notInTrash(finder.path("photos"))])
        XCTAssertNil(undo.record)
        XCTAssertEqual(tree.contents("photos/a.jpg"), "A", "the only copy left stays in the tree")
    }

    func testRedoOfAMoveAcrossVolumesKeepsTheOriginalWhenTheCopyIsGoneFromTheTrash() throws {
        try finder.file("photos/a.jpg", "A")
        let ops = try operations(CrossVolumeCopier())
        let record = try XCTUnwrap(ops.move([finder.path("photos")], into: tree.root).record)
        let undo = try XCTUnwrap(ops.reverse(record).record)
        try FileManager.default.removeItem(atPath: (trash.folder as NSString).appendingPathComponent("photos"))

        let redo = ops.reverse(undo)

        XCTAssertEqual(redo.failures, [.notInTrash(tree.path("photos"))])
        XCTAssertEqual(finder.contents("photos/a.jpg"), "A", "the original stays where it is")
    }

    func testAFailedCopyAcrossVolumesLeavesTheOriginalAndNoPartialOutput() throws {
        try finder.file("big/a.bin", "A"); try finder.file("big/b.bin", "B")
        let ops = try operations(FailingCopier())

        let outcome = ops.move([finder.path("big")], into: tree.root)

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.underlying(path: finder.path("big"), message: "No space left on device")])
        XCTAssertEqual(finder.contents("big/a.bin"), "A")
        XCTAssertEqual(finder.contents("big/b.bin"), "B")
        XCTAssertEqual(tree.names(), [], "no partial copy, staged or placed")
        XCTAssertEqual(trash.contents, [])
    }

    func testACopyThatDoesNotMatchTheOriginalIsRemovedAndTheOriginalKept() throws {
        try finder.file("docs/a.md", "A"); try finder.file("docs/keep.md", "K")
        let ops = try operations(LossyCopier(dropping: "keep.md"))

        let outcome = ops.move([finder.path("docs")], into: tree.root)

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.copyIncomplete(finder.path("docs"))])
        XCTAssertEqual(finder.contents("docs/keep.md"), "K")
        XCTAssertEqual(tree.names(), [])
    }

    func testAnOriginalThatCannotGoToTheTrashStaysAndTheCopyIsKept() throws {
        try finder.file("a.txt", "A")
        let ops = try operations(CrossVolumeCopier(), trasher: NoTrash())

        let outcome = ops.move([finder.path("a.txt")], into: tree.root)

        XCTAssertEqual(outcome.failures, [.originalKept(finder.path("a.txt"))])
        XCTAssertEqual(tree.contents("a.txt"), "A")
        XCTAssertEqual(finder.contents("a.txt"), "A")
        XCTAssertEqual(tree.describe(outcome.record), ["created a.txt"])
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("a.txt")])
        XCTAssertEqual(outcome.record?.outsidePaths, [], "nothing outside was changed")
    }

    func testReplaceDuringAMoveAcrossVolumesTrashesTheExistingItemFirst() throws {
        try finder.file("a.txt", "new"); try tree.file("a.txt", "old")
        let ops = try operations(CrossVolumeCopier())

        let outcome = ops.move([finder.path("a.txt")], into: tree.root, resolutions: [finder.path("a.txt"): .replace])

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.contents("a.txt"), "new")
        XCTAssertEqual(finder.names(), [])
        _ = ops.reverse(try XCTUnwrap(outcome.record))
        XCTAssertEqual(tree.contents("a.txt"), "old")
        XCTAssertEqual(finder.contents("a.txt"), "new")
    }
}
