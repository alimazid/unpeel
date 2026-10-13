import Darwin
import Foundation

/// Why a File Operation, or one item of it, did not happen. Every case
/// leaves the item it names untouched.
public enum FileOperationFailure: Error, Equatable, Sendable, LocalizedError {
    case outsideRoot(String)
    case insideDotGit(String)
    case isRoot
    case nameCollision(String)
    case sourceMissing(String)
    case intoOwnDescendant(String)
    /// Replace would trash a folder that holds an item being moved there.
    case replaceContainsSource(String)
    case invalidName(String)
    case noTrash(String)
    /// An undo or redo found the item changed since the operation (moved,
    /// replaced, or a created folder no longer empty).
    case changedSince(String)
    /// An undo or redo could not find the item in the Trash any more.
    case notInTrash(String)
    case underlying(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .outsideRoot(let path): return "“\(Self.name(path))” is outside the project folder."
        case .insideDotGit: return "Items inside .git can’t be changed here."
        case .isRoot: return "The project folder itself can’t be changed here."
        case .nameCollision(let path): return "“\(Self.name(path))” already exists in this folder."
        case .sourceMissing(let path): return "“\(Self.name(path))” no longer exists."
        case .intoOwnDescendant(let path): return "“\(Self.name(path))” can’t be moved or copied into itself."
        case .replaceContainsSource(let path):
            return "“\(Self.name(path))” can’t be replaced because it contains an item being moved."
        case .invalidName(let message): return message
        case .noTrash(let path): return "“\(Self.name(path))” can’t be moved to the Trash on this disk."
        case .changedSince(let path): return "“\(Self.name(path))” changed since, so it was left as it is."
        case .notInTrash(let path): return "“\(Self.name(path))” is no longer in the Trash."
        case let .underlying(path, message): return "Couldn’t change “\(Self.name(path))”: \(message)"
        }
    }

    private static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// Which file-system object a step acted on, and its state then, so an
/// undo can tell the item it left from one an agent replaced or edited
/// since.
public struct ItemIdentity: Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    /// What an in-place edit changes: a file's size, and the modification
    /// time of a file or of a folder (whose entries changed). A move keeps
    /// both on APFS.
    public let size: Int64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int

    /// The item itself, not a symlink's target.
    public static func of(_ path: String) -> ItemIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return ItemIdentity(
            device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }

    /// The same file-system object, whatever happened to its contents.
    public func isSameObject(as other: ItemIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

/// One change a File Operation made, with what its undo needs.
public enum FileOperationStep: Equatable, Sendable {
    /// A new item at `path`. `onlyIfEmpty` folders (New Folder, and the
    /// folders a nested New File created) are only trashed by an undo while
    /// they are still empty.
    case created(path: String, identity: ItemIdentity, onlyIfEmpty: Bool)
    case moved(from: String, to: String, identity: ItemIdentity)
    /// `original` now lives in the Trash at `trashLocation`.
    case trashed(original: String, trashLocation: String, identity: ItemIdentity, onlyIfEmpty: Bool)
}

public enum FileOperationKind: String, Equatable, Sendable {
    case newFile, newFolder, rename, move, copy, duplicate, trash, paste

    /// As it appears in "Undo <title>".
    public var title: String {
        switch self {
        case .newFile: return "New File"
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        case .move: return "Move"
        case .copy: return "Copy"
        case .duplicate: return "Duplicate"
        case .trash: return "Move to Trash"
        case .paste: return "Paste"
        }
    }
}

/// One user action: what changed, in order, and the paths to select
/// afterwards. One record is one step of the Operation History.
public struct FileOperationRecord: Equatable, Sendable {
    public let kind: FileOperationKind
    public let steps: [FileOperationStep]
    public let resultPaths: [String]

    public init(kind: FileOperationKind, steps: [FileOperationStep], resultPaths: [String]) {
        self.kind = kind
        self.steps = steps
        self.resultPaths = resultPaths
    }
}

public struct FileOperationOutcome: Equatable, Sendable {
    /// Nil when nothing changed.
    public let record: FileOperationRecord?
    public let failures: [FileOperationFailure]

    public init(record: FileOperationRecord?, failures: [FileOperationFailure]) {
        self.record = record
        self.failures = failures
    }

    static func make(_ kind: FileOperationKind, steps: [FileOperationStep], results: [String],
                     failures: [FileOperationFailure]) -> FileOperationOutcome {
        FileOperationOutcome(
            record: steps.isEmpty ? nil : FileOperationRecord(kind: kind, steps: steps, resultPaths: results),
            failures: failures
        )
    }

    static func failed(_ failure: FileOperationFailure) -> FileOperationOutcome {
        FileOperationOutcome(record: nil, failures: [failure])
    }

    static let nothing = FileOperationOutcome(record: nil, failures: [])
}

/// The Collision Prompt's answer for one item.
public enum CollisionResolution: Equatable, Sendable {
    /// Move the existing item to the Trash, then put the new one in place.
    case replace
    /// Put the new item in place under an incremented name.
    case keepBoth
    case skip
}

/// Moves an item to the Trash and says where it went.
public protocol Trasher: Sendable {
    func trash(_ path: String) throws -> String
    /// Whether `location` is in this Trash: the only place a redo of Move
    /// to Trash, or an undo, takes an item back from.
    func holds(_ location: String) -> Bool
}

public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ path: String) throws -> String {
        var location: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &location)
        guard let trashed = location?.path else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        return trashed
    }

    /// The Trash of the volume `location` is on (`~/.Trash`, or a volume's
    /// `.Trashes/<uid>`).
    public func holds(_ location: String) -> Bool {
        guard let trash = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: location), create: false
        ) else { return false }
        let folder = CanonicalPath.resolve(trash.path) ?? trash.path
        return location.hasPrefix(folder + "/")
    }
}
