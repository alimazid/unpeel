import CoreServices
import Foundation
import os

public struct FileSystemChange: Sendable, Equatable {
    /// Directories whose listing may have changed: each event path's parent,
    /// plus the path itself in case it is a directory.
    public let directories: Set<String>
    public let touchedGitignore: Bool
    /// The kernel coalesced or dropped events, so `directories` no longer
    /// describes everything that changed: every tracked directory is stale.
    public let needsFullRescan: Bool

    /// Flags that mean "what you were told is incomplete": the events below
    /// a path were collapsed into one, or the queue overflowed in user space
    /// or in the kernel, or the watched root itself moved.
    private static let rescanFlags = UInt32(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged
    )

    public init(directories: Set<String>, touchedGitignore: Bool, needsFullRescan: Bool = false) {
        self.directories = directories
        self.touchedGitignore = touchedGitignore
        self.needsFullRescan = needsFullRescan
    }

    public static func from(eventPaths: [String]) -> FileSystemChange {
        from(eventPaths: eventPaths, eventFlags: [])
    }

    public static func from(eventPaths: [String], eventFlags: [UInt32]) -> FileSystemChange {
        let normalised = eventPaths.map { path in
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let directories = normalised.reduce(into: Set<String>()) { result, path in
            result.insert(path)
            result.insert((path as NSString).deletingLastPathComponent)
        }
        let touched = normalised.contains { ($0 as NSString).lastPathComponent == ".gitignore" }
        // One dropped event invalidates the whole delivery, not just its own
        // path, so the flags are OR'ed across the batch.
        let combined = eventFlags.reduce(UInt32(0)) { $0 | $1 }
        return FileSystemChange(
            directories: directories,
            touchedGitignore: touched,
            needsFullRescan: combined & rescanFlags != 0
        )
    }
}

/// Heap box holding the handler, referenced by the FSEvents context's `info`
/// pointer. The context's own `retain`/`release` callbacks are left `nil`;
/// the single +1 that keeps this box alive is instead held by the watcher's
/// `callbackBox` field (set in `startLocked()`), and dropped in `teardown()`
/// — after `FSEventStreamInvalidate` — on `queue`. In the reentrant case
/// where a handler invocation calls `stop()` on its own watcher (running
/// `teardown()` synchronously before the handler returns), that field's
/// retain is released while the callback is still executing; the box stays
/// alive for the rest of the call anyway, because the callback's own
/// `takeUnretainedValue()` local is itself a strong reference for the
/// duration of that call. The C callback reads only this box — never the
/// watcher — so the watcher can be deallocated at any time, from any thread,
/// without the callback touching freed memory.
private final class CallbackBox {
    let handler: FileSystemWatcher.Handler
    init(handler: @escaping FileSystemWatcher.Handler) {
        self.handler = handler
    }
}

/// One recursive FSEvents stream on the explorer root. `root` must already be
/// canonical (`CanonicalPath.resolve`) so reported paths compare equal to
/// model paths. All stream state (`stream`, `callbackBox`) is mutated only
/// while holding `queue`, via `onQueue`: directly when already running on
/// this watcher's own queue (its FSEvents callback, or its own handler
/// calling `start()`/`stop()`), otherwise via `queue.sync`. `start()` and
/// `stop()` are therefore safe to call from any thread, including from
/// inside this watcher's own handler, and from inside a *different*
/// watcher's handler (each watcher's queue is identified by its own
/// `queueKey`, so one watcher's queue is never mistaken for another's) —
/// provided the two watchers do not tear each other down CONCURRENTLY: two
/// handlers each calling `stop()`/releasing the other at the same moment
/// are two serial queues syncing onto each other, which deadlocks.
public final class FileSystemWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (FileSystemChange) -> Void

    /// How long FSEvents gathers changes before delivering them.
    public static let defaultLatency: TimeInterval = 0.15

    private static let logger = Logger(subsystem: "com.unpeel.explorer", category: "watcher")

    private let root: String
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.unpeel.explorer.fsevents")
    /// Per-instance key: identifies *this* watcher's `queue`, not "some
    /// watcher's queue". A `static` key would be set on every watcher's
    /// queue and answer only "am I on any `FileSystemWatcher` queue", which
    /// is the wrong question when one watcher's handler touches a second
    /// watcher — it would make `onOwnQueue` return true on watcher A's queue
    /// even when checked against watcher B, causing B's `stop()`/`deinit` to
    /// mutate B's `stream`/`callbackBox` directly on A's queue instead of
    /// hopping to B's own queue.
    private let queueKey = DispatchSpecificKey<Void>()
    private var stream: FSEventStreamRef?
    /// Our balancing reference to the box retained by `FSEventStreamCreate`'s
    /// context; released exactly once, after the stream is fully torn down.
    private var callbackBox: Unmanaged<CallbackBox>?

    public init(root: String, latency: TimeInterval = FileSystemWatcher.defaultLatency, handler: @escaping Handler) {
        self.root = root
        self.latency = latency
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        // The last strong reference can be dropped from any thread, including
        // `queue` itself (e.g. a handler that was the sole owner, or another
        // watcher's handler dropping this one). Tearing down here must
        // therefore follow the same any-thread-safe path as `stop()` rather
        // than assuming no other reference/access exists.
        onQueue { teardown() }
    }

    /// True only when the calling code is already running on *this*
    /// watcher's own `queue` (e.g. inside its own handler). Internal rather
    /// than private so it can be exercised directly from tests without
    /// widening the public API.
    internal var isOnOwnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) != nil
    }

    /// True when a stream is running after the call — either newly created
    /// or already in place. False only when `FSEventStreamCreate` failed,
    /// which leaves the tree without automatic refresh.
    @discardableResult
    public func start() -> Bool {
        var running = false
        onQueue {
            startLocked()
            running = stream != nil
        }
        return running
    }

    public func stop() {
        onQueue { teardown() }
    }

    /// Runs `body` directly if already on `queue` (avoids a reentrant
    /// `queue.sync`, which libdispatch would trap as a deadlock — the same
    /// hazard applies to `start()` and `stop()` alike, and to a second
    /// watcher's handler calling either on this watcher), otherwise
    /// synchronously hands it to `queue`.
    private func onQueue(_ body: () -> Void) {
        if isOnOwnQueue {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    /// Creates and starts the FSEvents stream. Must run on `queue`; split out
    /// of `start()` so the C-callback closure below is not nested inside the
    /// `queue.sync` closure. Observed with Swift 6.2.4: nesting it there
    /// crashes the compiler in the strict-concurrency SIL pass (the
    /// "SendNonSendable" region analysis aborts on `&context` passed inout
    /// to a C function inside a doubly-nested closure), while as a single,
    /// non-capturing closure literal directly in a method body it converts
    /// to `FSEventStreamCallback` without issue. A top-level named function
    /// in the same role reproduced the same crash, so the callback stays an
    /// inline closure literal.
    private func startLocked() {
        guard stream == nil else { return }
        let box = Unmanaged.passRetained(CallbackBox(handler: handler))
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let info else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                guard !paths.isEmpty else { return }
                // `eventFlags` is `numEvents` long — the callback's own count
                // parameter, never `paths.count`, which is a separately
                // bridged array.
                let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
                box.handler(FileSystemChange.from(eventPaths: paths, eventFlags: flags))
            },
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            box.release()
            Self.logger.error("FSEventStreamCreate returned nil; the tree will not refresh by itself")
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
        callbackBox = box
    }

    /// Stops, invalidates and releases the stream, then releases our
    /// balancing reference to its callback box. Must run on `queue`.
    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox?.release()
        callbackBox = nil
    }
}
