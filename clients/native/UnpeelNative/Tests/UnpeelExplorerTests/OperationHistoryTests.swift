import XCTest
@testable import UnpeelExplorer

/// The Operation History as a value: what is undone and redone next, and
/// how recording, undoing and redoing move records between the stacks.
final class OperationHistoryTests: XCTestCase {
    private func record(_ kind: FileOperationKind, _ tag: String = "") -> FileOperationRecord {
        FileOperationRecord(kind: kind, steps: [], resultPaths: [tag])
    }

    func testAnEmptyHistoryHasNothingToUndoOrRedo() {
        let history = OperationHistory()
        XCTAssertNil(history.nextUndo)
        XCTAssertNil(history.nextRedo)
    }

    func testRecordingPushesOntoUndoAndClearsRedo() {
        let history = OperationHistory()
            .recording(record(.rename, "a"))
            .undone(replacement: record(.rename, "a-inverse"))
            .recording(record(.trash, "b"))

        XCTAssertEqual(history.nextUndo, record(.trash, "b"))
        XCTAssertNil(history.nextRedo)
    }

    func testUndoMovesTheInverseToRedoAndRedoMovesItBack() {
        let start = OperationHistory().recording(record(.rename, "a"))

        let undone = start.undone(replacement: record(.rename, "a-inverse"))
        XCTAssertNil(undone.nextUndo)
        XCTAssertEqual(undone.nextRedo, record(.rename, "a-inverse"))

        let redone = undone.redone(replacement: record(.rename, "a-again"))
        XCTAssertEqual(redone.nextUndo, record(.rename, "a-again"))
        XCTAssertNil(redone.nextRedo)
    }

    func testAnUndoThatChangedNothingDropsTheRecord() {
        let history = OperationHistory()
            .recording(record(.move, "first"))
            .recording(record(.rename, "second"))
            .undone(replacement: nil)

        XCTAssertEqual(history.nextUndo, record(.move, "first"))
        XCTAssertNil(history.nextRedo)
    }

    func testTheHistoryKeepsTheLatestFifty() {
        let history = (0..<60).reduce(OperationHistory()) { $0.recording(record(.newFile, "\($1)")) }

        XCTAssertEqual(history.undoStack.count, OperationHistory.limit)
        XCTAssertEqual(history.undoStack.first, record(.newFile, "10"))
        XCTAssertEqual(history.nextUndo, record(.newFile, "59"))
    }

    func testReducersLeaveTheInputUnchanged() {
        let start = OperationHistory().recording(record(.rename, "a"))
        let copy = start

        _ = start.recording(record(.trash))
        _ = start.undone(replacement: record(.rename))

        XCTAssertEqual(start, copy)
    }
}
