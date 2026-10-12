import Foundation

/// Everything `GitHistoryViewModel` asks of the outside world, injectable so
/// tests control results and timing. Every read is called off the main
/// thread.
public struct GitHistoryServices: Sendable {
    public typealias Head = @Sendable (_ root: String) -> GitReadResult<GitHead>
    public typealias Branches = @Sendable (_ root: String) -> GitReadResult<[GitRef]>
    public typealias Repository = @Sendable (_ root: String) -> GitReadResult<GitRepositoryLocation>
    public typealias CommitDetail = @Sendable (_ root: String, _ commit: GitCommit) -> GitReadResult<GitCommitDetail>
    public typealias LogPage = @Sendable (
        _ root: String, _ scope: GitLogScope, _ offset: Int, _ limit: Int
    ) -> GitReadResult<GitLogPage>

    public let head: Head
    public let branches: Branches
    public let repository: Repository
    public let logPage: LogPage
    public let commitDetail: CommitDetail

    public init(
        head: @escaping Head,
        branches: @escaping Branches,
        repository: @escaping Repository,
        logPage: @escaping LogPage,
        commitDetail: @escaping CommitDetail
    ) {
        self.head = head
        self.branches = branches
        self.repository = repository
        self.logPage = logPage
        self.commitDetail = commitDetail
    }

    /// Services backed by a real reader.
    public static func reading(_ reader: GitReader) -> GitHistoryServices {
        GitHistoryServices(
            head: { reader.head(at: $0) },
            branches: { reader.branches(at: $0) },
            repository: { reader.repository(at: $0) },
            logPage: { reader.logPage(at: $0, scope: $1, offset: $2, limit: $3) },
            commitDetail: { reader.commitDetail(at: $0, commit: $1) }
        )
    }

    public static let live = reading(GitReader())
}
