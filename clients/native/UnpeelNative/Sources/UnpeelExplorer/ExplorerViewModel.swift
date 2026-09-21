import Combine
import Foundation

public enum ExplorerContext: Sendable, Equatable {
    /// No session is selected.
    case none
    /// The selected session runs on another Host; its files are not local.
    case remote
    case local(root: String, projectRoot: String)
}

public struct ExplorerServices: Sendable {
    public typealias Scan = @Sendable (_ directory: String, _ root: String) throws -> DirectoryListing
    public typealias MakeWatcher = @Sendable (
        _ root: String, _ handler: @escaping FileSystemWatcher.Handler
    ) -> FileSystemWatcher?

    public let scan: Scan
    public let makeWatcher: MakeWatcher

    public init(scan: @escaping Scan, makeWatcher: @escaping MakeWatcher) {
        self.scan = scan
        self.makeWatcher = makeWatcher
    }

    public static let live = ExplorerServices(
        scan: { directory, root in try DirectoryScanner().scan(directory: directory, root: root) },
        makeWatcher: { root, handler in FileSystemWatcher(root: root, handler: handler) }
    )
}

@MainActor
public final class ExplorerViewModel: ObservableObject {
    @Published public private(set) var context: ExplorerContext = .none
    @Published public private(set) var model: FileTreeModel?
    @Published public private(set) var rootError: String?
    @Published public var selection: [String] = []
    @Published public private(set) var filter: VisibilityFilter
    /// Bumped when a root's saved view state has been re-applied, so the
    /// outline knows `scrollOffset` is now meaningful.
    @Published public private(set) var restoreToken = 0
    public var scrollOffset: Double = 0

    private let services: ExplorerServices
    private let stateStore: ExplorerStateStore
    private var watcher: FileSystemWatcher?
    /// Bumped on every context change; a load that finishes under an older
    /// generation belongs to a root that is no longer shown.
    private var generation = 0
    private var isRestoring = false

    public init(services: ExplorerServices = .live, stateStore: ExplorerStateStore) {
        self.services = services
        self.stateStore = stateStore
        filter = stateStore.filter
    }

    // MARK: - Context

    @discardableResult
    public func setContext(_ next: ExplorerContext) -> Task<Void, Never> {
        guard next != context else { return Task {} }
        persistState()
        teardown()
        context = next
        let current = generation
        return Task { await self.open(next, generation: current) }
    }

    @discardableResult
    public func retry() -> Task<Void, Never> {
        let current = context
        teardown()
        let next = generation
        return Task { await self.open(current, generation: next) }
    }

    private func teardown() {
        generation += 1
        watcher?.stop()
        watcher = nil
        model = nil
        rootError = nil
        selection = []
        scrollOffset = 0
    }

    private func open(_ context: ExplorerContext, generation current: Int) async {
        guard current == generation, case .local(let requestedRoot, _) = context else { return }
        guard let root = CanonicalPath.resolve(requestedRoot) else {
            rootError = ExplorerError.rootUnavailable(requestedRoot).localizedDescription
            return
        }
        model = FileTreeModel(root: root).settingContents(.loading, for: root)
        startWatcher(root: root)
        await load(root, generation: current)
        await restoreState(root: root, generation: current)
    }

    private func startWatcher(root: String) {
        watcher = services.makeWatcher(root) { [weak self] change in
            Task { @MainActor [weak self] in
                self?.handleChange(change)
            }
        }
        watcher?.start()
    }

    // MARK: - Loading

    private func load(_ directory: String, generation current: Int) async {
        guard let root = model?.root else { return }
        let scan = services.scan
        let result: Result<DirectoryListing, any Error> = await Task.detached(priority: .userInitiated) {
            Result { try scan(directory, root) }
        }.value
        guard current == generation, let model, model.directories[directory] != nil else { return }
        switch result {
        case .success(let listing):
            self.model = model.settingContents(.loaded(listing), for: directory)
        case .failure(let error) where directory == model.root:
            self.model = nil
            rootError = error.localizedDescription
        case .failure(let error):
            self.model = model.settingContents(.failed(error.localizedDescription), for: directory)
        }
    }

    private func reload(_ directories: Set<String>) async {
        let current = generation
        for directory in directories.sorted(by: { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }) {
            await load(directory, generation: current)
        }
    }

    // MARK: - Expansion

    @discardableResult
    public func expand(_ path: String) -> Task<Void, Never> {
        guard let model, model.entry(at: path)?.isExpandable == true else { return Task {} }
        let expanded = model.expanding(path)
        switch expanded.directories[path] {
        case .loaded?, .loading?:
            self.model = expanded
            persistState()
            return Task {}
        case .failed?, nil:
            self.model = expanded.settingContents(.loading, for: path)
            let current = generation
            return Task {
                await self.load(path, generation: current)
                self.persistState()
            }
        }
    }

    public func collapse(_ path: String) {
        guard let model else { return }
        self.model = model.collapsing(path)
        persistState()
    }

    public func collapseAll() {
        guard let model else { return }
        self.model = model.collapsingAll()
        persistState()
    }

    // MARK: - Refresh

    @discardableResult
    public func refresh() -> Task<Void, Never> {
        guard let model else { return Task {} }
        let tracked = Set(model.directories.keys)
        return Task { await self.reload(tracked) }
    }

    @discardableResult
    public func handleChange(_ change: FileSystemChange) -> Task<Void, Never> {
        guard let model else { return Task {} }
        let tracked = Set(model.directories.keys)
        let targets = change.touchedGitignore ? tracked : tracked.intersection(change.directories)
        guard !targets.isEmpty else { return Task {} }
        return Task { await self.reload(targets) }
    }

    // MARK: - Reveal

    @discardableResult
    public func reveal(_ path: String) -> Task<Void, Never> {
        guard let root = model?.root, path.hasPrefix(root + "/") else { return Task {} }
        let components = Array(ExplorerPaths.relative(path, to: root).split(separator: "/").dropLast())
        let ancestors = components.indices.map { index in
            root + "/" + components[...index].joined(separator: "/")
        }
        return Task {
            for ancestor in ancestors { await self.expand(ancestor).value }
            if self.model?.entry(at: path) != nil { self.selection = [path] }
        }
    }

    // MARK: - Filter and persistence

    public func setFilter(_ next: VisibilityFilter) {
        filter = next
        stateStore.filter = next
    }

    public func persistState() {
        guard !isRestoring, let model else { return }
        stateStore.save(
            RootViewState(expanded: model.expanded.sorted(), selection: selection, scrollOffset: scrollOffset),
            forRoot: model.root
        )
    }

    private func restoreState(root: String, generation current: Int) async {
        guard current == generation, let saved = stateStore.state(forRoot: root) else { return }
        isRestoring = true
        defer { isRestoring = false }
        let shallowFirst = saved.expanded.sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
        for path in shallowFirst {
            guard current == generation else { return }
            await expand(path).value
        }
        guard current == generation, let model else { return }
        selection = saved.selection.filter { model.entry(at: $0) != nil }
        scrollOffset = saved.scrollOffset
        restoreToken += 1
    }
}
