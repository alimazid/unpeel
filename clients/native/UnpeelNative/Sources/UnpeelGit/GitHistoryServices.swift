import Foundation

/// Everything `GitHistoryViewModel` asks of the outside world, injectable so
/// tests control results and timing. Every read is called off the main
/// thread. HEAD, the repository's location and change signals come from
/// `repositories`, shared with the EXPLORER's decorations, so one change
/// costs one status read across both views.
public struct GitHistoryServices: Sendable {
    public typealias Branches = @Sendable (_ root: String) -> GitReadResult<[GitRef]>
    public typealias CommitDetail = @Sendable (_ root: String, _ commit: GitCommit) -> GitReadResult<GitCommitDetail>
    public typealias LogPage = @Sendable (
        _ root: String, _ scope: GitLogScope, _ offset: Int, _ limit: Int
    ) -> GitReadResult<GitLogPage>

    public let branches: Branches
    public let logPage: LogPage
    public let commitDetail: CommitDetail
    public let repositories: GitRepositoryHub
    /// Fork-only: nested repositories. Which repository each Explorer Root
    /// reads, shared with the EXPLORER's decorations; nil always reads the
    /// Explorer Root itself.
    public let repositoryRoots: GitRepositoryRoots?

    public init(
        branches: @escaping Branches,
        logPage: @escaping LogPage,
        commitDetail: @escaping CommitDetail,
        repositories: GitRepositoryHub,
        repositoryRoots: GitRepositoryRoots? = nil
    ) {
        self.branches = branches
        self.logPage = logPage
        self.commitDetail = commitDetail
        self.repositories = repositories
        self.repositoryRoots = repositoryRoots
    }

    /// Services backed by a real reader, following repositories through
    /// `repositories` and, when given, choosing them through
    /// `repositoryRoots`.
    public static func reading(
        _ reader: GitReader, repositories: GitRepositoryHub, repositoryRoots: GitRepositoryRoots? = nil
    ) -> GitHistoryServices {
        GitHistoryServices(
            branches: { reader.branches(at: $0) },
            logPage: { reader.logPage(at: $0, scope: $1, offset: $2, limit: $3) },
            commitDetail: { reader.commitDetail(at: $0, commit: $1) },
            repositories: repositories,
            repositoryRoots: repositoryRoots
        )
    }
}
