import Combine
import XCTest
@testable import UnpeelExplorer

/// Large pastes and drops run as Transfers: copied out of sight with a
/// progress row and Cancel, then put in place as one undo step. Cancelled
/// or failed, nothing is left and nothing recorded. Here anything over one
/// item is large, and a `GatedCopier` holds each copy half-way.
@MainActor
final class ExplorerTransferTests: ExplorerOperationTestCase {
    private var finder: TempTree!
    private let overOneItem = TransferSize(items: 1, bytes: 1_000_000)

    override func setUp() async throws {
        try await super.setUp()
        finder = try TempTree()
        try finder.file("set/a.txt", "A")
        try finder.file("set/b.txt", "B")
    }

    override func tearDown() async throws {
        finder.remove()
        try await super.tearDown()
    }

    func testASmallCopyShowsNoTransfer() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try finder.file("one.txt")
        let viewModel = await opened(tree, largeTransfer: overOneItem)
        var most = 0
        let watching = viewModel.$transfers.sink { most = max(most, $0.count) }
        defer { watching.cancel() }

        await viewModel.copy([finder.path("one.txt")], into: tree.root).value

        XCTAssertEqual(most, 0)
        XCTAssertEqual(tree.names(), ["one.txt"])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Copy")
    }

    func testALargeCopyRunsAsATransferThenIsOneUndoStep() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let copier = GatedCopier()
        let viewModel = await opened(tree, copier: copier, largeTransfer: overOneItem)

        let copying = viewModel.copy([finder.path("set")], into: tree.root, as: .paste)
        await waitUntil { copier.started == 1 }

        let transfer = try XCTUnwrap(viewModel.visibleTransfers.first)
        XCTAssertEqual(transfer.title, "Copying “set”")
        XCTAssertEqual(transfer.total, TransferSize(items: 3, bytes: 2))
        XCTAssertEqual(tree.names().filter { !$0.hasPrefix(".") }, [], "nothing shows until it is all copied")

        copier.release()
        await copying.value

        XCTAssertEqual(viewModel.transfers.count, 0)
        XCTAssertEqual(tree.contents("set/b.txt"), "B")
        XCTAssertEqual(viewModel.selection, [tree.path("set")])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Paste")
        await viewModel.undo().value
        XCTAssertEqual(tree.names(), [])
    }

    func testCancellingATransferLeavesNothingAndRecordsNothing() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("mine.txt"); try finder.file("first.txt", "1")
        let copier = GatedCopier()
        let viewModel = await opened(tree, copier: copier, largeTransfer: overOneItem)
        let copying = viewModel.copy([finder.path("first.txt"), finder.path("set")], into: tree.root)
        copier.release()
        await waitUntil { copier.started == 2 }
        XCTAssertEqual(tree.names().filter { $0.hasPrefix(".unpeel-copy-") }.count, 2, "one copied, one half-way")

        let transfer = try XCTUnwrap(viewModel.visibleTransfers.first)
        transfer.cancel()
        XCTAssertTrue(transfer.isCancelling)
        await copying.value

        XCTAssertEqual(tree.names(), ["mine.txt"])
        XCTAssertNil(viewModel.undoActionTitle)
        XCTAssertNil(viewModel.operationMessage)
        XCTAssertEqual(viewModel.transfers.count, 0)
        XCTAssertEqual(finder.names(), ["first.txt", "set"])
    }

    func testAFailedTransferRemovesItsPartialOutputAndSaysWhy() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let viewModel = await opened(tree, copier: FailingCopier(crossesVolumes: false), largeTransfer: overOneItem)

        await viewModel.copy([finder.path("set")], into: tree.root).value

        XCTAssertEqual(tree.names(), [])
        XCTAssertEqual(viewModel.operationMessage, "Couldn’t change “set”: No space left on device")
        XCTAssertNil(viewModel.undoActionTitle)
        XCTAssertEqual(viewModel.transfers.count, 0)
    }

    func testOtherOperationsDoNotWaitForATransfer() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let copier = GatedCopier()
        let viewModel = await opened(tree, copier: copier, largeTransfer: overOneItem)
        let copying = viewModel.copy([finder.path("set")], into: tree.root)
        await waitUntil { copier.started == 1 }

        await viewModel.createFolder("meanwhile", in: tree.root).value

        XCTAssertTrue(tree.isDirectory("meanwhile"))
        XCTAssertEqual(viewModel.undoActionTitle, "Undo New Folder")
        copier.release()
        await copying.value
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Copy")
    }

    func testTwoTransfersAtOnceEachShowTheirOwnRow() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try finder.file("two/a.txt"); try finder.file("two/b.txt")
        let copier = GatedCopier()
        let viewModel = await opened(tree, copier: copier, largeTransfer: overOneItem)

        let first = viewModel.copy([finder.path("set")], into: tree.root)
        let second = viewModel.copy([finder.path("two")], into: tree.root)
        await waitUntil { copier.started == 2 }

        XCTAssertEqual(viewModel.visibleTransfers.map(\.title), ["Copying “set”", "Copying “two”"])
        copier.release(2)
        await first.value
        await second.value
        XCTAssertEqual(tree.names(), ["set", "two"])
        XCTAssertEqual(viewModel.transfers.count, 0)
    }

    func testALargeMoveAcrossVolumesIsATransferThatTrashesTheOriginalLast() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let copier = GatedCopier(crossesVolumes: true)
        let viewModel = await opened(tree, copier: copier, largeTransfer: overOneItem)

        let moving = viewModel.move([finder.path("set")], into: tree.root)
        await waitUntil { copier.started == 1 }
        XCTAssertEqual(viewModel.visibleTransfers.first?.title, "Moving “set”")
        XCTAssertEqual(finder.names(), ["set"])

        copier.release()
        await moving.value
        XCTAssertEqual(tree.contents("set/a.txt"), "A")
        XCTAssertEqual(finder.names(), [])
        XCTAssertEqual(trash.contents, ["set"])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Move")
    }

    func testARowShowsOnlyOnceATransferHasRunForAMoment() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let copier = GatedCopier()
        let viewModel = await opened(tree, copier: copier, largeTransfer: overOneItem)
        let copying = viewModel.copy([finder.path("set")], into: tree.root)
        await waitUntil { copier.started == 1 }
        let transfer = try XCTUnwrap(viewModel.visibleTransfers.first)
        XCTAssertFalse(transfer.isShown)

        await waitUntil { transfer.isShown }
        XCTAssertTrue(transfer.isShown)
        XCTAssertGreaterThan(transfer.done.items, 0)
        XCTAssertEqual(transfer.detail, "1 of 3 items — 1 byte of 2 bytes")

        copier.release()
        await copying.value
    }

    func testATransferIntoAnotherRootRecordsThereAndShowsNoRowHere() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let other = try TempTree(); defer { other.remove() }
        let copier = GatedCopier()
        let viewModel = await opened(tree, copier: copier, largeTransfer: overOneItem)
        let copying = viewModel.copy([finder.path("set")], into: tree.root)
        await waitUntil { copier.started == 1 }

        await viewModel.setContext(local(other)).value
        XCTAssertEqual(viewModel.visibleTransfers.count, 0)
        XCTAssertEqual(viewModel.transfers.count, 1)
        copier.release()
        await copying.value

        XCTAssertEqual(tree.names(), ["set"])
        XCTAssertNil(viewModel.undoActionTitle, "the other root's history is untouched")
        await viewModel.setContext(local(tree)).value
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Copy")
    }
}
