import Combine
import Foundation

/// Git History's state for one Explorer Root: the header (Checked-out
/// Branch, upstream counts), the commit list, and why there is nothing to
/// show when there is not. Shaped like `ExplorerViewModel`: `setContext`
/// follows the selected Session, every git read runs off the main thread,
/// and a generation counter discards results that belong to a root no
/// longer shown.
@MainActor
public final class GitHistoryViewModel: ObservableObject {
    public static let defaultPageSize = 200

    @Published public private(set) var context: ExplorerContext = .none
    @Published public private(set) var status: GitHistoryStatus = .noSession
    @Published public private(set) var head: GitHead?
    @Published public private(set) var commits: [GitCommit] = []
    /// More commits exist beyond the loaded ones (`loadMore`).
    @Published public private(set) var hasMore = false

    private let services: GitHistoryServices
    private let pageSize: Int
    /// Bumped on every context change; a read that finishes under an older
    /// generation belongs to a root that is no longer shown.
    private var generation = 0
    /// Bumped whenever the list is replaced rather than extended, so an
    /// in-flight page for the old list is dropped instead of appended.
    private var listGeneration = 0
    private var loadingMore = false

    public init(services: GitHistoryServices = .live, pageSize: Int = GitHistoryViewModel.defaultPageSize) {
        self.services = services
        self.pageSize = max(1, pageSize)
    }

    /// The Explorer Root git reads run in, when there is one.
    public var root: String? {
        guard case .local(let root, _) = context else { return nil }
        return root
    }

    /// Which commits the list shows.
    var scope: GitLogScope { .head }

    // MARK: - Context

    @discardableResult
    public func setContext(_ next: ExplorerContext) -> Task<Void, Never> {
        guard next != context else { return Task {} }
        generation += 1
        listGeneration += 1
        loadingMore = false
        context = next
        head = nil
        commits = []
        hasMore = false
        status = Self.initialStatus(for: next)
        let current = generation
        return Task { await self.load(generation: current) }
    }

    /// Re-reads everything for the current root, keeping what is shown
    /// until the new results arrive.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        let current = generation
        return Task { await self.load(generation: current) }
    }

    private static func initialStatus(for context: ExplorerContext) -> GitHistoryStatus {
        switch context {
        case .none: return .noSession
        case .remote: return .remote
        case .local: return .loading
        }
    }

    // MARK: - Loading

    private func load(generation current: Int) async {
        guard current == generation, let root else { return }
        let readHead = services.head
        let headResult = await Task.detached(priority: .userInitiated) { readHead(root) }.value
        guard current == generation else { return }
        let read: GitHead
        switch headResult {
        case .success(let value):
            read = value
        case .failure(let failure):
            show(failure)
            return
        }
        head = read
        guard read.hasCommits else {
            replaceList(with: GitLogPage(commits: [], hasMore: false))
            status = .noCommits
            return
        }
        let page = await readPage(root: root, scope: scope, offset: 0)
        guard current == generation else { return }
        switch page {
        case .success(let page):
            replaceList(with: page)
            status = .ready
        case .failure(let failure):
            show(failure)
        }
    }

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
    }

    private func show(_ failure: GitReadFailure) {
        head = nil
        replaceList(with: GitLogPage(commits: [], hasMore: false))
        status = GitHistoryStatus(failure)
    }
}
