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

/// One recursive FSEvents stream on the explorer root. `root` must already be
/// canonical (`CanonicalPath.resolve`) so reported paths compare equal to
/// model paths. All stream state is confined to `queue`.
public final class FileSystemWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (FileSystemChange) -> Void

    private let root: String
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.unpeel.explorer.fsevents")
    private var stream: FSEventStreamRef?

    public init(root: String, latency: TimeInterval = 0.15, handler: @escaping Handler) {
        self.root = root
        self.latency = latency
        self.handler = handler
    }

    deinit {
        // No other reference exists here, so tear down without hopping queues.
        teardown()
    }

    public func start() {
        queue.sync { startLocked() }
    }

    /// Must not be called from inside the handler (it runs on `queue`).
    public func stop() {
        queue.sync { teardown() }
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
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
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
                let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                guard !paths.isEmpty else { return }
                watcher.handler(FileSystemChange.from(eventPaths: paths))
            },
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
