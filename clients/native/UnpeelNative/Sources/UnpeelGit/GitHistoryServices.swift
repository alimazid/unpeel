import Foundation

/// Everything `GitHistoryViewModel` asks of the outside world, injectable so
/// tests control results and timing. Every read is called off the main
/// thread.
public struct GitHistoryServices: Sendable {
    public typealias Head = @Sendable (_ root: String) -> GitReadResult<GitHead>
    public typealias Branches = @Sendable (_ root: String) -> GitReadResult<[GitRef]>
    public typealias Repository = @Sendable (_ root: String) -> GitReadResult<GitRepositoryLocation>
    public typealias CommitDetail = @Sendable (_ root: String, _ commit: GitCommit) -> GitReadResult<GitCommitDetail>
    /// Starts watching a repository; the handler may be called on any
    /// thread. Nil when the repository cannot be watched.
    public typealias MakeMonitor = @Sendable (
        _ location: GitRepositoryLocation, _ handler: @escaping @Sendable () -> Void
    ) -> (any GitChangeMonitoring)?
    public typealias LogPage = @Sendable (
        _ root: String, _ scope: GitLogScope, _ offset: Int, _ limit: Int
    ) -> GitReadResult<GitLogPage>

    public let head: Head
    public let branches: Branches
    public let repository: Repository
    public let logPage: LogPage
    public let commitDetail: CommitDetail
    public let makeMonitor: MakeMonitor

    public init(
        head: @escaping Head,
        branches: @escaping Branches,
        repository: @escaping Repository,
        logPage: @escaping LogPage,
        commitDetail: @escaping CommitDetail,
        makeMonitor: @escaping MakeMonitor
    ) {
        self.head = head
        self.branches = branches
        self.repository = repository
        self.logPage = logPage
        self.commitDetail = commitDetail
        self.makeMonitor = makeMonitor
    }

    /// Services backed by a real reader; `makeMonitor` watches for changes
    /// (the default watches nothing — the FSEvents monitor lives with the
    /// EXPLORER's watcher in `UnpeelExplorer`).
    public static func reading(
        _ reader: GitReader,
        makeMonitor: @escaping MakeMonitor = { _, _ in nil }
    ) -> GitHistoryServices {
        GitHistoryServices(
            head: { reader.head(at: $0) },
            branches: { reader.branches(at: $0) },
            repository: { reader.repository(at: $0) },
            logPage: { reader.logPage(at: $0, scope: $1, offset: $2, limit: $3) },
            commitDetail: { reader.commitDetail(at: $0, commit: $1) },
            makeMonitor: makeMonitor
        )
    }
}
