import Darwin
import Foundation

/// Fork-only: explorer operations. How File Operations copy an item, and
/// whether a move can be a rename. A seam, so tests can slow a copy down,
/// fail it half-way, or make a move cross volumes.
public protocol ItemCopier: Sendable {
    /// Copies `source` — a file, a folder with everything in it, or a
    /// symlink as the link — to `target`, which must not exist. Reports what
    /// it writes to `progress`, and stops with `CancellationError` once
    /// `progress` is cancelled. A copy that throws may leave a partial
    /// `target`; the caller removes it.
    func copy(_ source: String, to target: String, progress: TransferProgress) throws

    /// Whether `item` can be renamed into `folder`: both on one volume.
    func canRename(_ item: String, into folder: String) -> Bool
}

/// `copyfile(3)`: clones where the volume can, copies otherwise; symlinks
/// stay links; a folder's metadata is set after its contents.
public struct SystemCopier: ItemCopier {
    /// False copies every byte even where the volume could clone: what a
    /// copy to another volume does, so tests can watch it on one.
    let clones: Bool

    public init() {
        clones = true
    }

    init(clones: Bool) {
        self.clones = clones
    }

    public func copy(_ source: String, to target: String, progress: TransferProgress) throws {
        guard let state = copyfile_state_alloc() else { throw FileOperations.posixFailure(source, code: ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(progress: progress)
        let callback: copyfile_callback_t = { what, stage, state, source, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            return Unmanaged<CopyContext>.fromOpaque(context).takeUnretainedValue()
                .handle(what: what, stage: stage, state: state, source: source)
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
        let flags = copyfile_flags_t(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC | (clones ? COPYFILE_CLONE : 0)
        )
        let result = withExtendedLifetime(context) { copyfile(source, target, state, flags) }
        guard result != 0 else { return }
        let code = errno
        if progress.isCancelled { throw CancellationError() }
        throw context.failure ?? FileOperations.posixFailure(source, code: code)
    }

    public func canRename(_ item: String, into folder: String) -> Bool {
        var itemInfo = stat()
        var folderInfo = stat()
        guard lstat(item, &itemInfo) == 0, stat(folder, &folderInfo) == 0 else { return true }
        return itemInfo.st_dev == folderInfo.st_dev
    }
}

/// What `copyfile`'s callback keeps between calls: the bytes already
/// reported for the file being copied, and the first error.
private final class CopyContext {
    let progress: TransferProgress
    var fileBytes: Int64 = 0
    var failure: FileOperationFailure?

    init(progress: TransferProgress) {
        self.progress = progress
    }

    func handle(what: Int32, stage: Int32, state: copyfile_state_t?, source: UnsafePointer<CChar>?) -> Int32 {
        let code = errno
        if progress.isCancelled { return COPYFILE_QUIT }
        let path = source.map { String(cString: $0) } ?? ""
        if stage == COPYFILE_ERR {
            // An attribute the destination cannot hold at all is not worth
            // the copy; anything else stops it rather than leave it
            // incomplete.
            if what == COPYFILE_COPY_XATTR, code == ENOTSUP || code == EOPNOTSUPP { return COPYFILE_CONTINUE }
            if failure == nil { failure = FileOperations.posixFailure(path, code: code) }
            return COPYFILE_QUIT
        }
        switch (what, stage) {
        case (COPYFILE_RECURSE_FILE, COPYFILE_START):
            fileBytes = 0
        case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
            progress.advance(items: 1, bytes: max(0, Self.fileSize(path) - fileBytes))
            fileBytes = 0
        case (COPYFILE_RECURSE_DIR, COPYFILE_START):
            progress.advance(items: 1)
        case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
            var copied: off_t = 0
            if let state, copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                progress.advance(bytes: max(0, Int64(copied) - fileBytes))
                fileBytes = max(fileBytes, Int64(copied))
            }
        default:
            break
        }
        return COPYFILE_CONTINUE
    }

    private static func fileSize(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return 0 }
        return Int64(info.st_size)
    }
}
