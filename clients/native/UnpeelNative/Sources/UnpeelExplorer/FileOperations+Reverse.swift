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
            let item = try recordedItem(path)
            guard let current = ItemIdentity.of(item), current.isSameObject(as: identity) else {
                throw FileOperationFailure.changedSince(item)
            }
            // A created folder that held only what this operation made is
            // judged by being empty again; anything else must be exactly as
            // the operation left it, so an agent's edit is never trashed.
            if onlyIfEmpty ? !Self.isEmptyFolder(item) : current != identity {
                throw FileOperationFailure.changedSince(item)
            }
            return try trashStep(item, onlyIfEmpty: onlyIfEmpty)
        case let .moved(from, to, identity):
            let item = try recordedItem(to)
            guard ItemIdentity.of(item)?.isSameObject(as: identity) == true else {
                throw FileOperationFailure.changedSince(item)
            }
            let target = try placeFor(from)
            try renameExclusively(item, to: target)
            return .moved(from: item, to: target, identity: identity)
        case let .trashed(original, location, identity, onlyIfEmpty):
            guard trasher.holds(location), !isInsideRoot(location),
                  ItemIdentity.of(location)?.isSameObject(as: identity) == true
            else { throw FileOperationFailure.notInTrash(original) }
            let target = try placeFor(original)
            try renameExclusively(location, to: target)
            return .created(path: target, identity: ItemIdentity.of(target) ?? identity, onlyIfEmpty: onlyIfEmpty)
        }
    }

    /// The recorded item, which must still be reached through the same
    /// folders: a folder an agent swapped for a symlink would otherwise
    /// silently redirect the undo elsewhere in the tree.
    private func recordedItem(_ path: String) throws -> String {
        let item = try changeableItem(path)
        guard item == path else { throw FileOperationFailure.changedSince(path) }
        return item
    }

    /// Where an item goes back to: its folder must still be the same
    /// writable folder in the root, and the name a legal one there.
    private func placeFor(_ path: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        guard FileNameValidation.isValidSegment(name) else { throw FileOperationFailure.outsideRoot(path) }
        let folder = try writableFolder(Self.parent(of: path))
        guard folder == Self.parent(of: path) else { throw FileOperationFailure.changedSince(path) }
        let target = Self.join(folder, name)
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
