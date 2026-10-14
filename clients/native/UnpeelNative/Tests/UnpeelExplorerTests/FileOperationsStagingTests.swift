import XCTest
@testable import UnpeelExplorer

/// A large move or copy in two halves: every copy is staged under a hidden
/// name first — with progress, cancellable — then committed at once.
/// Cancelling or failing while staging leaves nothing at the destination.
final class FileOperationsStagingTests: XCTestCase {
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

    private func operations(_ copier: any ItemCopier = SystemCopier()) throws -> FileOperations {
        try XCTUnwrap(FileOperations(root: tree.root, trasher: trash, copier: copier))
    }

    private func fillFinder() throws {
        try finder.file("set/a.bin", String(repeating: "a", count: 100))
        try finder.file("set/sub/b.bin", String(repeating: "b", count: 50))
        try finder.file("c.txt", "cc")
    }

    // MARK: - Measuring

    func testAPlanMeasuresWhatItCopies() throws {
        try fillFinder()
        let ops = try operations()

        let copy = ops.plan([finder.path("set"), finder.path("c.txt")], into: tree.root, kind: .copy)
        XCTAssertEqual(copy.copySize, TransferSize(items: 5, bytes: 152))
        XCTAssertEqual(copy.itemCount, 2)

        let rename = ops.plan([finder.path("set")], into: tree.root, kind: .move)
        XCTAssertEqual(rename.copySize, .zero, "a move on one volume copies nothing")

        let acrossVolumes = try operations(CrossVolumeCopier()).plan([finder.path("set")], into: tree.root, kind: .move)
        XCTAssertEqual(acrossVolumes.copySize, TransferSize(items: 4, bytes: 150))
    }

    func testTheRealCopierReportsEveryItemAndByte() throws {
        try fillFinder()
        try FileManager.default.createSymbolicLink(atPath: finder.path("set/link"), withDestinationPath: "a.bin")
        let progress = TransferProgress()

        try SystemCopier().copy(finder.path("set"), to: tree.path("set"), progress: progress)

        XCTAssertEqual(progress.done.items, TransferSize.of(finder.path("set")).items)
        XCTAssertEqual(progress.done.bytes, 150)
        XCTAssertEqual(tree.contents("set/sub/b.bin"), String(repeating: "b", count: 50))
        XCTAssertEqual(tree.linkDestination("set/link"), "a.bin")
    }

    func testTheRealCopierStopsWhenCancelled() throws {
        try fillFinder()
        let progress = TransferProgress()
        progress.cancel()

        XCTAssertThrowsError(try SystemCopier().copy(finder.path("set"), to: tree.path("set"), progress: progress)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: - Staging and committing

    func testStagingCopiesOutOfSightAndCommittingPutsThemInPlace() throws {
        try fillFinder()
        let ops = try operations()
        let plan = ops.plan([finder.path("set"), finder.path("c.txt")], into: tree.root, kind: .copy)
        let progress = TransferProgress()

        guard case .staged(let staged) = ops.stage(plan, resolutions: [:], progress: progress) else {
            return XCTFail("not staged")
        }
        XCTAssertEqual(progress.done, plan.copySize)
        XCTAssertTrue(tree.names().allSatisfy { $0.hasPrefix(".unpeel-copy-") }, "\(tree.names())")
        XCTAssertEqual(tree.names().count, 2)

        let outcome = ops.commit(staged)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.names(), ["c.txt", "set"])
        XCTAssertEqual(tree.contents("set/sub/b.bin"), String(repeating: "b", count: 50))
        XCTAssertEqual(outcome.record?.resultPaths, [tree.path("set"), tree.path("c.txt")])
    }

    func testCancellingWhileStagingLeavesNothingAtTheDestination() throws {
        try fillFinder()
        try tree.file("existing.txt")
        let copier = GatedCopier()
        let ops = try operations(copier)
        let plan = ops.plan([finder.path("c.txt"), finder.path("set")], into: tree.root, kind: .copy)
        let progress = TransferProgress()
        let staging = DispatchQueue(label: "staging")
        let done = expectation(description: "staged")
        nonisolated(unsafe) var result: StageResult?

        staging.async {
            result = ops.stage(plan, resolutions: [:], progress: progress)
            done.fulfill()
        }
        copier.release()
        while copier.started < 2 { usleep(5_000) }
        XCTAssertTrue(tree.names().contains { $0.hasPrefix(".unpeel-copy-") }, "partial output is there mid-copy")
        progress.cancel()
        wait(for: [done], timeout: 5)

        guard case .cancelled? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual(tree.names(), ["existing.txt"], "the finished copy and the partial one are both gone")
        XCTAssertEqual(finder.names(), ["c.txt", "set"])
    }

    func testAFailureWhileStagingRemovesEverythingStaged() throws {
        try fillFinder()
        let ops = try operations(FailingCopier(failing: [finder.path("set")]))
        let plan = ops.plan([finder.path("c.txt"), finder.path("set")], into: tree.root, kind: .copy)

        let result = ops.stage(plan, resolutions: [:], progress: TransferProgress())

        guard case .failed(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(failure, .underlying(path: finder.path("set"), message: "No space left on device"))
        XCTAssertEqual(tree.names(), [])
    }

    func testDiscardRemovesWhatWasStaged() throws {
        try fillFinder()
        let ops = try operations()
        let plan = ops.plan([finder.path("set")], into: tree.root, kind: .copy)
        guard case .staged(let staged) = ops.stage(plan, resolutions: [:], progress: TransferProgress()) else {
            return XCTFail("not staged")
        }

        ops.discard(staged)

        XCTAssertEqual(tree.names(), [])
    }

    func testAnItemToSkipIsNotStagedAndACommitThatCannotPlaceACopyRemovesIt() throws {
        try fillFinder()
        try tree.file("c.txt", "mine"); try tree.dir("set")
        let ops = try operations()
        let plan = ops.plan([finder.path("c.txt"), finder.path("set")], into: tree.root, kind: .copy)
        let resolutions = [finder.path("c.txt"): CollisionResolution.skip]

        guard case .staged(let staged) = ops.stage(plan, resolutions: resolutions, progress: TransferProgress()) else {
            return XCTFail("not staged")
        }
        XCTAssertEqual(tree.names().filter { $0.hasPrefix(".unpeel-copy-") }.count, 1, "only set is staged")

        let outcome = ops.commit(staged, resolutions: resolutions)

        XCTAssertEqual(outcome.failures, [.nameCollision(tree.path("set"))], "set was never answered")
        XCTAssertEqual(tree.names(), ["c.txt", "set"])
        XCTAssertEqual(tree.contents("c.txt"), "mine")
    }

    func testAStagedMoveAcrossVolumesTrashesTheOriginalsOnlyAtCommit() throws {
        try fillFinder()
        let ops = try operations(CrossVolumeCopier())
        let plan = ops.plan([finder.path("set")], into: tree.root, kind: .move)
        guard case .staged(let staged) = ops.stage(plan, resolutions: [:], progress: TransferProgress()) else {
            return XCTFail("not staged")
        }
        XCTAssertEqual(finder.names(), ["c.txt", "set"], "the original stays until the copy is placed")

        let outcome = ops.commit(staged)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(tree.names(), ["set"])
        XCTAssertEqual(finder.names(), ["c.txt"])
        XCTAssertEqual(trash.contents, ["set"])
    }

    func testAnOriginalChangedWhileItsCopyWasStagedIsNotMoved() throws {
        try fillFinder()
        let ops = try operations(CrossVolumeCopier())
        let plan = ops.plan([finder.path("set")], into: tree.root, kind: .move)
        guard case .staged(let staged) = ops.stage(plan, resolutions: [:], progress: TransferProgress()) else {
            return XCTFail("not staged")
        }
        try finder.file("set/added-by-agent.txt", "!")

        let outcome = ops.commit(staged)

        XCTAssertEqual(outcome.failures, [.changedSince(finder.path("set"))])
        XCTAssertEqual(tree.names(), [])
        XCTAssertEqual(finder.contents("set/added-by-agent.txt"), "!")
    }

    func testAnOriginalEditedInPlaceWhileItsCopyWasStagedIsNotMoved() throws {
        try fillFinder()
        let ops = try operations(CrossVolumeCopier())
        let plan = ops.plan([finder.path("set")], into: tree.root, kind: .move)
        guard case .staged(let staged) = ops.stage(plan, resolutions: [:], progress: TransferProgress()) else {
            return XCTFail("not staged")
        }
        let edited = finder.path("set/a.bin")
        try String(repeating: "z", count: 100).write(toFile: edited, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: edited)

        let outcome = ops.commit(staged)

        XCTAssertEqual(outcome.failures, [.changedSince(finder.path("set"))], "same size, newer content")
        XCTAssertEqual(tree.names(), [])
        XCTAssertEqual(finder.contents("set/a.bin"), String(repeating: "z", count: 100))
    }

    func testARenameCommittedLaterActsOnlyOnTheItemItPlannedWith() throws {
        try tree.file("a.txt", "planned"); try tree.dir("dest")
        let ops = try operations()
        let plan = ops.plan([tree.path("a.txt")], into: tree.path("dest"), kind: .move)
        try FileManager.default.removeItem(atPath: tree.path("a.txt"))
        try tree.file("a.txt", "an agent's new file")

        let outcome = ops.commit(plan)

        XCTAssertEqual(outcome.failures, [.changedSince(tree.path("a.txt"))])
        XCTAssertEqual(tree.contents("a.txt"), "an agent's new file")
        XCTAssertEqual(tree.names("dest"), [])
    }

    // MARK: - The real copier, byte by byte

    func testTheRealCopierReportsBytesAsItWritesThemAndStopsMidFile() throws {
        let big = finder.path("big.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: big, contents: Data(count: 128 * 1024 * 1024)))
        let progress = TransferProgress()
        let done = expectation(description: "copied")
        nonisolated(unsafe) var thrown: (any Error)?

        DispatchQueue.global().async {
            do { try SystemCopier(clones: false).copy(big, to: self.tree.path("big.bin"), progress: progress) } catch {
                thrown = error
            }
            done.fulfill()
        }
        let deadline = Date().addingTimeInterval(10)
        while progress.done.bytes == 0, Date() < deadline { usleep(500) }
        progress.cancel()
        wait(for: [done], timeout: 30)

        XCTAssertTrue(thrown is CancellationError, "\(String(describing: thrown))")
        XCTAssertGreaterThan(progress.done.bytes, 0)
        XCTAssertLessThan(progress.done.bytes, 128 * 1024 * 1024)
    }

    func testTheRealCopierStopsAtAnUnreadableFileAndNamesIt() throws {
        try fillFinder()
        let locked = finder.path("set/sub/b.bin")
        chmod(locked, 0)
        defer { chmod(locked, 0o644) }

        XCTAssertThrowsError(try SystemCopier(clones: false).copy(finder.path("set"), to: tree.path("set"), progress: TransferProgress())) {
            XCTAssertEqual($0 as? FileOperationFailure, .underlying(path: locked, message: "Permission denied"))
        }
    }
}
