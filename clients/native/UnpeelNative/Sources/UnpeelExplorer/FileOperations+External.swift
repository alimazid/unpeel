import Darwin
import Foundation

/// Fork-only: explorer operations. Items from outside the root: a ⌘-drop
/// from Finder moves them in. The destination is confined as always; the
/// source may be anywhere. The only writes outside the root are taking the
/// item from where it was, and an undo putting it back to exactly there.
extension FileOperations {
    /// An item a move may take: one in the root (as `changeableItem`), or —
    /// dropped from Finder — one anywhere else, as the link if it is one.
    func movableItem(_ source: String) throws -> String {
        let standardized = (source as NSString).standardizingPath
        guard let folder = CanonicalPath.resolve(Self.parent(of: standardized)) else {
            throw FileOperationFailure.sourceMissing(source)
        }
        if isInsideRoot(folder) { return try changeableItem(source) }
        return try externalItem(Self.join(folder, (standardized as NSString).lastPathComponent))
    }

    /// An existing item outside the root, by its canonical folder and its
    /// own name.
    func externalItem(_ path: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        guard FileNameValidation.isValidSegment(name), !name.contains("/"), let folder = CanonicalPath.resolve(Self.parent(of: path)) else {
            throw FileOperationFailure.sourceMissing(path)
        }
        let item = Self.join(folder, name)
        guard ItemIdentity.of(item) != nil else { throw FileOperationFailure.sourceMissing(item) }
        return item
    }

    /// A recorded path outside the root: only ever where a move from
    /// Finder took an item from (or, once undone, put it back).
    func isExternal(_ recordedPath: String) -> Bool {
        !isInsideRoot(Self.parent(of: recordedPath))
    }

    /// A move to another volume: the item is copied (or was, by `stage`),
    /// the copy checked against the original — which must not have changed
    /// since the copy began — put in place, and only then the original
    /// moved to the Trash — never deleted, so ⌘Z (or the Trash) brings it
    /// back. If the original cannot go to the Trash, the copy stays and the
    /// failure says both remain.
    func moveAcrossVolumes(
        _ item: String, to target: String, staging: TransferPlan.StagedCopy?
    ) throws -> [FileOperationStep] {
        let before = staging?.original ?? TreeSignature.of(item)
        let copy = try staging?.path ?? stageCopy(item, in: Self.parent(of: target), progress: TransferProgress())
        let original = TreeSignature.of(item)
        guard original == before else {
            Self.remove(copy)
            throw FileOperationFailure.changedSince(item)
        }
        guard TreeSignature.of(copy).shape == original.shape else {
            Self.remove(copy)
            throw FileOperationFailure.copyIncomplete(item)
        }
        let created = try placeStaged(copy, at: target)
        do {
            return [created, try trashStep(item, onlyIfEmpty: false)]
        } catch {
            throw PartialTransfer(steps: [created], failure: .originalKept(item), target: target)
        }
    }
}

/// What a copy must match, and what an original must still be: each item
/// below a path with its kind, a file's size and a link's destination
/// (`shape`, which a copy keeps), and each file's and link's modification
/// time (`times`, which an edit changes). A folder's own time is left out:
/// Finder writes a `.DS_Store` into an open folder, and `.DS_Store` files
/// are left out too.
struct TreeSignature: Equatable, Sendable {
    let shape: [String: String]
    let times: [String: String]

    static func of(_ path: String) -> TreeSignature {
        var shape: [String: String] = [:]
        var times: [String: String] = [:]
        collect(path, relative: "", shape: &shape, times: &times)
        return TreeSignature(shape: shape, times: times)
    }

    private static func collect(
        _ path: String, relative: String, shape: inout [String: String], times: inout [String: String]
    ) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        let time = "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            shape[relative] = "file \(info.st_size)"
            times[relative] = time
        case S_IFLNK:
            shape[relative] = "link " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "")
            times[relative] = time
        case S_IFDIR:
            shape[relative] = "folder"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] where name != ".DS_Store" {
                collect((path as NSString).appendingPathComponent(name), relative: relative + "/" + name,
                        shape: &shape, times: &times)
            }
        default:
            shape[relative] = "other"
        }
    }
}
