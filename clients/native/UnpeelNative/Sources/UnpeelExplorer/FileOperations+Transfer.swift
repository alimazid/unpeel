import Darwin
import Foundation

/// Move, copy and duplicate: items into a folder, with the Collision
/// Prompt's answers keyed by source path. A move or copy is planned first
/// (`plan`), so a large one can copy before anything else changes
/// (`FileOperations+Staging`), then carried out (`commit`).
extension FileOperations {
    /// Sources whose name already exists in `directory` and that would
    /// therefore need an answer. An item already in that folder is not one:
    /// moving it there does nothing and copying it there keeps both.
    public func collidingSources(_ sources: [String], into directory: String) -> [String] {
        guard let folder = try? writableFolder(directory) else { return [] }
        return sources.filter { source in
            let standardized = (source as NSString).standardizingPath
            guard CanonicalPath.resolve(Self.parent(of: standardized)) != folder else { return false }
            return ItemIdentity.of(Self.join(folder, (standardized as NSString).lastPathComponent)) != nil
        }
    }

    /// Moves items into `directory`: items of the root, or — dropped from
    /// Finder — items from anywhere. An item already there is left alone;
    /// an unanswered collision fails that item.
    public func move(
        _ sources: [String], into directory: String, resolutions: [String: CollisionResolution] = [:]
    ) -> FileOperationOutcome {
        commit(plan(sources, into: directory, kind: .move), resolutions: resolutions)
    }

    /// Copies items — from anywhere readable — into `directory`. A copy
    /// into its own folder takes an incremented name instead of colliding.
    public func copy(
        _ sources: [String], into directory: String, resolutions: [String: CollisionResolution] = [:]
    ) -> FileOperationOutcome {
        commit(plan(sources, into: directory, kind: .copy), resolutions: resolutions)
    }

    /// Copies each item beside itself as `name copy.ext`.
    public func duplicate(_ paths: [String]) -> FileOperationOutcome {
        var failures: [FileOperationFailure] = []
        let items = changeableItems(paths, failures: &failures)
        var steps: [FileOperationStep] = []
        var results: [String] = []
        for item in Self.outermost(items) {
            do {
                let folder = Self.parent(of: item)
                let target = Self.join(folder, freeName(for: item, in: folder))
                steps.append(try copyItem(item, to: target))
                results.append(target)
            } catch {
                failures.append(Self.failure(error, path: item))
            }
        }
        return .make(.duplicate, steps: steps, results: results, failures: failures)
    }

    // MARK: - Commit

    /// Carries out `plan`: puts each item in place, resolving collisions,
    /// using the copies `stage` made for it where there are some. A staged
    /// copy left unused (skipped, failed) is removed.
    public func commit(
        _ plan: TransferPlan, resolutions: [String: CollisionResolution] = [:]
    ) -> FileOperationOutcome {
        guard let folder = plan.folder else { return .make(plan.kind, steps: [], results: [], failures: plan.failures) }
        var failures = plan.failures
        var steps: [FileOperationStep] = []
        var results: [String] = []
        var placedItems: [ItemIdentity] = []
        var outside: Set<String> = []
        for entry in plan.entries {
            let staging = plan.staged[entry.item]
            if plan.kind == .move, isExternal(entry.item) { outside.insert(entry.item) }
            do {
                let placed = try place(
                    entry, into: folder, kind: plan.kind, resolution: resolutions[entry.key],
                    placedEarlier: placedItems, staging: staging
                )
                steps += placed.steps
                if let target = placed.target {
                    results.append(target)
                    if let identity = ItemIdentity.of(target) { placedItems.append(identity) }
                }
            } catch let partial as PartialTransfer {
                steps += partial.steps
                if let target = partial.target { results.append(target) }
                failures.append(partial.failure)
            } catch {
                failures.append(Self.failure(error, path: entry.item))
            }
            if let staging, ItemIdentity.of(staging.path) != nil { Self.remove(staging.path) }
        }
        let touched = Set(steps.flatMap(Self.paths(of:)))
        return .make(plan.kind, steps: steps, results: results, failures: failures,
                     outsidePaths: outside.intersection(touched))
    }

    /// Moves or copies one item into `folder`, resolving a collision. Two
    /// sources of one name (`a/x.txt`, `b/x.txt`) keep both: the second
    /// never replaces what this same operation just put there.
    private func place(
        _ entry: TransferPlan.Entry, into folder: String, kind: FileOperationKind, resolution: CollisionResolution?,
        placedEarlier: [ItemIdentity], staging: TransferPlan.StagedCopy?
    ) throws -> (steps: [FileOperationStep], target: String?) {
        let item = entry.item
        if Self.contains(item, folder) { throw FileOperationFailure.intoOwnDescendant(item) }
        if kind == .move { try confirmUnchanged(entry) }
        var target = Self.join(folder, (item as NSString).lastPathComponent)
        let existing = ItemIdentity.of(target)
        if kind == .copy, Self.parent(of: item) == folder {
            target = Self.join(folder, freeName(for: item, in: folder))
        } else if let existing, placedEarlier.contains(where: { $0.isSameObject(as: existing) }) {
            target = Self.join(folder, freeName(for: item, in: folder))
        } else if existing != nil {
            switch resolution {
            case nil: throw FileOperationFailure.nameCollision(target)
            case .skip?: return ([], nil)
            case .keepBoth?: target = Self.join(folder, freeName(for: item, in: folder))
            case .replace?: return (try replace(target, with: entry, kind: kind, staging: staging), target)
            }
        }
        return (try put(entry, at: target, kind: kind, staging: staging), target)
    }

    /// Trashes `target`, then puts the item there. If putting it there
    /// fails, the trashed item is put back; if even that fails, the trash
    /// step is kept in the record (as a `PartialTransfer`) so ⌘Z can still
    /// restore it — nothing is ever left changed without a record.
    private func replace(
        _ target: String, with entry: TransferPlan.Entry, kind: FileOperationKind, staging: TransferPlan.StagedCopy?
    ) throws -> [FileOperationStep] {
        let item = entry.item
        if item == target || item.hasPrefix(target + "/") {
            throw FileOperationFailure.replaceContainsSource(target)
        }
        let trashed = try trashStep(target, onlyIfEmpty: false)
        do {
            return [trashed] + (try put(entry, at: target, kind: kind, staging: staging))
        } catch let partial as PartialTransfer {
            throw PartialTransfer(steps: [trashed] + partial.steps, failure: partial.failure, target: partial.target)
        } catch {
            let failure = Self.failure(error, path: item)
            if case let .trashed(_, location, _, _) = trashed,
               renamex_np(location, target, UInt32(RENAME_EXCL)) == 0 {
                throw failure
            }
            throw PartialTransfer(steps: [trashed], failure: failure, target: nil)
        }
    }

    /// Puts the item at the free `target`: a rename for a move on one
    /// volume, a copy (the staged one, if any) otherwise.
    private func put(
        _ entry: TransferPlan.Entry, at target: String, kind: FileOperationKind, staging: TransferPlan.StagedCopy?
    ) throws -> [FileOperationStep] {
        let item = entry.item
        guard kind == .move else {
            return [try staging.map { try placeStaged($0.path, at: target) } ?? copyItem(item, to: target)]
        }
        guard entry.copies else {
            let identity = try identity(of: item)
            try renameExclusively(item, to: target)
            return [.moved(from: item, to: target, identity: identity)]
        }
        return try moveAcrossVolumes(item, to: target, staging: staging)
    }

    /// A move acts on the item it planned with: still reached through the
    /// same folders, and still the same object — a Transfer may commit
    /// minutes after it planned.
    private func confirmUnchanged(_ entry: TransferPlan.Entry) throws {
        guard let planned = entry.identity, try movableItem(entry.key) == entry.item,
              ItemIdentity.of(entry.item)?.isSameObject(as: planned) == true
        else { throw FileOperationFailure.changedSince(entry.item) }
    }

    /// The first `IncrementalName` free in `folder`.
    func freeName(for item: String, in folder: String) -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: item, isDirectory: &isDirectory)
        return IncrementalName.available(
            for: (item as NSString).lastPathComponent, isFolder: isDirectory.boolValue,
            isTaken: { ItemIdentity.of(Self.join(folder, $0)) != nil }
        )
    }

    /// A source that may be copied: it exists. Its folder is canonicalised
    /// so the own-descendant check compares like with like.
    func readableItem(_ source: String) throws -> String {
        let standardized = (source as NSString).standardizingPath
        let folder = CanonicalPath.resolve(Self.parent(of: standardized)) ?? Self.parent(of: standardized)
        let item = Self.join(folder, (standardized as NSString).lastPathComponent)
        guard ItemIdentity.of(item) != nil else { throw FileOperationFailure.sourceMissing(source) }
        return item
    }

    // MARK: - Copying

    /// Copies `source` to the free `target`.
    func copyItem(
        _ source: String, to target: String, progress: TransferProgress = TransferProgress()
    ) throws -> FileOperationStep {
        try placeStaged(try stageCopy(source, in: Self.parent(of: target), progress: progress), at: target)
    }

    /// A copy of `source` under a unique hidden name in `folder`. The copy
    /// is renamed into place exclusively afterwards (`placeStaged`): a
    /// recursive copy straight to the target would merge into a folder (or
    /// write through a symlink) an agent put there meanwhile, and a failed
    /// copy must only ever clean up what this call wrote.
    func stageCopy(_ source: String, in folder: String, progress: TransferProgress) throws -> String {
        let staging = Self.join(folder, ".unpeel-copy-\(UUID().uuidString)")
        do {
            try copier.copy(source, to: staging, progress: progress)
            return staging
        } catch {
            Self.remove(staging)
            if error is CancellationError { throw error }
            if ItemIdentity.of(source) == nil { throw FileOperationFailure.sourceMissing(source) }
            throw Self.failure(error, path: source)
        }
    }

    func placeStaged(_ staging: String, at target: String) throws -> FileOperationStep {
        do {
            try renameExclusively(staging, to: target)
        } catch {
            Self.remove(staging)
            throw error
        }
        return .created(path: target, identity: try identity(of: target), onlyIfEmpty: false)
    }

    /// Removes a partial or unused copy this operation made.
    static func remove(_ path: String) {
        guard ItemIdentity.of(path) != nil else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            logger.error("could not remove \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// An item that changed something but did not finish: a replace that
/// trashed the existing item but could neither place the new one nor put
/// the old one back, or a move to another disk whose original could not go
/// to the Trash. Its steps still belong in the record so they can be
/// undone, and `target` is still the item to show.
struct PartialTransfer: Error {
    let steps: [FileOperationStep]
    let failure: FileOperationFailure
    let target: String?
}
