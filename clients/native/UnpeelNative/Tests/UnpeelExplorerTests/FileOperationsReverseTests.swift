import XCTest
@testable import UnpeelExplorer

/// `FileOperations.reverse` against real trees: every record kind undoes to
/// exactly the tree before it and redoes to exactly the tree after it, and
/// an undo whose items an "agent" changed since stops for those items.
final class FileOperationsReverseTests: XCTestCase {
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

    /// Every path below the root with a file's contents or "/" for a folder
    /// or "-> target" for a link.
    private func snapshot() -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(atPath: tree.root)
        while let relative = enumerator?.nextObject() as? String {
            let path = tree.path(relative)
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                result[relative] = "-> \(link)"
            } else if tree.isDirectory(relative) {
                result[relative] = "/"
            } else {
                result[relative] = tree.contents(relative) ?? "?"
            }
        }
        return result
    }

    /// Runs `operation`, then undo, redo and undo again, asserting the tree
    /// at every stage. Returns the last undo's outcome.
    @discardableResult
    private func assertRoundTrip(
        _ operation: () -> FileOperationOutcome, file: StaticString = #filePath, line: UInt = #line
    ) throws -> FileOperationOutcome {
        let before = snapshot()
        let done = operation()
        XCTAssertEqual(done.failures, [], file: file, line: line)
        let after = snapshot()
        XCTAssertNotEqual(before, after, "the operation changed nothing", file: file, line: line)
        let record = try XCTUnwrap(done.record, file: file, line: line)

        let undone = ops.reverse(record)
        XCTAssertEqual(undone.failures, [], file: file, line: line)
        XCTAssertEqual(snapshot(), before, "undo", file: file, line: line)
        XCTAssertEqual(undone.record?.kind, record.kind, file: file, line: line)

        let redone = ops.reverse(try XCTUnwrap(undone.record, file: file, line: line))
        XCTAssertEqual(redone.failures, [], file: file, line: line)
        XCTAssertEqual(snapshot(), after, "redo", file: file, line: line)

        let again = ops.reverse(try XCTUnwrap(redone.record, file: file, line: line))
        XCTAssertEqual(snapshot(), before, "second undo", file: file, line: line)
        return again
    }

    // MARK: - Every kind round-trips

    func testNewFileRoundTrips() throws {
        try assertRoundTrip { ops.createFile("notes.txt", in: tree.root) }
    }

    func testNestedNewFileRoundTripsIncludingItsFolders() throws {
        try tree.dir("src")
        try assertRoundTrip { ops.createFile("src/a/b/x.ts", in: tree.root) }
    }

    func testNewFolderRoundTrips() throws {
        try assertRoundTrip { ops.createFolder("build", in: tree.root) }
    }

    func testRenameRoundTrips() throws {
        try tree.file("a.txt", "A")
        let undone = try assertRoundTrip { ops.rename(tree.path("a.txt"), to: "b.txt") }
        XCTAssertEqual(undone.record?.resultPaths, [tree.path("a.txt")])
    }

    func testMoveOfSeveralItemsRoundTripsAsOneStep() throws {
        try tree.file("a.txt", "A"); try tree.file("b/c.txt", "C"); try tree.dir("dest")
        try assertRoundTrip { ops.move([tree.path("a.txt"), tree.path("b")], into: tree.path("dest")) }
    }

    func testReplaceRoundTripsBothItems() throws {
        try tree.file("a.txt", "new"); try tree.file("dest/a.txt", "old")
        try assertRoundTrip {
            ops.move([tree.path("a.txt")], into: tree.path("dest"), resolutions: [tree.path("a.txt"): .replace])
        }
    }

    func testCopyRoundTrips() throws {
        try tree.file("src/a.txt", "A"); try tree.dir("dest")
        try assertRoundTrip { ops.copy([tree.path("src")], into: tree.path("dest")) }
    }

    func testDuplicateRoundTrips() throws {
        try tree.file("a.txt", "A")
        try assertRoundTrip { ops.duplicate([tree.path("a.txt")]) }
    }

    func testTrashRoundTripsAndSelectsTheRestoredItems() throws {
        try tree.file("a.txt", "A"); try tree.file("b/c.txt", "C")
        try assertRoundTrip { ops.trash([tree.path("a.txt"), tree.path("b")]) }

        let trashed = try XCTUnwrap(ops.trash([tree.path("a.txt")]).record)
        XCTAssertEqual(ops.reverse(trashed).record?.resultPaths, [tree.path("a.txt")])
    }

    // MARK: - Agents changed things since

    func testUndoOfAMoveWhoseItemWasReplacedStops() throws {
        try tree.file("a.txt", "A")
        let record = try XCTUnwrap(ops.rename(tree.path("a.txt"), to: "b.txt").record)
        // An agent replaces b.txt with a new file (a new inode).
        try FileManager.default.removeItem(atPath: tree.path("b.txt"))
        try tree.file("b.txt", "agent")

        let outcome = ops.reverse(record)

        XCTAssertNil(outcome.record)
        XCTAssertEqual(outcome.failures, [.changedSince(tree.path("b.txt"))])
        XCTAssertEqual(tree.contents("b.txt"), "agent")
        XCTAssertFalse(tree.exists("a.txt"))
    }

    func testUndoOfAMoveWhoseOldPlaceIsTakenStops() throws {
        try tree.file("a.txt", "A")
        let record = try XCTUnwrap(ops.rename(tree.path("a.txt"), to: "b.txt").record)
        try tree.file("a.txt", "agent")

        let outcome = ops.reverse(record)

        XCTAssertEqual(outcome.failures, [.nameCollision(tree.path("a.txt"))])
        XCTAssertEqual(tree.contents("a.txt"), "agent")
        XCTAssertEqual(tree.contents("b.txt"), "A")
    }

    func testUndoOfAMovedAwayItemStops() throws {
        try tree.file("a.txt")
        let record = try XCTUnwrap(ops.rename(tree.path("a.txt"), to: "b.txt").record)
        try FileManager.default.removeItem(atPath: tree.path("b.txt"))

        XCTAssertEqual(ops.reverse(record).failures, [.sourceMissing(tree.path("b.txt"))])
    }

    func testUndoOfNewFolderKeepsAFolderAnAgentFilled() throws {
        let record = try XCTUnwrap(ops.createFolder("build", in: tree.root).record)
        try tree.file("build/out.o")

        let outcome = ops.reverse(record)

        XCTAssertEqual(outcome.failures, [.changedSince(tree.path("build"))])
        XCTAssertTrue(tree.exists("build/out.o"))
    }

    func testAFinderDotDSStoreDoesNotCountAsContent() throws {
        let record = try XCTUnwrap(ops.createFolder("build", in: tree.root).record)
        try tree.file("build/.DS_Store")

        XCTAssertEqual(ops.reverse(record).failures, [])
        XCTAssertFalse(tree.exists("build"))
    }

    func testUndoOfANestedNewFileTrashesTheFileButKeepsAFolderInUse() throws {
        let record = try XCTUnwrap(ops.createFile("a/b/x.txt", in: tree.root).record)
        try tree.file("a/agent.txt")

        let outcome = ops.reverse(record)

        XCTAssertEqual(outcome.failures, [.changedSince(tree.path("a"))])
        XCTAssertEqual(tree.names("a"), ["agent.txt"])
        XCTAssertEqual(tree.describe(outcome.record), ["trashed a/b/x.txt", "trashed a/b"])
    }

    func testUndoOfANewFileAnAgentRewroteStops() throws {
        let record = try XCTUnwrap(ops.createFile("x.txt", in: tree.root).record)
        // Editors and agents save by writing a new file and renaming it over.
        try "agent".write(toFile: tree.path("x.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ops.reverse(record).failures, [.changedSince(tree.path("x.txt"))])
        XCTAssertEqual(tree.contents("x.txt"), "agent")
    }

    func testUndoOfANewFileAnAgentAppendedToStops() throws {
        let record = try XCTUnwrap(ops.createFile("x.txt", in: tree.root).record)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: tree.path("x.txt")))
        handle.seekToEndOfFile(); handle.write(Data("agent".utf8)); try handle.close()

        XCTAssertEqual(ops.reverse(record).failures, [.changedSince(tree.path("x.txt"))])
        XCTAssertEqual(tree.contents("x.txt"), "agent")
    }

    func testUndoOfACopiedFolderAnAgentAddedToStops() throws {
        try tree.file("src/a.txt"); try tree.dir("dest")
        let record = try XCTUnwrap(ops.copy([tree.path("src")], into: tree.path("dest")).record)
        try tree.file("dest/src/agent.txt")

        XCTAssertEqual(ops.reverse(record).failures, [.changedSince(tree.path("dest/src"))])
        XCTAssertTrue(tree.exists("dest/src/agent.txt"))
    }

    func testUndoNeverFollowsAFolderSwappedForASymlink() throws {
        try tree.file("a/f.txt", "F"); try tree.dir("z/sub")
        let record = try XCTUnwrap(ops.move([tree.path("a/f.txt")], into: tree.path("z")).record)
        try FileManager.default.moveItem(atPath: tree.path("a"), toPath: tree.path("a-old"))
        try tree.symlink("a", to: tree.path("z/sub"))

        XCTAssertEqual(ops.reverse(record).failures, [.changedSince(tree.path("a/f.txt"))])
        XCTAssertEqual(tree.contents("z/f.txt"), "F")
        XCTAssertEqual(tree.names("z/sub"), [])
    }

    func testAForgedTrashRecordCannotPullAFileIntoTheRoot() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try outside.file("secret.txt", "S")
        let forged = FileOperationRecord(
            kind: .trash,
            steps: [.trashed(original: tree.path("stolen.txt"), trashLocation: outside.path("secret.txt"),
                             identity: try XCTUnwrap(ItemIdentity.of(outside.path("secret.txt"))), onlyIfEmpty: false)],
            resultPaths: []
        )

        XCTAssertEqual(ops.reverse(forged).failures, [.notInTrash(tree.path("stolen.txt"))])
        XCTAssertEqual(outside.names(), ["secret.txt"])
        XCTAssertFalse(tree.exists("stolen.txt"))
    }

    func testRedoOfATrashEmptiedSinceStops() throws {
        try tree.file("a.txt")
        let record = try XCTUnwrap(ops.trash([tree.path("a.txt")]).record)
        trash.remove()

        XCTAssertEqual(ops.reverse(record).failures, [.notInTrash(tree.path("a.txt"))])
    }

    func testAPartialUndoKeepsWhatItRestored() throws {
        try tree.file("a.txt", "A"); try tree.file("b.txt", "B")
        let record = try XCTUnwrap(ops.trash([tree.path("a.txt"), tree.path("b.txt")]).record)
        try tree.file("b.txt", "agent")

        let outcome = ops.reverse(record)

        XCTAssertEqual(outcome.failures, [.nameCollision(tree.path("b.txt"))])
        XCTAssertEqual(tree.contents("a.txt"), "A")
        XCTAssertEqual(tree.contents("b.txt"), "agent")
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("a.txt")])
        XCTAssertEqual(tree.describe(outcome.record), ["created a.txt"])
    }

    func testReverseStaysConfinedToTheRoot() throws {
        let outside = try TempTree(); defer { outside.remove() }
        try outside.file("victim.txt", "V")
        let forged = FileOperationRecord(
            kind: .rename,
            steps: [.moved(from: tree.path("x"), to: outside.path("victim.txt"),
                           identity: try XCTUnwrap(ItemIdentity.of(outside.path("victim.txt"))))],
            resultPaths: []
        )

        XCTAssertEqual(ops.reverse(forged).failures, [.outsideRoot(outside.path("victim.txt"))])
        XCTAssertEqual(outside.names(), ["victim.txt"])
    }
}
