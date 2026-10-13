import Foundation

/// The undo and redo stacks of one Explorer Root's File Operations. A pure
/// value: the view model keeps one per root and replaces it on every
/// change. Each record is one user action, however many items it touched.
///
/// Not `NSUndoManager`: an operation runs off the main actor and can fail
/// for some of its items, while `NSUndoManager` needs each inverse
/// registered synchronously inside the undo handler that performs it.
public struct OperationHistory: Equatable, Sendable {
    public static let limit = 50

    public let undoStack: [FileOperationRecord]
    public let redoStack: [FileOperationRecord]

    public init(undoStack: [FileOperationRecord] = [], redoStack: [FileOperationRecord] = []) {
        self.undoStack = Array(undoStack.suffix(Self.limit))
        self.redoStack = Array(redoStack.suffix(Self.limit))
    }

    public var nextUndo: FileOperationRecord? { undoStack.last }
    public var nextRedo: FileOperationRecord? { redoStack.last }

    /// A new operation: it becomes the next undo and the redo stack is
    /// cleared, as in every editor.
    public func recording(_ record: FileOperationRecord) -> OperationHistory {
        OperationHistory(undoStack: undoStack + [record], redoStack: [])
    }

    /// The next undo was performed. `replacement` — the inverse it produced,
    /// nil when nothing could be undone — becomes the next redo.
    public func undone(replacement: FileOperationRecord?) -> OperationHistory {
        OperationHistory(
            undoStack: Array(undoStack.dropLast()),
            redoStack: redoStack + (replacement.map { [$0] } ?? [])
        )
    }

    /// The next redo was performed; its inverse becomes the next undo.
    public func redone(replacement: FileOperationRecord?) -> OperationHistory {
        OperationHistory(
            undoStack: undoStack + (replacement.map { [$0] } ?? []),
            redoStack: Array(redoStack.dropLast())
        )
    }
}
