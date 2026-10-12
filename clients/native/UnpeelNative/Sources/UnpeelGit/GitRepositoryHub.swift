import Foundation

/// What `GitRepositoryHub` asks of the outside world, injectable so tests
/// control results, timing and counts. `read` is called off the main
/// thread; a monitor's handler may be called on any thread.
public struct GitRepositoryHubServices: Sendable {
    public typealias Read = @Sendable (_ root: String) -> GitReadResult<GitRepositorySnapshot>
    /// Watches a repository's HEAD, index and refs. Nil when it cannot.
    public typealias MakeMonitor = @Sendable (
        _ location: GitRepositoryLocation, _ handler: @escaping @Sendable () -> Void
    ) -> (any GitChangeMonitoring)?
    /// Watches a folder that is not a repository for a `.git` appearing.
    public typealias MakeFolderMonitor = @Sendable (
        _ folder: String, _ handler: @escaping @Sendable () -> Void
    ) -> (any GitChangeMonitoring)?

    public let read: Read
    public let makeMonitor: MakeMonitor
    public let makeFolderMonitor: MakeFolderMonitor

    /// Without monitors nothing is watched: status is re-read only when a
    /// view reports a change.
    public init(
        read: @escaping Read,
        makeMonitor: @escaping MakeMonitor = { _, _ in nil },
        makeFolderMonitor: @escaping MakeFolderMonitor = { _, _ in nil }
    ) {
        self.read = read
        self.makeMonitor = makeMonitor
        self.makeFolderMonitor = makeFolderMonitor
    }

    public static func reading(
        _ reader: GitReader,
        makeMonitor: @escaping MakeMonitor = { _, _ in nil },
        makeFolderMonitor: @escaping MakeFolderMonitor = { _, _ in nil }
    ) -> GitRepositoryHubServices {
        GitRepositoryHubServices(
            read: { reader.snapshot(at: $0) }, makeMonitor: makeMonitor, makeFolderMonitor: makeFolderMonitor
        )
    }
}

/// The views of one Explorer Root's repository — the EXPLORER's Git Status
/// Decorations and Git History — share its status through here: one read
/// serves every view until the working tree or the repository changes, and
/// views asking while a read runs wait for that read rather than starting
/// their own. A root is followed while at least one view subscribes to it.
///
/// It is also the root's one repository-change signal: while followed, the
/// repository's HEAD, index and refs are watched (a worktree's own, through
/// its git directory), or — for a folder that is not a repository — the
/// folder is watched for a `.git` appearing. A change makes the next read
/// fresh and is passed to every subscribed view.
@MainActor
public final class GitRepositoryHub {
    public typealias ChangeHandler = @MainActor () -> Void

    /// What a root's read says should be watched.
    private enum WatchTarget: Equatable {
        case nothing
        case repository(GitRepositoryLocation)
        case folder
    }

    /// One followed root. A class so a finishing read can tell whether the
    /// root it read for is still the one followed.
    private final class Entry {
        var subscribers: [UUID: ChangeHandler] = [:]
        /// Bumped by every change; a read belongs to the epoch it started in.
        var epoch = 0
        var cached: (epoch: Int, result: GitReadResult<GitRepositorySnapshot>)?
        var inFlight: (epoch: Int, task: Task<GitReadResult<GitRepositorySnapshot>, Never>)?
        var target = WatchTarget.nothing
        var monitor: (any GitChangeMonitoring)?
        /// Identifies `monitor`, so a replaced one's late signal is ignored.
        var monitorToken = UUID()
    }

    private let services: GitRepositoryHubServices
    private var entries: [String: Entry] = [:]

    public nonisolated init(services: GitRepositoryHubServices) {
        self.services = services
    }

    /// Follows `root` until the subscription is cancelled (or released);
    /// `onChange` hears every repository change while it lasts. Watching
    /// starts with the root's first read.
    public func subscribe(root: String, onChange: @escaping ChangeHandler = {}) -> GitRepositorySubscription {
        let id = UUID()
        let entry = entries[root] ?? Entry()
        entry.subscribers[id] = onChange
        entries[root] = entry
        return GitRepositorySubscription { [weak self] in self?.unsubscribe(root: root, id: id) }
    }

    private func unsubscribe(root: String, id: UUID) {
        guard let entry = entries[root], entry.subscribers.removeValue(forKey: id) != nil,
              entry.subscribers.isEmpty
        else { return }
        entry.monitor?.stop()
        entry.monitor = nil
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
        // Only the newest read may steer the watch: one from before a
        // change landing after a newer one (a "not a repository" from before
        // `git init`) would point it back at what no longer holds.
        if entries[root] === entry, (entry.cached?.epoch ?? -1) <= epoch {
            if entry.inFlight?.epoch == epoch { entry.inFlight = nil }
            entry.cached = (epoch, result)
            watch(root, entry, for: result)
        }
        return result
    }

    /// Files in `root`'s working tree changed (the EXPLORER's watcher saw
    /// them): the next status call reads again. Views are not told — each
    /// reacts to its own watcher.
    public func workingTreeDidChange(root: String) {
        entries[root]?.epoch += 1
    }

    /// `root`'s repository changed (a commit, checkout, stage, fetch, a
    /// branch created or deleted, or a `.git` appearing): the next status
    /// call reads again, and every view following the root hears of it.
    public func repositoryDidChange(root: String) {
        guard let entry = entries[root] else { return }
        entry.epoch += 1
        for handler in Array(entry.subscribers.values) { handler() }
    }

    // MARK: - Watching

    /// Points the root's one watch at what its latest read found: the
    /// repository, or the folder awaiting one. A failed read that is not
    /// "not a repository" keeps the current watch; without git there is
    /// nothing to watch.
    private func watch(_ root: String, _ entry: Entry, for result: GitReadResult<GitRepositorySnapshot>) {
        let target: WatchTarget
        switch result {
        case .success(let snapshot): target = .repository(snapshot.location)
        case .failure(.notARepository): target = .folder
        case .failure(.gitUnavailable): target = .nothing
        case .failure(.failed): return
        }
        guard target != entry.target else { return }
        entry.monitor?.stop()
        entry.target = target
        let token = UUID()
        entry.monitorToken = token
        let signal: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.monitorDidSignal(root: root, token: token) }
        }
        switch target {
        case .nothing: entry.monitor = nil
        case .repository(let location): entry.monitor = services.makeMonitor(location, signal)
        case .folder: entry.monitor = services.makeFolderMonitor(root, signal)
        }
    }

    /// Tokens are unique per monitor, so a signal from a replaced monitor,
    /// or from one whose root was released, matches nothing.
    private func monitorDidSignal(root: String, token: UUID) {
        guard entries[root]?.monitorToken == token else { return }
        repositoryDidChange(root: root)
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
