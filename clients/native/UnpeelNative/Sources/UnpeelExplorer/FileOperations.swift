import Darwin
import Foundation
import os

/// Every write the EXPLORER makes, confined to one Explorer Root (ADR
/// 0002). Synchronous and free of shared state, so a caller can run it off
/// the main actor. Each call returns what changed as a `FileOperationRecord`
/// — the Operation History's unit — plus a failure per item that did not
/// change; a failure never leaves a half-applied item behind.
///
/// Confinement: a destination folder must resolve inside the root; an item
/// being changed must sit, by name, in a folder that resolves inside the
/// root, so a symlink is acted on as the link, never its target. The root
/// itself and anything under `.git` are refused. Renames and moves use
/// `renamex_np(RENAME_EXCL)` and copies `COPYFILE_EXCL`, so an item an
/// agent created at the destination a moment earlier is never replaced.
public struct FileOperations: Sendable {
    public let root: String
    let trasher: any Trasher
    let copier: any ItemCopier

    static let logger = Logger(subsystem: "com.unpeel.explorer", category: "operations")

    public init?(root: String, trasher: any Trasher = SystemTrasher(), copier: any ItemCopier = SystemCopier()) {
        guard let resolved = CanonicalPath.resolve(root) else { return nil }
        self.root = resolved
        self.trasher = trasher
        self.copier = copier
    }

    // MARK: - Create

    /// An empty file at `relativePath` below `directory`, creating missing
    /// folders on the way (`src/utils/x.ts`).
    public func createFile(_ relativePath: String, in directory: String) -> FileOperationOutcome {
        create(relativePath, in: directory, kind: .newFile)
    }

    public func createFolder(_ relativePath: String, in directory: String) -> FileOperationOutcome {
        create(relativePath, in: directory, kind: .newFolder)
    }

    private func create(_ relativePath: String, in directory: String, kind: FileOperationKind) -> FileOperationOutcome {
        var steps: [FileOperationStep] = []
        do {
            if let issue = FileNameValidation.validate(relativePath, purpose: .create, isTaken: { _ in false }),
               issue.severity == .error {
                throw FileOperationFailure.invalidName(issue.message)
            }
            let segments = FileNameValidation.wellFormed(relativePath).split(separator: "/").map(String.init)
            let folder = try writableFolder(directory)
            let target = segments.reduce(folder, Self.join)
            if ExplorerPaths.isInsideDotGit(target, root: root) { throw FileOperationFailure.insideDotGit(target) }
            var current = folder
            for segment in segments.dropLast() {
                let (next, created) = try ensureFolder(Self.join(current, segment))
                if let created { steps.append(created) }
                current = next
            }
            let final = Self.join(current, segments.last ?? "")
            try makeItem(at: final, isFolder: kind == .newFolder)
            steps.append(.created(path: final, identity: try identity(of: final), onlyIfEmpty: kind == .newFolder))
            return .make(kind, steps: steps, results: [final], failures: [])
        } catch {
            // The folders made on the way are removed again, so a refused
            // name leaves nothing behind.
            for case let .created(path, _, _) in steps.reversed() { rmdir(path) }
            return .failed(Self.failure(error, path: directory))
        }
    }

    /// `path` as an existing folder (it may already exist), or a new one.
    private func ensureFolder(_ path: String) throws -> (String, FileOperationStep?) {
        if mkdir(path, 0o777) == 0 {
            return (path, .created(path: path, identity: try identity(of: path), onlyIfEmpty: true))
        }
        guard errno == EEXIST else { throw Self.posixFailure(path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileOperationFailure.nameCollision(path)
        }
        return (try writableFolder(path), nil)
    }

    private func makeItem(at path: String, isFolder: Bool) throws {
        if isFolder {
            guard mkdir(path, 0o777) == 0 else { throw Self.posixFailure(path) }
            return
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
        guard descriptor >= 0 else { throw Self.posixFailure(path) }
        close(descriptor)
    }

    // MARK: - Rename

    /// Renames within the item's folder. A case-only rename works on a
    /// case-insensitive volume.
    public func rename(_ path: String, to newName: String) -> FileOperationOutcome {
        do {
            let item = try changeableItem(path)
            let currentName = (item as NSString).lastPathComponent
            if let issue = FileNameValidation.validate(
                newName, purpose: .rename(currentName: currentName), isTaken: { _ in false }
            ), issue.severity == .error {
                throw FileOperationFailure.invalidName(issue.message)
            }
            let name = FileNameValidation.wellFormed(newName)
            guard name != currentName else { return .nothing }
            let target = Self.join(Self.parent(of: item), name)
            if ExplorerPaths.isInsideDotGit(target, root: root) { throw FileOperationFailure.insideDotGit(target) }
            let identity = try identity(of: item)
            try renameExclusively(item, to: target)
            return .make(.rename, steps: [.moved(from: item, to: target, identity: identity)],
                         results: [target], failures: [])
        } catch {
            return .failed(Self.failure(error, path: path))
        }
    }

    // MARK: - Trash

    /// Each item to the Trash. An item inside another one being trashed is
    /// left to go with it.
    public func trash(_ paths: [String]) -> FileOperationOutcome {
        var failures: [FileOperationFailure] = []
        let items = changeableItems(paths, failures: &failures)
        var steps: [FileOperationStep] = []
        for item in Self.outermost(items) {
            do {
                steps.append(try trashStep(item, onlyIfEmpty: false))
            } catch {
                failures.append(Self.failure(error, path: item))
            }
        }
        return .make(.trash, steps: steps, results: [], failures: failures)
    }

    func trashStep(_ item: String, onlyIfEmpty: Bool) throws -> FileOperationStep {
        let identity = try identity(of: item)
        let location: String
        do {
            location = try trasher.trash(item)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            throw FileOperationFailure.noTrash(item)
        } catch {
            throw FileOperationFailure.underlying(path: item, message: error.localizedDescription)
        }
        return .trashed(
            original: item, trashLocation: location,
            identity: ItemIdentity.of(location) ?? identity, onlyIfEmpty: onlyIfEmpty
        )
    }

    // MARK: - Confinement

    /// The canonical form of a folder that may be written into: the root or
    /// a folder below it, never inside `.git`.
    func writableFolder(_ directory: String) throws -> String {
        guard let resolved = CanonicalPath.resolve(directory), isInsideRoot(resolved) else {
            throw FileOperationFailure.outsideRoot(directory)
        }
        if ExplorerPaths.isInsideDotGit(resolved, root: root) { throw FileOperationFailure.insideDotGit(resolved) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileOperationFailure.sourceMissing(directory)
        }
        return resolved
    }

    /// An existing item that may be renamed, moved or trashed, as the
    /// canonical form of its folder plus its own name — never resolved
    /// itself, so a symlink stays the link.
    func changeableItem(_ path: String) throws -> String {
        let standardized = (path as NSString).standardizingPath
        let name = (standardized as NSString).lastPathComponent
        guard let folder = CanonicalPath.resolve(Self.parent(of: standardized)) else {
            throw FileOperationFailure.sourceMissing(path)
        }
        let item = Self.join(folder, name)
        if item == root { throw FileOperationFailure.isRoot }
        guard isInsideRoot(folder), name != ".", name != "..", !name.isEmpty else {
            throw FileOperationFailure.outsideRoot(path)
        }
        if ExplorerPaths.isInsideDotGit(item, root: root) { throw FileOperationFailure.insideDotGit(item) }
        guard ItemIdentity.of(item) != nil else { throw FileOperationFailure.sourceMissing(item) }
        return item
    }

    func changeableItems(_ paths: [String], failures: inout [FileOperationFailure]) -> [String] {
        paths.compactMap { path in
            do {
                return try changeableItem(path)
            } catch {
                failures.append(Self.failure(error, path: path))
                return nil
            }
        }
    }

    func isInsideRoot(_ resolved: String) -> Bool {
        resolved == root || resolved.hasPrefix(root == "/" ? "/" : root + "/")
    }

    // MARK: - Primitives

    /// `rename(2)` that fails rather than replace an existing destination.
    func renameExclusively(_ source: String, to target: String) throws {
        guard renamex_np(source, target, UInt32(RENAME_EXCL)) != 0 else { return }
        let code = errno
        if code == EEXIST, Self.isCaseOnlyRename(source, target) {
            try renameThroughStaging(source, to: target)
            return
        }
        if code == EEXIST { throw FileOperationFailure.nameCollision(target) }
        if ItemIdentity.of(source) == nil { throw FileOperationFailure.sourceMissing(source) }
        if code == EXDEV {
            throw FileOperationFailure.underlying(path: source, message: "it can’t be moved to another disk from here.")
        }
        throw Self.posixFailure(source, code: code)
    }

    /// APFS renames `a` to `A` with `RENAME_EXCL`; a file system that finds
    /// the item itself at the new spelling gets two exclusive renames
    /// through a unique name instead, so no other item can be replaced.
    private func renameThroughStaging(_ source: String, to target: String) throws {
        let staging = Self.join(Self.parent(of: source), ".unpeel-rename-\(UUID().uuidString)")
        guard renamex_np(source, staging, UInt32(RENAME_EXCL)) == 0 else { throw Self.posixFailure(source) }
        guard renamex_np(staging, target, UInt32(RENAME_EXCL)) == 0 else {
            let failure = Self.posixFailure(target)
            renamex_np(staging, source, UInt32(RENAME_EXCL))
            throw failure
        }
    }

    static func isCaseOnlyRename(_ source: String, _ target: String) -> Bool {
        let from = (source as NSString).lastPathComponent
        let to = (target as NSString).lastPathComponent
        return parent(of: source) == parent(of: target) && from != to
            && from.compare(to, options: .caseInsensitive) == .orderedSame
    }

    func identity(of path: String) throws -> ItemIdentity {
        guard let identity = ItemIdentity.of(path) else { throw FileOperationFailure.sourceMissing(path) }
        return identity
    }

    static func join(_ folder: String, _ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Whether `path` is `folder` or inside it.
    static func contains(_ folder: String, _ path: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// The paths not inside another one of `paths`, in their original order.
    static func outermost(_ paths: [String]) -> [String] {
        paths.filter { path in
            !paths.contains { other in other != path && path.hasPrefix(other == "/" ? "/" : other + "/") }
        }
    }

    static func posixFailure(_ path: String, code: Int32 = errno) -> FileOperationFailure {
        if code == EEXIST { return .nameCollision(path) }
        if code == ENOENT { return .sourceMissing(path) }
        return .underlying(path: path, message: String(cString: strerror(code)))
    }

    static func failure(_ error: any Error, path: String) -> FileOperationFailure {
        (error as? FileOperationFailure) ?? .underlying(path: path, message: error.localizedDescription)
    }
}
