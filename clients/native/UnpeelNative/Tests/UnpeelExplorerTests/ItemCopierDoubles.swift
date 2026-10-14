import Foundation
@testable import UnpeelExplorer

/// The real copier, with moves made to cross volumes: what a ⌘-drop from
/// another disk does, without a second disk.
struct CrossVolumeCopier: ItemCopier {
    func copy(_ source: String, to target: String, progress: TransferProgress) throws {
        try SystemCopier().copy(source, to: target, progress: progress)
    }

    func canRename(_: String, into _: String) -> Bool { false }
}

/// Fails a copy half-way, leaving partial output behind as a real failed
/// copy would: the caller must remove it. `failing` picks the sources that
/// fail; nil fails them all.
struct FailingCopier: ItemCopier {
    var failing: Set<String>?
    var crossesVolumes = true

    func copy(_ source: String, to target: String, progress: TransferProgress) throws {
        guard failing?.contains(source) ?? true else {
            return try SystemCopier().copy(source, to: target, progress: progress)
        }
        try PartialOutput.write(at: target, like: source)
        throw FileOperationFailure.underlying(path: source, message: "No space left on device")
    }

    func canRename(_: String, into _: String) -> Bool { !crossesVolumes }
}

/// Copies everything but the files named `dropping`: a copy that came out
/// incomplete without saying so.
struct LossyCopier: ItemCopier {
    let dropping: String

    func copy(_ source: String, to target: String, progress: TransferProgress) throws {
        try SystemCopier().copy(source, to: target, progress: progress)
        let enumerator = FileManager.default.enumerator(atPath: target)
        while let relative = enumerator?.nextObject() as? String {
            if (relative as NSString).lastPathComponent == dropping {
                try FileManager.default.removeItem(atPath: (target as NSString).appendingPathComponent(relative))
            }
        }
    }

    func canRename(_: String, into _: String) -> Bool { false }
}

/// A slow copy: writes part of the item, then waits at a gate before
/// copying it for real — long enough to cancel half-way, or to see the
/// Transfer while it runs.
final class GatedCopier: ItemCopier, @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private let gate = DispatchSemaphore(value: 0)
    let crossesVolumes: Bool

    init(crossesVolumes: Bool = false) {
        self.crossesVolumes = crossesVolumes
    }

    /// How many copies have written their partial output and are waiting.
    var started: Int {
        lock.withLock { startedCount }
    }

    /// Lets one waiting copy finish.
    func release(_ count: Int = 1) {
        for _ in 0..<count { gate.signal() }
    }

    func copy(_ source: String, to target: String, progress: TransferProgress) throws {
        try PartialOutput.write(at: target, like: source)
        progress.advance(items: 1, bytes: 1)
        lock.withLock { startedCount += 1 }
        while gate.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            if progress.isCancelled { throw CancellationError() }
        }
        try FileManager.default.removeItem(atPath: target)
        try SystemCopier().copy(source, to: target, progress: progress)
    }

    func canRename(_: String, into _: String) -> Bool { !crossesVolumes }
}

enum PartialOutput {
    /// A half-written copy: a folder with one partial file, or a partial
    /// file.
    static func write(at target: String, like source: String) throws {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
            try "parti".write(toFile: (target as NSString).appendingPathComponent("partial"), atomically: false, encoding: .utf8)
        } else {
            try "parti".write(toFile: target, atomically: false, encoding: .utf8)
        }
    }
}
