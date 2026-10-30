import Foundation

/// Fork-only: nested repositories. Which repository an Explorer Root's git
/// views read, as one resolution saw it.
public struct GitRepositoryRootState: Equatable, Sendable {
    /// What the Explorer Root itself is.
    public enum Folder: Equatable, Sendable {
        case repository
        case notARepository
        /// git is unavailable or failed: nothing is searched or chosen.
        case unknown
    }

    /// The Explorer Root as the context names it.
    public let explorerRoot: String
    /// The Explorer Root's real path, which nested paths are under.
    public let directory: String
    public let folder: Folder
    /// The nested repositories offered, as absolute real paths in path
    /// order; only for a folder that is not a repository.
    public let nested: [String]
    /// The nested repository the views read; nil reads the Explorer Root.
    public let chosen: String?
    /// The lone nested repository, used without the user choosing it.
    public let isAutomatic: Bool

    public init(
        explorerRoot: String, directory: String, folder: Folder,
        nested: [String] = [], chosen: String? = nil, isAutomatic: Bool = false
    ) {
        self.explorerRoot = explorerRoot
        self.directory = directory
        self.folder = folder
        self.nested = nested
        self.chosen = chosen
        self.isAutomatic = isAutomatic
    }

    /// Where the git views read: the chosen nested repository, else the
    /// Explorer Root.
    public var repositoryRoot: String { chosen ?? explorerRoot }

    /// Only a folder that is not a repository offers nested ones.
    public var canChoose: Bool { folder == .notARepository }

    /// `repository`'s path within the Explorer Root.
    public func name(of repository: String) -> String {
        let prefix = directory + "/"
        return repository.hasPrefix(prefix) ? String(repository.dropFirst(prefix.count)) : repository
    }
}

/// Fork-only: nested repositories. What `GitRepositoryRoots` asks of the
/// outside world, injectable so tests control it. `findNested` and
/// `isRepository` read the disk and are called off the main thread.
public struct GitRepositoryRootsServices: Sendable {
    public typealias FindNested = @Sendable (_ folder: String) -> [String]
    public typealias IsRepository = @Sendable (_ folder: String) -> Bool
    public typealias Canonical = @Sendable (_ path: String) -> String

    public let findNested: FindNested
    public let isRepository: IsRepository
    public let canonical: Canonical

    public init(findNested: @escaping FindNested, isRepository: @escaping IsRepository, canonical: @escaping Canonical) {
        self.findNested = findNested
        self.isRepository = isRepository
        self.canonical = canonical
    }

    public static let live = GitRepositoryRootsServices(
        findNested: { GitNestedRepositoryFinder().repositories(in: $0) },
        isRepository: GitNestedRepositoryFinder.isRepository,
        canonical: GitPath.canonical
    )
}

/// Fork-only: nested repositories. Decides, for every Explorer Root the git
/// views follow, which repository they read — the root's own, or for a
/// folder that is not one, the nested repository the user chose in it (a
/// lone one is used without asking) — so the EXPLORER's Git Status
/// Decorations and Git History always agree.
///
/// Shaped like `GitRepositoryHub`: a root is followed while a view
/// subscribes to it, resolved once until something changes, and views
/// asking while a resolution runs share it. A new choice, or the folder
/// itself becoming a repository (`git init`, seen through the hub's watch
/// of the root), resolves again and tells every subscribed view. A root
/// followed afresh is searched afresh, so repositories cloned meanwhile
/// appear.
@MainActor
public final class GitRepositoryRoots {
    public typealias ChangeHandler = @MainActor () -> Void

    private final class Entry {
        var subscribers: [UUID: ChangeHandler] = [:]
        var epoch = 0
        var cached: (epoch: Int, state: GitRepositoryRootState)?
        var inFlight: (epoch: Int, task: Task<GitRepositoryRootState, Never>)?
        /// The hub's watch of the root itself, for its own `.git`.
        var hubSubscription: GitRepositorySubscription?
    }

    private let hub: GitRepositoryHub
    private let choices: GitRepositoryChoiceStore
    private let services: GitRepositoryRootsServices
    private var entries: [String: Entry] = [:]

    public init(hub: GitRepositoryHub, choices: GitRepositoryChoiceStore, services: GitRepositoryRootsServices = .live) {
        self.hub = hub
        self.choices = choices
        self.services = services
    }

    /// Follows `explorerRoot` until the subscription is cancelled;
    /// `onChange` hears every change of what it resolves to.
    public func subscribe(explorerRoot: String, onChange: @escaping ChangeHandler = {}) -> GitRepositorySubscription {
        let id = UUID()
        let entry = entries[explorerRoot] ?? Entry()
        if entry.subscribers.isEmpty {
            entry.hubSubscription = hub.subscribe(root: explorerRoot) { [weak self] in
                self?.folderDidChange(explorerRoot)
            }
        }
        entry.subscribers[id] = onChange
        entries[explorerRoot] = entry
        return GitRepositorySubscription { [weak self] in self?.unsubscribe(explorerRoot, id: id) }
    }

    private func unsubscribe(_ explorerRoot: String, id: UUID) {
        guard let entry = entries[explorerRoot], entry.subscribers.removeValue(forKey: id) != nil,
              entry.subscribers.isEmpty
        else { return }
        entry.hubSubscription?.cancel()
        entries[explorerRoot] = nil
    }

    /// What `explorerRoot`'s git views read: the last resolution if nothing
    /// has changed since it started, the one in flight if one is, otherwise
    /// a new one. An unfollowed root is simply resolved.
    public func resolve(explorerRoot: String) async -> GitRepositoryRootState {
        guard let entry = entries[explorerRoot] else { return await computeState(explorerRoot) }
        let epoch = entry.epoch
        if let cached = entry.cached, cached.epoch == epoch { return cached.state }
        let task: Task<GitRepositoryRootState, Never>
        if let inFlight = entry.inFlight, inFlight.epoch == epoch {
            task = inFlight.task
        } else {
            task = Task { await self.computeState(explorerRoot) }
            entry.inFlight = (epoch, task)
        }
        let state = await task.value
        if entries[explorerRoot] === entry, (entry.cached?.epoch ?? -1) <= epoch {
            if entry.inFlight?.epoch == epoch { entry.inFlight = nil }
            entry.cached = (epoch, state)
        }
        return state
    }

    /// Makes `repository` — a repository inside `explorerRoot`, or nil for
    /// the folder itself — what `explorerRoot`'s git views read, remembers
    /// it, and tells them. Only for a followed root last resolved as a
    /// folder that is not a repository; refused (false) otherwise, or for a
    /// path that is not a repository inside it.
    @discardableResult
    public func choose(_ repository: String?, in explorerRoot: String) -> Bool {
        guard entries[explorerRoot]?.cached?.state.canChoose == true else { return false }
        let directory = services.canonical(explorerRoot)
        let choice: GitRepositoryChoice
        if let repository {
            let path = services.canonical(repository)
            guard path.hasPrefix(directory + "/"), services.isRepository(path) else { return false }
            choice = .repository(String(path.dropFirst(directory.count + 1)))
        } else {
            choice = .folder
        }
        choices.save(choice, forRoot: directory)
        invalidate(explorerRoot)
        return true
    }

    /// Resolves `explorerRoot` again, searching it afresh, and tells every
    /// view following it.
    public func invalidate(_ explorerRoot: String) {
        guard let entry = entries[explorerRoot] else { return }
        entry.epoch += 1
        for handler in Array(entry.subscribers.values) { handler() }
    }

    /// The hub saw the root's repository change. For a folder that is not
    /// a repository that means a `.git` appeared in it; a repository's own
    /// commits and checkouts never change what it resolves to.
    private func folderDidChange(_ explorerRoot: String) {
        guard let entry = entries[explorerRoot], entry.cached?.state.folder != .repository else { return }
        invalidate(explorerRoot)
    }

    // MARK: - Resolving

    private func computeState(_ explorerRoot: String) async -> GitRepositoryRootState {
        let services = services
        let directory = services.canonical(explorerRoot)
        switch await hub.status(root: explorerRoot) {
        case .success:
            return GitRepositoryRootState(explorerRoot: explorerRoot, directory: directory, folder: .repository)
        case .failure(.notARepository):
            break
        case .failure(.gitUnavailable), .failure(.failed):
            return GitRepositoryRootState(explorerRoot: explorerRoot, directory: directory, folder: .unknown)
        }
        let stored = choices.choice(forRoot: directory)
        let storedPath = stored.flatMap { choice -> String? in
            guard case .repository(let relative) = choice else { return nil }
            return (directory as NSString).appendingPathComponent(relative)
        }
        let (found, storedIsRepository) = await Task.detached(priority: .userInitiated) {
            (services.findNested(directory), storedPath.map(services.isRepository) ?? false)
        }.value
        return Self.state(
            explorerRoot: explorerRoot, directory: directory, found: found,
            stored: stored, storedPath: storedIsRepository ? storedPath : nil
        )
    }

    /// A valid stored repository wins (listed even when deeper than the
    /// search goes); a stored `.folder` means none; otherwise a lone
    /// repository is used.
    private static func state(
        explorerRoot: String, directory: String, found: [String],
        stored: GitRepositoryChoice?, storedPath: String?
    ) -> GitRepositoryRootState {
        if let storedPath {
            let nested = found.contains(storedPath)
                ? found
                : (found + [storedPath]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return GitRepositoryRootState(
                explorerRoot: explorerRoot, directory: directory, folder: .notARepository,
                nested: nested, chosen: storedPath
            )
        }
        let automatic = stored == .folder || found.count != 1 ? nil : found.first
        return GitRepositoryRootState(
            explorerRoot: explorerRoot, directory: directory, folder: .notARepository,
            nested: found, chosen: automatic, isAutomatic: automatic != nil
        )
    }
}
