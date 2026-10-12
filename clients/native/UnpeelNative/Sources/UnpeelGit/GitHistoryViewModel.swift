import Combine
import Foundation
import os

/// Git History's state for one Explorer Root: the header (Checked-out
/// Branch, upstream counts), the History Branch Filter, the commit list,
/// the one expanded commit, and why there is nothing to show when there is
/// not. Shaped like `ExplorerViewModel`: `setContext` follows the selected
/// Session, every git read runs off the main thread, and a generation
/// counter discards results that belong to a root no longer shown. While a
/// repository is shown it is watched, and changes refresh everything in
/// place (`repositoryDidChange`).
@MainActor
public final class GitHistoryViewModel: ObservableObject {
    public static let defaultPageSize = 200
    /// How long a change signal waits for more before the refresh starts.
    public static let defaultChangeDebounce: TimeInterval = 0.2

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

    private var monitor: (any GitChangeMonitoring)?
    private var monitoredLocation: GitRepositoryLocation?
    /// A change arrived that no refresh has read yet.
    private var pendingChange = false
    /// The refresh loop serving change signals, while one runs.
    private var changeTask: Task<Void, Never>?

    public init(
        services: GitHistoryServices,
        pageSize: Int = GitHistoryViewModel.defaultPageSize,
        changeDebounce: TimeInterval = GitHistoryViewModel.defaultChangeDebounce
    ) {
        self.services = services
        self.pageSize = max(1, pageSize)
        self.changeDebounce = max(0, changeDebounce)
    }

    deinit {
        monitor?.stop()
    }

    /// The Explorer Root git reads run in, when there is one.
    public var root: String? {
        guard case .local(let root, _) = context else { return nil }
        return root
    }

    /// Which commits the list shows.
    var scope: GitLogScope { filter.scope }

    public var localBranches: [GitRef] { branches.filter { $0.kind == .localBranch } }
    public var remoteBranches: [GitRef] { branches.filter { $0.kind == .remoteBranch } }

    /// The filter's label: the Checked-out Branch (or `detached@…`), the
    /// chosen branch, or "All branches".
    public var filterTitle: String {
        switch filter {
        case .checkedOut: return head?.displayName ?? ""
        case .branch(let ref): return ref.name
        case .allBranches: return GitHistoryFilter.allBranchesTitle
        }
    }

    /// The History Branch Filter only has choices once there are commits;
    /// a repository without any keeps its empty state.
    public var canChooseFilter: Bool { head?.hasCommits == true }

    /// Whether the list shows the Checked-out Branch — by default, or
    /// because the branch the user chose is the one checked out now.
    public var filterShowsCheckedOutBranch: Bool {
        switch filter {
        case .checkedOut: return true
        case .branch(let ref): return ref.kind == .localBranch && ref.name == head?.branch
        case .allBranches: return false
        }
    }

    // MARK: - Context

    @discardableResult
    public func setContext(_ next: ExplorerContext) -> Task<Void, Never> {
        guard next != context else { return Task {} }
        generation += 1
        listGeneration += 1
        loadingMore = false
        pendingChange = false
        changeTask = nil
        watch(nil)
        context = next
        head = nil
        filter = .checkedOut
        branches = []
        expanded = nil
        location = nil
        detailCache = [:]
        commits = []
        hasMore = false
        status = Self.initialStatus(for: next)
        let current = generation
        return Task { await self.load(generation: current, merging: false) }
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
    /// deleted). Signals are coalesced: a burst costs one refresh, and one
    /// arriving mid-refresh costs exactly one more.
    @discardableResult
    public func repositoryDidChange() -> Task<Void, Never> {
        guard root != nil else { return Task {} }
        pendingChange = true
        if let changeTask { return changeTask }
        let current = generation
        let debounce = changeDebounce
        let task = Task {
            if debounce > 0 { try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000)) }
            while self.pendingChange, current == self.generation {
                self.pendingChange = false
                await self.load(generation: current, merging: true)
            }
            if current == self.generation { self.changeTask = nil }
        }
        changeTask = task
        return task
    }

    /// Watches `location` (nil stops watching). A signal from a monitor of a
    /// previous generation is ignored.
    private func watch(_ location: GitRepositoryLocation?) {
        guard location != monitoredLocation else { return }
        monitor?.stop()
        monitor = nil
        monitoredLocation = location
        guard let location else { return }
        let current = generation
        monitor = services.makeMonitor(location) { [weak self] in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.repositoryDidChange()
            }
        }
    }

    // MARK: - Loading

    private func load(generation current: Int, merging: Bool) async {
        guard current == generation, let root else { return }
        let token = nextReplacementToken()
        let readHead = services.head
        let readBranches = services.branches
        let readRepository = services.repository
        let (headResult, branchesResult, locationResult) = await Task.detached(priority: .userInitiated) {
            (readHead(root), readBranches(root), readRepository(root))
        }.value
        guard current == generation, token == replacementToken else { return }
        let read: GitHead
        switch headResult {
        case .success(let value):
            read = value
        case .failure(let failure):
            show(failure)
            return
        }
        head = read
        switch locationResult {
        case .success(let value):
            location = value
        case .failure(let failure):
            // Costs opening changed files and live updates, not the list.
            Self.logger.error("repository location unreadable: \(String(describing: failure), privacy: .public)")
            location = nil
        }
        watch(location)
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
        watch(nil)
        replaceList(with: GitLogPage(commits: [], hasMore: false))
        status = GitHistoryStatus(failure)
    }
}
