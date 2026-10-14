import Combine
import Foundation
import os
import UnpeelGit

/// Fork-only: git support. The context moved to `UnpeelGit` so Git History
/// follows the same Explorer Root; this keeps the explorer's API unchanged.
public typealias ExplorerContext = UnpeelGit.ExplorerContext

public struct ExplorerServices: Sendable {
    public typealias Scan = @Sendable (_ directory: String, _ root: String) throws -> DirectoryListing
    public typealias MakeWatcher = @Sendable (
        _ root: String, _ handler: @escaping FileSystemWatcher.Handler
    ) -> FileSystemWatcher?

    public typealias MakeOperations = @Sendable (_ root: String) -> FileOperations?

    public let scan: Scan
    public let makeWatcher: MakeWatcher
    /// Fork-only: git support. Where Git Status Decorations come from; nil
    /// shows none.
    public let repositories: GitRepositoryHub?
    /// Fork-only: explorer operations. The File Operations for a root.
    public let makeOperations: MakeOperations

    public init(
        scan: @escaping Scan,
        makeWatcher: @escaping MakeWatcher,
        repositories: GitRepositoryHub? = nil,
        makeOperations: @escaping MakeOperations = { FileOperations(root: $0) }
    ) {
        self.scan = scan
        self.makeWatcher = makeWatcher
        self.repositories = repositories
        self.makeOperations = makeOperations
    }

    @MainActor public static var live: ExplorerServices {
        ExplorerServices(
            scan: { directory, root in try DirectoryScanner().scan(directory: directory, root: root) },
            makeWatcher: { root, handler in FileSystemWatcher(root: root, handler: handler) },
            repositories: .shared
        )
    }
}

@MainActor
public final class ExplorerViewModel: ObservableObject {
    @Published public private(set) var context: ExplorerContext = .none
    @Published public private(set) var model: FileTreeModel?
    @Published public private(set) var rootError: String?
    @Published public var selection: [String] = []
    @Published public private(set) var filter: VisibilityFilter
    /// Bumped when a root's saved view state has been re-applied, so the
    /// outline knows `scrollOffset` is now meaningful. `.remote`, `.none`
    /// and failed opens deliberately do NOT bump it: there is no outline to
    /// scroll in those states, and the next successful open bumps it anyway.
    @Published public private(set) var restoreToken = 0
    public var scrollOffset: Double = 0
    /// Fork-only: explorer operations. Bumped with every selection that
    /// reveals (an operation's result, a reveal from elsewhere), so the
    /// outline scrolls that selection into view; a click never does.
    @Published public internal(set) var revealToken = 0
    /// Fork-only: git support. The current root's Git Status Decorations
    /// (see `ExplorerViewModel+Decorations`).
    @Published public internal(set) var decorations: GitDecorations = .none
    /// Fork-only: explorer operations. The latest File Operation failure,
    /// shown in the EXPLORER's message strip until dismissed, the next
    /// operation succeeds, or the root changes.
    @Published public internal(set) var operationMessage: String?
    /// Fork-only: explorer operations. The New File… / New Folder… waiting
    /// for its name (see `ExplorerViewModel+Draft`).
    @Published public internal(set) var draft: ExplorerDraft?

    static let logger = Logger(subsystem: "com.unpeel.explorer", category: "viewmodel")

    let services: ExplorerServices
    private let stateStore: ExplorerStateStore
    private var watcher: FileSystemWatcher?
    /// Bumped on every context change; a load that finishes under an older
    /// generation belongs to a root that is no longer shown.
    private(set) var generation = 0
    /// The generation currently opening (initial load + saved-state replay),
    /// or `nil` when none is. `persistState()` is suppressed while this
    /// equals `generation` — i.e. while the *current, live* root is mid-open
    /// — regardless of which generation's leftover continuation happens to
    /// be the one calling it. A generation must only clear this for itself
    /// (checked, never unconditionally), so an abandoned open can never
    /// un-suppress persistence for the generation that superseded it.
    private var restoringGeneration: Int?
    /// Per-directory monotonically increasing token. A load's result is
    /// applied only if its token is still the latest issued for that
    /// directory, so an overlapping load that started earlier (e.g. a
    /// pre-change scan) can never overwrite a later one's result, no matter
    /// which one's scan happens to finish last.
    private var loadTokens: [String: Int] = [:]
    /// Directories a reload still has to scan, and the one loop scanning
    /// them. A batch that arrives mid-reload joins this set instead of
    /// starting a chain of its own (see `scheduleReload`).
    private var pendingReloads: Set<String> = []
    private var reloadTask: Task<Void, Never>?
    /// Folders that changed while they were not on screen (collapsed, or
    /// under a collapsed parent). They keep their old contents and are
    /// rescanned when an expansion shows them again.
    private var staleDirectories: Set<String> = []
    /// Fork-only: git support. Decoration state, owned by
    /// `ExplorerViewModel+Decorations`.
    let decorationDebounce: TimeInterval
    var followedRepository: FollowedRepository?
    let decorationRefresh = RefreshCoalescer()
    /// Fork-only: explorer operations. Each Explorer Root's Operation
    /// History, kept for the app's life (see `ExplorerViewModel+Operations`).
    var histories: [String: OperationHistory] = [:]
    /// The File Operation in flight; the next one waits for it, so an undo
    /// always acts on the history as the previous operation left it.
    var operationTail: Task<Void, Never>?

    public init(
        services: ExplorerServices = .live,
        stateStore: ExplorerStateStore,
        decorationDebounce: TimeInterval = RefreshCoalescer.defaultDebounce
    ) {
        self.services = services
        self.stateStore = stateStore
        self.decorationDebounce = max(0, decorationDebounce)
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
        persistState()
        let current = context
        teardown()
        let next = generation
        return Task { await self.open(current, generation: next) }
    }

    private func teardown() {
        generation += 1
        loadTokens.removeAll()
        pendingReloads = []
        reloadTask = nil
        staleDirectories = []
        stopWatcher()
        stopDecorations()
        model = nil
        rootError = nil
        selection = []
        scrollOffset = 0
        operationMessage = nil
        draft = nil
    }

    /// Persistence is suppressed for the WHOLE window from the moment a
    /// root starts opening until its restore finishes. The trade-off:
    /// expansions and selections a user makes while a slow root is still
    /// loading are not written back, but a half-replayed expansion set can
    /// never overwrite the saved state it is in the middle of replaying —
    /// losing a few seconds of interaction is recoverable, silently
    /// truncating a root's remembered tree is not.
    private func open(_ context: ExplorerContext, generation current: Int) async {
        guard current == generation else { return }
        // Set before the first model is published (below), so `persistState`
        // is suppressed for the whole window from here through the end of
        // `restoreState` — not just while replaying saved expansions.
        restoringGeneration = current
        guard case .local(let requestedRoot, _) = context else {
            finishOpening(current)
            return
        }
        guard let root = CanonicalPath.resolve(requestedRoot) else {
            reportRootUnavailable(requestedRoot, underlying: nil)
            finishOpening(current)
            return
        }
        model = FileTreeModel(root: root).settingContents(.loading, for: root)
        startWatcher(root: root)
        let decorating = startDecorations(root: requestedRoot)
        await load(root, generation: current)
        // The saved expansions below need the root's entries.
        await settle(root)
        guard current == generation, model != nil else {
            finishOpening(current)
            return
        }
        await restoreState(root: root, generation: current)
        finishOpening(current)
        await decorating.value
    }

    /// Clears `restoringGeneration` only if it still names `current` — a
    /// generation that has since been superseded must never clear the value
    /// the generation that replaced it is relying on.
    private func finishOpening(_ current: Int) {
        if restoringGeneration == current { restoringGeneration = nil }
    }

    private func reportRootUnavailable(_ root: String, underlying error: (any Error)?) {
        // Paths keep the default private redaction; only the error text,
        // which names no path, is logged publicly.
        if let error {
            Self.logger.error("root unavailable at \(root): \(error.localizedDescription, privacy: .public)")
        } else {
            Self.logger.error("root unavailable at \(root)")
        }
        rootError = ExplorerError.rootUnavailable(root).localizedDescription
    }

    /// Whether an FSEvents stream is currently owned by this view model.
    /// Internal so the watcher's lifecycle can be asserted without widening
    /// the public API.
    internal var hasActiveWatcher: Bool { watcher != nil }

    private func startWatcher(root: String) {
        watcher = services.makeWatcher(root) { [weak self] change in
            Task { @MainActor in
                self?.handleChange(change)
            }
        }
        if let watcher, !watcher.start() {
            Self.logger.error("file system watcher did not start; the tree will not refresh by itself")
        }
    }

    private func stopWatcher() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Loading

    private func load(_ directory: String, generation current: Int) async {
        guard let root = model?.root else { return }
        loadTokens[directory, default: 0] += 1
        let token = loadTokens[directory]
        let scan = services.scan
        let result: Result<DirectoryListing, any Error> = await Task.detached(priority: .userInitiated) {
            Result { try scan(directory, root) }
        }.value
        guard
            current == generation, let model, model.directories[directory] != nil,
            loadTokens[directory] == token
        else { return }
        switch result {
        case .success(let listing):
            staleDirectories.remove(directory)
            self.model = model.settingContents(.loaded(listing), for: directory)
        case .failure(let error) where directory == model.root:
            self.model = nil
            // Spec §3.5: no stream keeps running behind the error state; a
            // successful `retry()` builds a fresh one.
            stopWatcher()
            stopDecorations()
            reportRootUnavailable(model.root, underlying: error)
        case .failure(let error):
            self.model = model.settingContents(.failed(error.localizedDescription), for: directory)
        }
    }

    /// A watcher batch arriving while `directory` was being scanned for the
    /// first time reloads it, and that first result is dropped as stale:
    /// the directory's contents are the reload's. Waits for them, so a
    /// caller that goes on to use the entries (restoring expansions, a
    /// reveal) does not find the directory still loading.
    private func settle(_ directory: String) async {
        guard case .loading? = model?.directories[directory], let reloadTask else { return }
        await reloadTask.value
    }

    /// Rescans `directories` — the ones on screen; the rest are marked stale
    /// for their next expansion. One loop serves every request: a batch
    /// arriving while it scans joins `pendingReloads`, and the chain in
    /// flight gives way after its current directory, so a burst of agent
    /// writes costs one reload of the union, not one chain per batch.
    private func scheduleReload(_ directories: Set<String>) -> Task<Void, Never> {
        guard let model else { return Task {} }
        let shown = directories.filter(model.isShown)
        staleDirectories.formUnion(directories.subtracting(shown))
        guard !shown.isEmpty else { return reloadTask ?? Task {} }
        pendingReloads.formUnion(shown)
        if let reloadTask { return reloadTask }
        let current = generation
        let task = Task { await self.drainReloads(generation: current) }
        reloadTask = task
        return task
    }

    private func drainReloads(generation current: Int) async {
        while current == generation, !pendingReloads.isEmpty {
            var chain = pendingReloads.sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
            pendingReloads = []
            while current == generation, !chain.isEmpty {
                guard pendingReloads.isEmpty else {
                    // Superseded: what is left joins the newer batch, and
                    // the union is reloaded shallow-first from the top.
                    pendingReloads.formUnion(chain)
                    break
                }
                await load(chain.removeFirst(), generation: current)
            }
        }
        if current == generation { reloadTask = nil }
    }

    // MARK: - Expansion

    @discardableResult
    public func expand(_ path: String) -> Task<Void, Never> {
        guard let model, !ExplorerPaths.isInsideDotGit(path, root: model.root),
              model.entry(at: path)?.isExpandable == true
        else { return Task {} }
        let expanded = model.expanding(path)
        switch expanded.directories[path] {
        case .loaded?, .loading?:
            self.model = expanded
            persistState()
            return rescanStaleDirectoriesNowShown()
        case .failed?, nil:
            self.model = expanded.settingContents(.loading, for: path)
            staleDirectories.remove(path)
            let current = generation
            return Task {
                await self.load(path, generation: current)
                await self.settle(path)
                // Safe even when that load was discarded (a superseded
                // generation, or a newer token for this directory):
                // `persistState` writes only live main-actor state — the
                // model and selection as they stand now — never this
                // task's own result.
                self.persistState()
                await self.rescanStaleDirectoriesNowShown().value
            }
        }
    }

    /// An expansion can show folders that changed while hidden (the folder
    /// itself, or expanded ones beneath it); they still hold their old
    /// contents, so they are rescanned now.
    private func rescanStaleDirectoriesNowShown() -> Task<Void, Never> {
        guard let model else { return Task {} }
        let shown = staleDirectories.filter { model.directories[$0] != nil && model.isShown($0) }
        guard !shown.isEmpty else { return Task {} }
        staleDirectories.subtract(shown)
        return scheduleReload(shown)
    }

    /// Rows under the collapsed folder leave the selection: operations act
    /// on what is visibly selected.
    public func collapse(_ path: String) {
        guard let model else { return }
        self.model = model.collapsing(path)
        selection = selection.filter { !$0.hasPrefix(path + "/") }
        persistState()
    }

    public func collapseAll() {
        guard let model else { return }
        self.model = model.collapsingAll()
        selection = selection.filter { FileTreeModel.parent(of: $0) == model.root }
        persistState()
    }

    // MARK: - Refresh

    /// Rescans every folder on screen; collapsed ones are rescanned when
    /// next expanded.
    /// Also re-reads the Git Status Decorations.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        guard let model else { return Task {} }
        let reload = scheduleReload(Set(model.directories.keys))
        let decorating = workingTreeDidChange()
        return Task {
            await reload.value
            await decorating.value
        }
    }

    @discardableResult
    public func handleChange(_ change: FileSystemChange) -> Task<Void, Never> {
        guard let model else { return Task {} }
        let decorating = Self.touchesWorkingTree(change, root: model.root) ? workingTreeDidChange() : Task {}
        let tracked = Set(model.directories.keys)
        // A dropped/coalesced event says nothing usable about WHICH paths
        // changed, so — like a `.gitignore` edit — everything tracked is
        // suspect.
        let reloadEverything = change.touchedGitignore || change.needsFullRescan
        let targets = reloadEverything ? tracked : tracked.intersection(change.directories)
        guard !targets.isEmpty else { return decorating }
        let reload = scheduleReload(targets)
        return Task {
            await reload.value
            await decorating.value
        }
    }

    // MARK: - Showing a File Operation

    /// Fork-only: explorer operations. Shows an operation's result without
    /// waiting for the watcher: a renamed or moved folder keeps its
    /// expansion under the new path, and the folders whose listings changed
    /// are rescanned now. A rescan of them already in flight started before
    /// the operation, so its result is discarded — applied, it would prune a
    /// relocated folder's expansion as an orphan.
    func reloadAfterOperation(changedFolders: Set<String>, relocations: [(from: String, to: String)]) -> Task<Void, Never> {
        guard var next = model else { return Task {} }
        for folder in changedFolders { loadTokens[folder, default: 0] += 1 }
        var relocated: Set<String> = []
        for (from, to) in relocations where next.expanded.contains(from) || next.directories[from] != nil {
            next = next.relocating(from: from, to: to)
            relocated.formUnion(next.expanded.filter { $0 == to || $0.hasPrefix(to + "/") })
            staleDirectories = staleDirectories.filter { $0 != from && !$0.hasPrefix(from + "/") }
        }
        // Every relocated expanded folder is rescanned: now if it is on
        // screen, else (as stale) when an expansion shows it — even one that
        // landed under a collapsed folder, which a reveal then expands.
        for folder in relocated {
            next = next.settingContents(.loading, for: folder)
        }
        model = next
        let loaded = next
        return scheduleReload(changedFolders.filter { loaded.directories[$0] != nil }.union(relocated))
    }

    // MARK: - Reveal

    @discardableResult
    public func reveal(_ path: String) -> Task<Void, Never> {
        // Every compared path must go through `CanonicalPath.resolve` — a
        // caller-supplied path may be a non-canonical alias (e.g. `/var/…`
        // for `/private/var/…`) that would never match `root` otherwise.
        // `CanonicalPath.isInside` is not the test here: the resolved
        // STRING is needed for the ancestor walk below anyway, and the
        // root itself must not qualify (there is nothing to reveal), which
        // `isInside` would accept.
        guard
            let root = model?.root, let resolved = CanonicalPath.resolve(path),
            resolved.hasPrefix(root + "/"), !ExplorerPaths.isInsideDotGit(resolved, root: root)
        else { return Task {} }
        let components = Array(ExplorerPaths.relative(resolved, to: root).split(separator: "/").dropLast())
        let ancestors = components.indices.map { index in
            root + "/" + components[...index].joined(separator: "/")
        }
        return Task {
            for ancestor in ancestors { await self.expand(ancestor).value }
            if self.model?.entry(at: resolved) != nil {
                self.revealToken += 1
                self.selection = [resolved]
            }
        }
    }

    // MARK: - Filter and persistence

    public func setFilter(_ next: VisibilityFilter) {
        filter = next
        stateStore.filter = next
    }

    public func persistState() {
        guard restoringGeneration != generation, let model else { return }
        stateStore.save(
            RootViewState(expanded: model.expanded.sorted(), selection: selection, scrollOffset: scrollOffset),
            forRoot: model.root
        )
    }

    /// Replays a root's saved expansions, then applies its selection and
    /// scroll offset. `restoringGeneration` (set by `open` before this runs)
    /// already suppresses `persistState` for the whole call, so a partially
    /// replayed expansion set is never written back as if it were final.
    private func restoreState(root: String, generation current: Int) async {
        guard current == generation else { return }
        guard let saved = stateStore.state(forRoot: root) else {
            // No saved state is still a completed restore: the outline still
            // needs a `restoreToken` bump so it resets scroll for this root
            // instead of keeping the previous root's leftover offset.
            restoreToken += 1
            return
        }
        let shallowFirst = saved.expanded.sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
        for path in shallowFirst {
            guard current == generation else { return }
            await expand(path).value
        }
        guard current == generation, let model else { return }
        // Fork-only: explorer operations. A selection made meanwhile — a
        // click, or the result of an operation undone right after switching
        // back to this root — is newer than the saved one.
        if selection.isEmpty {
            selection = saved.selection.filter { model.entry(at: $0) != nil }
        }
        scrollOffset = saved.scrollOffset
        restoreToken += 1
    }
}
