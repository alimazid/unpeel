import Darwin
import Foundation

/// Undo and redo: a record's steps inverted, last first. Undoing a record
/// and redoing it are the same call — the inverse of a record is another
/// record, and reversing that one re-applies the original.
extension FileOperations {
    /// Inverts `record`, re-checking each step first: the item must still
    /// be the one the step left (same file-system object, a created folder
    /// still empty), and its old place must still be free. A step that
    /// fails is reported and skipped; the others still happen, and the
    /// returned record holds exactly those, so redoing it re-applies
    /// exactly what this undid.
    public func reverse(_ record: FileOperationRecord) -> FileOperationOutcome {
        var steps: [FileOperationStep] = []
        var results: [String] = []
        var failures: [FileOperationFailure] = []
        for step in record.steps.reversed() {
            do {
                let inverse = try invert(step)
                steps.append(inverse)
                if let shown = Self.shownPath(after: inverse) { results.append(shown) }
            } catch {
                failures.append(Self.failure(error, path: Self.subject(of: step)))
            }
        }
        return .make(record.kind, steps: steps, results: results.reversed(), failures: failures)
    }

    private func invert(_ step: FileOperationStep) throws -> FileOperationStep {
        switch step {
        case let .created(path, identity, onlyIfEmpty):
            let item = try changeableItem(path)
            guard ItemIdentity.of(item) == identity else { throw FileOperationFailure.changedSince(item) }
            if onlyIfEmpty, !Self.isEmptyFolder(item) { throw FileOperationFailure.changedSince(item) }
            return try trashStep(item, onlyIfEmpty: onlyIfEmpty)
        case let .moved(from, to, identity):
            let item = try changeableItem(to)
            guard ItemIdentity.of(item) == identity else { throw FileOperationFailure.changedSince(item) }
            let target = try placeFor(from)
            try renameExclusively(item, to: target)
            return .moved(from: item, to: target, identity: identity)
        case let .trashed(original, location, identity, onlyIfEmpty):
            guard ItemIdentity.of(location) == identity else { throw FileOperationFailure.notInTrash(original) }
            let target = try placeFor(original)
            try renameExclusively(location, to: target)
            return .created(path: target, identity: identity, onlyIfEmpty: onlyIfEmpty)
        }
    }

    /// Where an item goes back to: its folder must still be a writable
    /// folder in the root, and the name a legal one there.
    private func placeFor(_ path: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        guard FileNameValidation.isValidSegment(name) else { throw FileOperationFailure.outsideRoot(path) }
        let target = Self.join(try writableFolder(Self.parent(of: path)), name)
        if ExplorerPaths.isInsideDotGit(target, root: root) { throw FileOperationFailure.insideDotGit(target) }
        return target
    }

    /// A Finder-written `.DS_Store` does not make a folder "in use".
    static func isEmptyFolder(_ path: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return names.allSatisfy { $0 == ".DS_Store" }
    }

    /// The item to select after an inverse step, nil when it left the tree.
    private static func shownPath(after step: FileOperationStep) -> String? {
        switch step {
        case let .created(path, _, _): return path
        case let .moved(_, to, _): return to
        case .trashed: return nil
        }
    }

    /// The path a failure of `step` is about: the item as it is in the tree.
    private static func subject(of step: FileOperationStep) -> String {
        switch step {
        case let .created(path, _, _): return path
        case let .moved(_, to, _): return to
        case let .trashed(original, _, _, _): return original
        }
    }
}
