import Foundation

/// Fork-only: explorer operations. A move or copy worked out before
/// anything changes: the destination, each item to act on, and how much has
/// to be copied — which decides whether it runs as a Transfer.
public struct TransferPlan: Sendable {
    struct Entry: Sendable {
        /// The source as asked for: what the Collision Prompt's answers are
        /// keyed by.
        let key: String
        /// The item to act on: its folder canonical, its own name kept.
        let item: String
        /// Whether it has to be copied: every item of a copy, an item a move
        /// takes to another volume.
        let copies: Bool
        let size: TransferSize
        /// The item when planned: a move acts on it only while it is still
        /// the same object, reached the same way.
        let identity: ItemIdentity?
    }

    /// A copy `stage` made, and — for a move — the original as it was when
    /// the copy began, which it must still be when it goes to the Trash.
    struct StagedCopy: Sendable {
        let path: String
        let original: TreeSignature?
    }

    public let kind: FileOperationKind
    /// The canonical destination; nil when it was refused.
    let folder: String?
    let entries: [Entry]
    /// Sources refused before anything changed.
    let failures: [FileOperationFailure]
    /// Copies `stage` made under hidden names in `folder`, by item.
    let staged: [String: StagedCopy]

    /// What has to be copied; a rename copies nothing.
    public var copySize: TransferSize {
        entries.filter(\.copies).reduce(.zero) { $0 + $1.size }
    }

    public var itemCount: Int { entries.count }

    func with(staged: [String: StagedCopy]) -> TransferPlan {
        TransferPlan(kind: kind, folder: folder, entries: entries, failures: failures, staged: staged)
    }
}

/// How `stage` ended.
public enum StageResult: Sendable {
    case staged(TransferPlan)
    /// Cancelled: everything staged was removed.
    case cancelled
    /// A copy failed: everything staged was removed.
    case failed(FileOperationFailure)
}

/// A large move or copy in two halves: `stage` makes every copy first —
/// slow, with progress and Cancel — while nothing the user can see has
/// changed; `commit` then puts the items in place at once. Cancelling or
/// failing while staging leaves nothing behind.
extension FileOperations {
    public func plan(_ sources: [String], into directory: String, kind: FileOperationKind) -> TransferPlan {
        let folder: String
        do {
            folder = try writableFolder(directory)
        } catch {
            return TransferPlan(
                kind: kind, folder: nil, entries: [], failures: [Self.failure(error, path: directory)], staged: [:]
            )
        }
        var failures: [FileOperationFailure] = []
        var prepared: [(key: String, item: String)] = []
        for source in sources {
            do {
                let item = kind == .move ? try movableItem(source) : try readableItem(source)
                // Refused before measuring: an ancestor of the root is huge.
                if Self.contains(item, folder) { throw FileOperationFailure.intoOwnDescendant(item) }
                // Moving an item into the folder it is in does nothing.
                if kind == .move, Self.parent(of: item) == folder { continue }
                prepared.append((source, item))
            } catch {
                failures.append(Self.failure(error, path: source))
            }
        }
        let keep = Set(Self.outermost(prepared.map(\.item)))
        let entries = prepared.filter { keep.contains($0.item) }.map { key, item in
            let copies = kind != .move || !copier.canRename(item, into: folder)
            return TransferPlan.Entry(
                key: key, item: item, copies: copies, size: copies ? .of(item) : .zero, identity: ItemIdentity.of(item)
            )
        }
        return TransferPlan(kind: kind, folder: folder, entries: entries, failures: failures, staged: [:])
    }

    /// Makes every copy `plan` needs under a hidden name in its folder,
    /// reporting to `progress`. An item the Collision Prompt said to skip is
    /// not copied.
    public func stage(
        _ plan: TransferPlan, resolutions: [String: CollisionResolution], progress: TransferProgress
    ) -> StageResult {
        guard let folder = plan.folder else { return .staged(plan) }
        var staged: [String: TransferPlan.StagedCopy] = [:]
        var expected = TransferSize.zero
        for entry in plan.entries where entry.copies && !isSkipped(entry, in: folder, resolutions: resolutions) {
            do {
                if progress.isCancelled { throw CancellationError() }
                let original = plan.kind == .move ? TreeSignature.of(entry.item) : nil
                let copy = try stageCopy(entry.item, in: folder, progress: progress)
                staged[entry.item] = TransferPlan.StagedCopy(path: copy, original: original)
                expected = expected + entry.size
                progress.reach(expected)
            } catch {
                staged.values.forEach { Self.remove($0.path) }
                if error is CancellationError || progress.isCancelled { return .cancelled }
                return .failed(Self.failure(error, path: entry.item))
            }
        }
        if progress.isCancelled {
            staged.values.forEach { Self.remove($0.path) }
            return .cancelled
        }
        return .staged(plan.with(staged: staged))
    }

    /// Removes what `stage` made, for a Transfer cancelled after its copies
    /// were done but before they were put in place.
    public func discard(_ plan: TransferPlan) {
        plan.staged.values.forEach { Self.remove($0.path) }
    }

    private func isSkipped(
        _ entry: TransferPlan.Entry, in folder: String, resolutions: [String: CollisionResolution]
    ) -> Bool {
        guard resolutions[entry.key] == .skip, Self.parent(of: entry.item) != folder else { return false }
        return ItemIdentity.of(Self.join(folder, (entry.item as NSString).lastPathComponent)) != nil
    }
}
