import XCTest
@testable import UnpeelExplorer

/// A real move from another volume, with the system copier and the system
/// Trash. Needs a writable folder on a volume other than the temporary
/// folder's, named by `UNPEEL_TEST_OTHER_VOLUME` (for instance a disk image
/// attached with `hdiutil attach -nobrowse`); skipped otherwise.
final class FileOperationsVolumeTests: XCTestCase {
    private var tree: TempTree!
    private var source: String!

    override func setUpWithError() throws {
        guard let volume = ProcessInfo.processInfo.environment["UNPEEL_TEST_OTHER_VOLUME"] else {
            throw XCTSkip("UNPEEL_TEST_OTHER_VOLUME is not set")
        }
        tree = try TempTree()
        source = (volume as NSString).appendingPathComponent("unpeel-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        XCTAssertFalse(SystemCopier().canRename(source, into: tree.root), "the folder must be on another volume")
    }

    override func tearDown() {
        tree?.remove()
        if let source { try? FileManager.default.removeItem(atPath: source) }
    }

    private func write(_ relative: String, bytes: Int) throws -> String {
        let path = (source as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: bytes)))
        return path
    }

    func testAStagedMoveFromAnotherVolumeReportsEveryByteAndTrashesTheOriginalThere() throws {
        let folder = (source as NSString).appendingPathComponent("photos")
        _ = try write("photos/big.raw", bytes: 64 * 1024 * 1024)
        _ = try write("photos/sub/small.jpg", bytes: 1000)
        let folderTrash = try FolderTrash(); defer { folderTrash.remove() }
        let ops = try XCTUnwrap(FileOperations(root: tree.root, trasher: VolumeTrash(volume: source, local: folderTrash)))
        let plan = ops.plan([folder], into: tree.root, kind: .move)
        XCTAssertEqual(plan.copySize, TransferSize(items: 4, bytes: 64 * 1024 * 1024 + 1000))
        let progress = TransferProgress()

        guard case .staged(let staged) = ops.stage(plan, resolutions: [:], progress: progress) else {
            return XCTFail("not staged")
        }
        XCTAssertEqual(progress.done, plan.copySize)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder), "the original stays until commit")

        let outcome = ops.commit(staged)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
        XCTAssertEqual(TransferSize.of(tree.path("photos")), plan.copySize)
        let undo = ops.reverse(try XCTUnwrap(outcome.record))
        XCTAssertEqual(undo.failures, [])
        XCTAssertEqual(TransferSize.of(folder), plan.copySize, "put back from that volume's Trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path("photos")))
        XCTAssertEqual(folderTrash.contents, ["photos"])
    }

    func testCancellingACopyFromAnotherVolumeMidFileLeavesNothing() throws {
        let big = try write("big.raw", bytes: 256 * 1024 * 1024)
        let ops = try XCTUnwrap(FileOperations(root: tree.root))
        let plan = ops.plan([big], into: tree.root, kind: .copy)
        let progress = TransferProgress()
        let done = expectation(description: "staged")
        nonisolated(unsafe) var result: StageResult?

        DispatchQueue.global().async {
            result = ops.stage(plan, resolutions: [:], progress: progress)
            done.fulfill()
        }
        let deadline = Date().addingTimeInterval(10)
        while progress.done.bytes == 0, Date() < deadline { usleep(1000) }
        XCTAssertGreaterThan(progress.done.bytes, 0)
        progress.cancel()
        wait(for: [done], timeout: 30)

        guard case .cancelled? = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertLessThan(progress.done.bytes, plan.copySize.bytes, "cancelled mid-file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tree.root), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: big))
    }
}

/// The system Trash for items on the other volume (its own `.Trashes`), a
/// folder Trash for the rest, so the user's own Trash is never filled.
private struct VolumeTrash: Trasher {
    let volume: String
    let local: FolderTrash

    func trash(_ path: String) throws -> String {
        try isOnVolume(path) ? SystemTrasher().trash(path) : local.trash(path)
    }

    func holds(_ location: String) -> Bool {
        isOnVolume(location) ? SystemTrasher().holds(location) : local.holds(location)
    }

    private func isOnVolume(_ path: String) -> Bool {
        let components = (volume as NSString).pathComponents.prefix(3)
        return path.hasPrefix(NSString.path(withComponents: Array(components)) + "/")
    }
}
