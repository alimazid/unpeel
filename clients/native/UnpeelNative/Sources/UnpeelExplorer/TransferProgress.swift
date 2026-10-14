import Darwin
import Foundation
import os

/// Fork-only: explorer operations. How much a copy covers: every item
/// (files, folders, symlinks) and the bytes of its files.
public struct TransferSize: Equatable, Sendable {
    public var items: Int
    public var bytes: Int64

    public init(items: Int = 0, bytes: Int64 = 0) {
        self.items = items
        self.bytes = bytes
    }

    public static let zero = TransferSize()

    /// A paste or drop copying more than this, in either measure, runs as
    /// a Transfer with a progress row and Cancel.
    public static let largeTransfer = TransferSize(items: 200, bytes: 50 * 1024 * 1024)

    public func exceeds(_ limit: TransferSize) -> Bool {
        items > limit.items || bytes > limit.bytes
    }

    public static func + (lhs: TransferSize, rhs: TransferSize) -> TransferSize {
        TransferSize(items: lhs.items + rhs.items, bytes: lhs.bytes + rhs.bytes)
    }

    /// `path` and everything below it, a symlink counted as itself and
    /// never followed. Zero when it does not exist.
    public static func of(_ path: String) -> TransferSize {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .zero }
        let type = info.st_mode & S_IFMT
        var size = TransferSize(items: 1, bytes: type == S_IFREG ? Int64(info.st_size) : 0)
        guard type == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return size
        }
        for name in names {
            size = size + of((path as NSString).appendingPathComponent(name))
        }
        return size
    }
}

/// Fork-only: explorer operations. How far a copy has got, and whether it
/// should stop: written by the thread copying, read and cancelled from the
/// main actor.
public final class TransferProgress: Sendable {
    private struct State {
        var done = TransferSize.zero
        var isCancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var done: TransferSize {
        state.withLock { $0.done }
    }

    public var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    public func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    func advance(items: Int = 0, bytes: Int64 = 0) {
        state.withLock { $0.done = $0.done + TransferSize(items: items, bytes: bytes) }
    }

    /// At least `size` done: an item copied whole, which a clone does
    /// without reporting anything on the way.
    func reach(_ size: TransferSize) {
        state.withLock {
            $0.done = TransferSize(items: max($0.done.items, size.items), bytes: max($0.done.bytes, size.bytes))
        }
    }
}
