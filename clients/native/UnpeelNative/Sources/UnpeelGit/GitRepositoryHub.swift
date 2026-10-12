import Foundation

/// What `GitRepositoryHub` asks of the outside world, injectable so tests
/// control results, timing and counts. `read` is called off the main
/// thread.
public struct GitRepositoryHubServices: Sendable {
    public typealias Read = @Sendable (_ root: String) -> GitReadResult<GitRepositorySnapshot>

    public let read: Read

    public init(read: @escaping Read) {
        self.read = read
    }

    public static func reading(_ reader: GitReader) -> GitRepositoryHubServices {
        GitRepositoryHubServices(read: { reader.snapshot(at: $0) })
    }
}

/// The views of one Explorer Root's repository — the EXPLORER's Git Status
/// Decorations and Git History — share its status through here: one read
/// serves every view until the working tree or the repository changes, and
/// views asking while a read runs wait for that read rather than starting
/// their own. A root is followed while at least one view subscribes to it.
@MainActor
public final class GitRepositoryHub {
    /// One followed root. A class so a finishing read can tell whether the
    /// root it read for is still the one followed.
    private final class Entry {
        var subscribers: Set<UUID> = []
        /// Bumped by every change; a read belongs to the epoch it started in.
        var epoch = 0
        var cached: (epoch: Int, result: GitReadResult<GitRepositorySnapshot>)?
        var inFlight: (epoch: Int, task: Task<GitReadResult<GitRepositorySnapshot>, Never>)?
    }

    private let services: GitRepositoryHubServices
    private var entries: [String: Entry] = [:]

    public nonisolated init(services: GitRepositoryHubServices) {
        self.services = services
    }

    /// Follows `root` until the subscription is cancelled (or released).
    public func subscribe(root: String) -> GitRepositorySubscription {
        let id = UUID()
        let entry = entries[root] ?? Entry()
        entry.subscribers.insert(id)
        entries[root] = entry
        return GitRepositorySubscription { [weak self] in self?.unsubscribe(root: root, id: id) }
    }

    private func unsubscribe(root: String, id: UUID) {
        guard let entry = entries[root], entry.subscribers.remove(id) != nil, entry.subscribers.isEmpty else { return }
        entries[root] = nil
    }

    /// `root`'s repository and status: the last read if nothing has changed
    /// since it started, the read in flight if one is, otherwise a new one.
    /// An unfollowed root is simply read.
    public func status(root: String) async -> GitReadResult<GitRepositorySnapshot> {
        guard let entry = entries[root] else { return await read(root) }
        let epoch = entry.epoch
        if let cached = entry.cached, cached.epoch == epoch { return cached.result }
        let task: Task<GitReadResult<GitRepositorySnapshot>, Never>
        if let inFlight = entry.inFlight, inFlight.epoch == epoch {
            task = inFlight.task
        } else {
            let read = services.read
            task = Task.detached(priority: .userInitiated) { read(root) }
            entry.inFlight = (epoch, task)
        }
        let result = await task.value
        if entries[root] === entry {
            if entry.inFlight?.epoch == epoch { entry.inFlight = nil }
            if (entry.cached?.epoch ?? -1) <= epoch { entry.cached = (epoch, result) }
        }
        return result
    }

    /// Files in `root`'s working tree changed (the EXPLORER's watcher saw
    /// them): the next status call reads again.
    public func workingTreeDidChange(root: String) {
        entries[root]?.epoch += 1
    }

    private func read(_ root: String) async -> GitReadResult<GitRepositorySnapshot> {
        let read = services.read
        return await Task.detached(priority: .userInitiated) { read(root) }.value
    }
}

/// A view's hold on a root it follows through `GitRepositoryHub`.
/// Cancelling twice is harmless; releasing the last reference cancels.
public final class GitRepositorySubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@MainActor () -> Void)?

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    deinit {
        cancel()
    }

    public func cancel() {
        lock.lock()
        let action = onCancel
        onCancel = nil
        lock.unlock()
        guard let action else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            Task { @MainActor in action() }
        }
    }
}
