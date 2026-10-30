import Combine
import Foundation
import os

/// Git History's state for one Explorer Root: the header (Checked-out
/// Branch, upstream counts), the History Branch Filter, the commit list,
/// the one expanded commit, and why there is nothing to show when there is
/// not. Shaped like `ExplorerViewModel`: `setContext` follows the selected
/// Session, every git read runs off the main thread, and a generation
/// counter discards results that belong to a root no longer shown. While a
/// root is shown it is followed through the shared `GitRepositoryHub` —
/// HEAD and the repository's location come from the status read the
/// EXPLORER's decorations share — and its change signal refreshes
/// everything in place. Collapsing the section (`suspend`) stops reading
/// and watching but keeps what is shown, for expanding again.
///
/// Fork-only: nested repositories. With `GitRepositoryRoots`, an Explorer
/// Root that is not a repository shows the nested repository chosen in it
/// (`repository`, `chooseRepository`); switching repositories starts the
/// list over, like a new Explorer Root.
@MainActor
public final class GitHistoryViewModel: ObservableObject {
    public static let defaultPageSize = 200

    private static let logger = Logger(subsystem: "com.unpeel.git", category: "history")

    @Published public private(set) var context: ExplorerContext = .none
    @Published public private(set) var status: GitHistoryStatus = .noSession
    @Published public private(set) var head: GitHead?
    /// The History Branch Filter's choice.
    @Published public private(set) var filter: GitHistoryFilter = .checkedOut
    /// Every branch the filter can choose, local first.
    @Published public private(set) var branches: [GitRef] = []
    @Published public private(set) var commits: [GitCommit] = []
    /// More commits exist beyond the loaded ones (`loadMore`).
    @Published public private(set) var hasMore = false
    /// The one expanded commit, if any (see `GitHistoryViewModel+Detail`).
    @Published public internal(set) var expanded: GitExpandedCommit?
    /// Where the repository lives; changed-file paths are relative to its
    /// work tree.
    @Published public private(set) var location: GitRepositoryLocation?
    /// Fork-only: nested repositories. Which repository the Explorer Root
    /// reads, as last resolved; nil without `GitRepositoryRoots` or before
    /// the first resolution.
    @Published public private(set) var repository: GitRepositoryRootState?
    /// Where the list is scrolled; kept while the section is collapsed so
    /// expanding it lands where the user left off. Not published: only the
    /// outline reads it, when it is rebuilt.
    public var scrollOffset: Double = 0

    let services: GitHistoryServices
    private let pageSize: Int
    private let changeDebounce: TimeInterval
    /// Bumped on every context change; a read that finishes under an older
    /// generation belongs to a root that is no longer shown.
    private(set) var generation = 0
    /// Bumped whenever the list is replaced rather than extended, so an
    /// in-flight page for the old list is dropped instead of appended.
    private var listGeneration = 0
    /// Bumped by every read that will replace the list (a load, a refresh,
    /// a filter choice); one started earlier is dropped when it finishes.
    private var replacementToken = 0
    private var loadingMore = false
    /// Commit details read so far for this root; a commit never changes.
    var detailCache: [String: GitCommitDetail] = [:]

    /// The repository's hold on the shared hub: its status and change
    /// signal.
    private var subscription: GitRepositorySubscription?
    /// Fork-only: nested repositories. The Explorer Root's hold on which
    /// repository it reads.
    private var choiceSubscription: GitRepositorySubscription?
    /// Collapsed or hidden: not following the root, but keeping the list.
    private var isSuspended = false
    /// Serves change signals: a burst costs one refresh.
    private let changeRefresh = RefreshCoalescer()

    public init(
        services: GitHistoryServices,
        pageSize: Int = GitHistoryViewModel.defaultPageSize,
        changeDebounce: TimeInterval = RefreshCoalescer.defaultDebounce
    ) {
        self.services = services
        self.pageSize = max(1, pageSize)
        self.changeDebounce = max(0, changeDebounce)
    }

    deinit {
        subscription?.cancel()
        choiceSubscription?.cancel()
    }

    /// The Explorer Root the history follows, when there is one.
    public var explorerRoot: String? {
        guard case .local(let root, _) = context else { return nil }
        return root
    }

    /// Where git reads run: the nested repository in use, else the
    /// Explorer Root.
    public var root: String? {
        guard let explorerRoot else { return nil }
        return repository?.repositoryRoot ?? explorerRoot
    }

    /// Which commits the list shows.
    var scope: GitLogScope { filter.scope }

    public var localBranches: [GitRef] { branches.filter { $0.kind == .localBranch } }
    public var remoteBranches: [GitRef] { branches.filter { $0.kind == .remoteBranch } }

    /// The filter's label (`GitHistoryFilter.title(head:)`).
    public var filterTitle: String { filter.title(head: head) }

    /// The History Branch Filter only has choices once there are commits;
    /// a repository without any keeps its empty state.
    public var canChooseFilter: Bool { head?.hasCommits == true }

    /// Whether the list shows the Checked-out Branch
    /// (`GitHistoryFilter.showsCheckedOutBranch(head:)`).
    public var filterShowsCheckedOutBranch: Bool { filter.showsCheckedOutBranch(head: head) }

    // MARK: - Context

    /// Shows `next`'s history. The same root again after `suspend`
    /// resumes in place instead.
    @discardableResult
    public func setContext(_ next: ExplorerContext) -> Task<Void, Never> {
        guard next != context else { return isSuspended ? resume() : Task {} }
        generation += 1
        listGeneration += 1
        loadingMore = false
        changeRefresh.reset()
        isSuspended = false
        context = next
        repository = nil
        clearList()
        status = Self.initialStatus(for: next)
        follow(explorerRoot)
        let current = generation
        return Task { await self.load(generation: current, merging: false) }
    }

    /// The section was collapsed or hidden: no reads and no watching while
    /// nobody can see it — a refresh still waiting out its debounce is
    /// dropped — but the list, the expanded commit and the scroll position
    /// stay for when it is shown again.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        changeRefresh.reset()
        follow(nil)
    }

    /// Shown again: follow the root once more and catch up in place — new
    /// commits land on top, and the expanded commit stays if still listed.
    private func resume() -> Task<Void, Never> {
        isSuspended = false
        follow(explorerRoot)
        return refresh()
    }

    /// Everything shown for one repository, gone.
    private func clearList() {
        head = nil
        filter = .checkedOut
        branches = []
        expanded = nil
        location = nil
        detailCache = [:]
        commits = []
        hasMore = false
        scrollOffset = 0
    }

    /// Re-reads everything for the current root, keeping what is shown —
    /// loaded pages, the expanded commit — where history allows.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        let current = generation
        return Task { await self.load(generation: current, merging: true) }
    }

    private static func initialStatus(for context: ExplorerContext) -> GitHistoryStatus {
        switch context {
        case .none: return .noSession
        case .remote: return .remote
        case .local: return .loading
        }
    }

    // MARK: - Live updates

    /// The repository changed (a commit, checkout, fetch, branch created or
    /// deleted). Reported to the shared hub, so every view of the root —
    /// the EXPLORER's decorations too — reads it once; this view hears it
    /// back through its subscription (synchronously), and the refresh that
    /// starts is returned. Nothing happens while suspended.
    @discardableResult
    public func repositoryDidChange() -> Task<Void, Never> {
        guard let root, subscription != nil else { return Task {} }
        services.repositories.repositoryDidChange(root: root)
        return changeRefresh.current ?? Task {}
    }

    /// The hub's change signal for this root. Signals are coalesced: a
    /// burst costs one refresh, and one arriving mid-refresh costs exactly
    /// one more.
    @discardableResult
    private func heardRepositoryChange() -> Task<Void, Never> {
        let current = generation
        return changeRefresh.request(debounce: changeDebounce) { [weak self] in
            await self?.load(generation: current, merging: true)
        }
    }

    /// Follows `explorerRoot` (nil lets go): which repository it reads,
    /// and that repository through the hub. A signal for a previous
    /// generation is ignored.
    private func follow(_ explorerRoot: String?) {
        choiceSubscription?.cancel()
        choiceSubscription = nil
        followRepository(nil)
        guard let explorerRoot else { return }
        let current = generation
        choiceSubscription = services.repositoryRoots?.subscribe(explorerRoot: explorerRoot) { [weak self] in
            guard let self, current == self.generation else { return }
            self.heardRepositoryChange()
        }
        followRepository(root)
    }

    /// Follows `root` through the hub (nil lets go). The hub watches the
    /// repository — or, for a folder that is not one yet, waits for a
    /// `.git` — while any view follows it.
    private func followRepository(_ root: String?) {
        subscription?.cancel()
        subscription = nil
        guard let root else { return }
        let current = generation
        subscription = services.repositories.subscribe(root: root) { [weak self] in
            guard let self, current == self.generation else { return }
            self.heardRepositoryChange()
        }
    }

    // MARK: - Nested repositories

    /// Fork-only: nested repositories. Shows `repository` — a repository
    /// inside the Explorer Root, or nil for the folder itself — and
    /// remembers the choice; the EXPLORER's decorations follow it too.
    /// Only for an Explorer Root that is not a repository.
    @discardableResult
    public func chooseRepository(_ repository: String?) -> Task<Void, Never> {
        guard let explorerRoot, let roots = services.repositoryRoots, choiceSubscription != nil,
              roots.choose(repository, in: explorerRoot)
        else { return Task {} }
        // Choosing told every follower, this one included; the user is
        // waiting, so this one loads now rather than after the debounce.
        changeRefresh.reset()
        return refresh()
    }

    /// A newly resolved repository for the Explorer Root. Another
    /// repository than the one shown starts over, as a new Explorer Root
    /// would; returns whether it did.
    private func useRepository(_ resolved: GitRepositoryRootState) -> Bool {
        let previous = root
        repository = resolved
        guard resolved.repositoryRoot != previous else { return false }
        listGeneration += 1
        loadingMore = false
        clearList()
        status = .loading
        if !isSuspended { followRepository(resolved.repositoryRoot) }
        return true
    }

    // MARK: - Loading

    private func load(generation current: Int, merging: Bool) async {
        guard current == generation, let explorerRoot, let expectedRoot = root else { return }
        var token = nextReplacementToken()
        let readBranches = services.branches
        // Started for the repository shown so far, alongside resolving
        // which one to show (nearly always the same one again).
        var branchesRead = Task.detached(priority: .userInitiated) { readBranches(expectedRoot) }
        if let roots = services.repositoryRoots {
            let resolved = await roots.resolve(explorerRoot: explorerRoot)
            guard current == generation else { return }
            // Another repository is shown even when a newer read (a branch
            // chosen meanwhile) took over: that read was for the old one,
            // so it is dropped and this load reads the new one.
            if resolved != repository, useRepository(resolved) {
                token = nextReplacementToken()
            } else if token != replacementToken {
                return
            }
        }
        guard let root else { return }
        if root != expectedRoot {
            branchesRead = Task.detached(priority: .userInitiated) { readBranches(root) }
        }
        let snapshotResult = await services.repositories.status(root: root)
        let branchesResult = await branchesRead.value
        guard current == generation, token == replacementToken else { return }
        let snapshot: GitRepositorySnapshot
        switch snapshotResult {
        case .success(let value):
            snapshot = value
        case .failure(let failure):
            show(failure)
            return
        }
        let read = snapshot.status.head
        head = read
        location = snapshot.location
        let previousFilter = filter
        switch branchesResult {
        case .success(let value):
            branches = value
            // A chosen branch that no longer exists falls back. The choice
            // is never rewritten otherwise: a chosen branch an agent checks
            // out stays chosen when HEAD moves on.
            filter = filter.validated(against: value)
        case .failure(let failure):
            // Keep the last known branches and the choice; the next change
            // reads them again.
            Self.logger.error("branch listing failed: \(String(describing: failure), privacy: .public)")
        }
        guard read.hasCommits else {
            replaceList(with: GitLogPage(commits: [], hasMore: false))
            status = .noCommits
            return
        }
        let canMerge = merging && filter == previousFilter && status == .ready
        let page = await readPage(root: root, scope: scope, offset: 0)
        guard current == generation, token == replacementToken else { return }
        switch page {
        case .success(let page):
            if canMerge { merge(page) } else { replaceList(with: page) }
            status = .ready
        case .failure(let failure):
            show(failure)
        }
    }

    /// Merges a fresh first page into the listed commits: when the old top
    /// is still there with the same history below it, only the new commits
    /// are added on top, so loaded pages, the expanded commit and the
    /// user's place survive an agent's commit. Anything else (an amend, a
    /// reset, a checkout) replaces the list.
    private func merge(_ page: GitLogPage) {
        guard let top = commits.first,
              let newCount = page.commits.firstIndex(where: { $0.sha == top.sha })
        else { return replaceList(with: page) }
        let overlap = page.commits.count - newCount
        guard zip(page.commits[newCount...], commits).allSatisfy({ $0.sha == $1.sha }),
              commits.count > overlap
        else { return replaceList(with: page) }
        // The page's copies replace the old ones it covers (their ref
        // labels may have moved); older loaded commits are kept.
        commits = page.commits + commits.dropFirst(overlap)
    }

    // MARK: - History Branch Filter

    /// Chooses which branch's commits to list and reloads the list for it.
    /// Never touches the working tree: it only changes what is read.
    @discardableResult
    public func selectFilter(_ choice: GitHistoryFilter) -> Task<Void, Never> {
        let next = choice.normalized(head: head)
        guard canChooseFilter, next != filter, let root else { return Task {} }
        filter = next
        let current = generation
        let token = nextReplacementToken()
        let scope = next.scope
        return Task {
            let page = await self.readPage(root: root, scope: scope, offset: 0)
            guard current == self.generation, token == self.replacementToken else { return }
            switch page {
            case .success(let page):
                self.replaceList(with: page)
                self.status = .ready
            case .failure(let failure):
                self.show(failure)
            }
        }
    }

    /// Whether `choice` is what the filter shows now (the Checked-out
    /// Branch chosen by name counts as the default).
    public func isChosen(_ choice: GitHistoryFilter) -> Bool {
        choice.normalized(head: head) == filter.normalized(head: head)
    }

    private func nextReplacementToken() -> Int {
        replacementToken += 1
        return replacementToken
    }

    // MARK: - Paging

    /// Loads the next page; a no-op at the end, while one is loading, or
    /// with nothing listed.
    @discardableResult
    public func loadMore() -> Task<Void, Never> {
        guard hasMore, !loadingMore, let root else { return Task {} }
        loadingMore = true
        let current = generation
        let list = listGeneration
        let scope = scope
        let offset = commits.count
        return Task {
            let page = await self.readPage(root: root, scope: scope, offset: offset)
            guard current == self.generation, list == self.listGeneration else { return }
            self.loadingMore = false
            switch page {
            case .success(let page):
                // A commit landing on top since the last page shifts the
                // offset, so the new page can start with listed commits.
                let listed = Set(self.commits.map(\.sha))
                self.commits += page.commits.filter { !listed.contains($0.sha) }
                self.hasMore = page.hasMore
            case .failure(let failure):
                self.show(failure)
            }
        }
    }

    private func readPage(root: String, scope: GitLogScope, offset: Int) async -> GitReadResult<GitLogPage> {
        let readLog = services.logPage
        let limit = pageSize
        return await Task.detached(priority: .userInitiated) {
            readLog(root, scope, offset, limit)
        }.value
    }

    private func replaceList(with page: GitLogPage) {
        listGeneration += 1
        loadingMore = false
        commits = page.commits
        hasMore = page.hasMore
        if let sha = expanded?.sha, !page.commits.contains(where: { $0.sha == sha }) {
            expanded = nil
        }
    }

    private func show(_ failure: GitReadFailure) {
        head = nil
        branches = []
        location = nil
        replaceList(with: GitLogPage(commits: [], hasMore: false))
        status = GitHistoryStatus(failure)
    }
}
