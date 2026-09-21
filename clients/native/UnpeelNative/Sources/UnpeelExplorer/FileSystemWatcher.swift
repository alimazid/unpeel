import CoreServices
import Foundation

public struct FileSystemChange: Sendable, Equatable {
    /// Directories whose listing may have changed: each event path's parent,
    /// plus the path itself in case it is a directory.
    public let directories: Set<String>
    public let touchedGitignore: Bool

    public init(directories: Set<String>, touchedGitignore: Bool) {
        self.directories = directories
        self.touchedGitignore = touchedGitignore
    }

    public static func from(eventPaths: [String]) -> FileSystemChange {
        let normalised = eventPaths.map { path in
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let directories = normalised.reduce(into: Set<String>()) { result, path in
            result.insert(path)
            result.insert((path as NSString).deletingLastPathComponent)
        }
        let touched = normalised.contains { ($0 as NSString).lastPathComponent == ".gitignore" }
        return FileSystemChange(directories: directories, touchedGitignore: touched)
    }
}

/// Heap box the FSEvents stream itself owns via the context's retain count
/// (see `startLocked()`). The C callback reads only this box — never the
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
/// while holding `queue`, either because the caller is already running on it
/// (the FSEvents callback, or a handler that calls `stop()`) or via
/// `queue.sync`. `start()` and `stop()` are safe to call from any thread,
/// including from inside the handler itself.
public final class FileSystemWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (FileSystemChange) -> Void

    /// Identifies `queue` on whichever thread is currently running a block
    /// submitted to it, so teardown can avoid a reentrant `queue.sync` (which
    /// libdispatch treats as a fatal deadlock, not a hang) when it is already
    /// executing there — e.g. a handler calling `stop()`, or the last strong
    /// reference to the watcher being dropped from inside the handler.
    private static let queueKey = DispatchSpecificKey<Void>()

    private let root: String
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.unpeel.explorer.fsevents")
    private var stream: FSEventStreamRef?
    /// Our balancing reference to the box retained by `FSEventStreamCreate`'s
    /// context; released exactly once, after the stream is fully torn down.
    private var callbackBox: Unmanaged<CallbackBox>?

    public init(root: String, latency: TimeInterval = 0.15, handler: @escaping Handler) {
        self.root = root
        self.latency = latency
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        // The last strong reference can be dropped from any thread, including
        // `queue` itself (e.g. a handler that was the sole owner). Tearing
        // down here must therefore follow the same any-thread-safe path as
        // `stop()` rather than assuming no other reference/access exists.
        teardownFromAnyThread()
    }

    public func start() {
        queue.sync { startLocked() }
    }

    public func stop() {
        teardownFromAnyThread()
    }

    /// Runs `teardown()` directly if already on `queue` (avoids a reentrant
    /// `queue.sync`, which libdispatch would trap as a deadlock), otherwise
    /// synchronously hands it to `queue`.
    private func teardownFromAnyThread() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            teardown()
        } else {
            queue.sync { teardown() }
        }
    }

    /// Creates and starts the FSEvents stream. Must run on `queue`; split out
    /// of `start()` so the C-callback closure below is not nested inside the
    /// `queue.sync` closure. Nesting it there crashes the Swift 6.2
    /// strict-concurrency SIL pass ("SendNonSendable" region analysis aborts
    /// on `&context` inout to a C function inside a doubly-nested closure);
    /// as a single, non-capturing closure literal directly in a method body
    /// it converts to `FSEventStreamCallback` without issue. A top-level
    /// named function in the same role reproduces the same crash, so the
    /// callback must stay an inline closure literal.
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
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                guard !paths.isEmpty else { return }
                box.handler(FileSystemChange.from(eventPaths: paths))
            },
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            box.release()
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
