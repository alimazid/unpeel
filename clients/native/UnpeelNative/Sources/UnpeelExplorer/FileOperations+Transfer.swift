import Darwin
import Foundation

/// Move, copy and duplicate: items into a folder, with the Collision
/// Prompt's answers keyed by source path.
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

    /// Moves items (inside the root) into `directory`. An item already
    /// there is left alone; an unanswered collision fails that item.
    public func move(
        _ sources: [String], into directory: String, resolutions: [String: CollisionResolution] = [:]
    ) -> FileOperationOutcome {
        transfer(sources, into: directory, kind: .move, resolutions: resolutions) { source, folder in
            let item = try self.changeableItem(source)
            guard Self.parent(of: item) != folder else { return nil }
            return (source, item)
        }
    }

    /// Copies items — from anywhere readable — into `directory`. A copy
    /// into its own folder takes an incremented name instead of colliding.
    public func copy(
        _ sources: [String], into directory: String, resolutions: [String: CollisionResolution] = [:]
    ) -> FileOperationOutcome {
        transfer(sources, into: directory, kind: .copy, resolutions: resolutions) { source, _ in
            (source, try self.readableItem(source))
        }
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

    // MARK: - Shared

    /// `prepare` turns a source into (its resolution key, the canonical item
    /// to act on), nil to skip it silently, or throws to fail it.
    private func transfer(
        _ sources: [String], into directory: String, kind: FileOperationKind,
        resolutions: [String: CollisionResolution],
        prepare: (String, String) throws -> (key: String, item: String)?
    ) -> FileOperationOutcome {
        let folder: String
        do {
            folder = try writableFolder(directory)
        } catch {
            return .failed(Self.failure(error, path: directory))
        }
        var failures: [FileOperationFailure] = []
        var prepared: [(key: String, item: String)] = []
        for source in sources {
            do {
                if let entry = try prepare(source, folder) { prepared.append(entry) }
            } catch {
                failures.append(Self.failure(error, path: source))
            }
        }
        let keep = Set(Self.outermost(prepared.map(\.item)))
        var steps: [FileOperationStep] = []
        var results: [String] = []
        var placedItems: [ItemIdentity] = []
        for (key, item) in prepared where keep.contains(item) {
            do {
                let placed = try place(
                    item, into: folder, kind: kind, resolution: resolutions[key], placedEarlier: placedItems
                )
                steps += placed.steps
                if let target = placed.target {
                    results.append(target)
                    if let identity = ItemIdentity.of(target) { placedItems.append(identity) }
                }
            } catch let partial as PartialTransfer {
                steps += partial.steps
                failures.append(partial.failure)
            } catch {
                failures.append(Self.failure(error, path: item))
            }
        }
        return .make(kind, steps: steps, results: results, failures: failures)
    }

    /// Moves or copies one item into `folder`, resolving a collision. Two
    /// sources of one name (`a/x.txt`, `b/x.txt`) keep both: the second
    /// never replaces what this same operation just put there.
    private func place(
        _ item: String, into folder: String, kind: FileOperationKind, resolution: CollisionResolution?,
        placedEarlier: [ItemIdentity]
    ) throws -> (steps: [FileOperationStep], target: String?) {
        if folder == item || folder.hasPrefix(item + "/") { throw FileOperationFailure.intoOwnDescendant(item) }
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
            case .replace?: return (try replace(target, with: item, kind: kind), target)
            }
        }
        return ([try transferItem(item, to: target, kind: kind)], target)
    }

    /// Trashes `target`, then puts `item` there. If putting it there fails,
    /// the trashed item is put back; if even that fails, the trash step is
    /// kept in the record (as a `PartialTransfer`) so ⌘Z can still restore
    /// it — nothing is ever left changed without a record.
    private func replace(_ target: String, with item: String, kind: FileOperationKind) throws -> [FileOperationStep] {
        if item == target || item.hasPrefix(target + "/") {
            throw FileOperationFailure.replaceContainsSource(target)
        }
        let trashed = try trashStep(target, onlyIfEmpty: false)
        do {
            return [trashed, try transferItem(item, to: target, kind: kind)]
        } catch {
            let failure = Self.failure(error, path: item)
            if case let .trashed(_, location, _, _) = trashed,
               renamex_np(location, target, UInt32(RENAME_EXCL)) == 0 {
                throw failure
            }
            throw PartialTransfer(steps: [trashed], failure: failure)
        }
    }

    private func transferItem(_ item: String, to target: String, kind: FileOperationKind) throws -> FileOperationStep {
        guard kind == .move else { return try copyItem(item, to: target) }
        let identity = try identity(of: item)
        try renameExclusively(item, to: target)
        return .moved(from: item, to: target, identity: identity)
    }

    /// The first `IncrementalName` free in `folder`.
    private func freeName(for item: String, in folder: String) -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: item, isDirectory: &isDirectory)
        return IncrementalName.available(
            for: (item as NSString).lastPathComponent, isFolder: isDirectory.boolValue,
            isTaken: { ItemIdentity.of(Self.join(folder, $0)) != nil }
        )
    }

    /// A source that may be copied: it exists. Its folder is canonicalised
    /// so the own-descendant check compares like with like.
    private func readableItem(_ source: String) throws -> String {
        let standardized = (source as NSString).standardizingPath
        let folder = CanonicalPath.resolve(Self.parent(of: standardized)) ?? Self.parent(of: standardized)
        let item = Self.join(folder, (standardized as NSString).lastPathComponent)
        guard ItemIdentity.of(item) != nil else { throw FileOperationFailure.sourceMissing(source) }
        return item
    }

    /// Clones where the volume can, copies otherwise; symlinks stay links.
    /// The copy is made under a unique hidden name in the destination folder
    /// and then renamed into place exclusively: `copyfile` with
    /// `COPYFILE_RECURSIVE` would merge into a folder (or write through a
    /// symlink) an agent put at `target` meanwhile, and a failed copy must
    /// only ever clean up what this call wrote.
    func copyItem(_ source: String, to target: String) throws -> FileOperationStep {
        let staging = Self.join(Self.parent(of: target), ".unpeel-copy-\(UUID().uuidString)")
        let flags = copyfile_flags_t(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC | COPYFILE_CLONE
        )
        guard copyfile(source, staging, nil, flags) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(atPath: staging)
            throw ItemIdentity.of(source) == nil
                ? FileOperationFailure.sourceMissing(source) : Self.posixFailure(source, code: code)
        }
        do {
            try renameExclusively(staging, to: target)
        } catch {
            try? FileManager.default.removeItem(atPath: staging)
            throw error
        }
        return .created(path: target, identity: try identity(of: target), onlyIfEmpty: false)
    }
}

/// A replace that trashed the existing item but could neither place the
/// new one nor put the old one back: the trash step still belongs in the
/// record so it can be undone.
struct PartialTransfer: Error {
    let steps: [FileOperationStep]
    let failure: FileOperationFailure
}
