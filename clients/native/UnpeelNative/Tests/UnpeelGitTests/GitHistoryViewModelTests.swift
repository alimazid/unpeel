import XCTest
@testable import UnpeelGit

@MainActor
final class GitHistoryViewModelTests: XCTestCase {
    private func local(_ root: String) -> ExplorerContext {
        .local(root: root, projectRoot: root)
    }

    private let main = GitHead(oid: "aaaa", branch: "main", upstream: "origin/main", ahead: 1, behind: 2)

    func testNoSessionAndRemoteAreEmptyStates() async {
        let fake = FakeGitHistory()
        let viewModel = GitHistoryViewModel(services: fake.services)

        XCTAssertEqual(viewModel.status, .noSession)
        await viewModel.setContext(.remote).value
        XCTAssertEqual(viewModel.status, .remote)
        await viewModel.setContext(.none).value
        XCTAssertEqual(viewModel.status, .noSession)
        XCTAssertNil(viewModel.head)
        XCTAssertTrue(fake.headReadRoots.isEmpty)
    }

    func testRepositoryShowsItsHead() async {
        let fake = FakeGitHistory()
        fake.setHead(.success(main), for: "/repo")
        let viewModel = GitHistoryViewModel(services: fake.services)

        await viewModel.setContext(local("/repo")).value

        XCTAssertEqual(viewModel.status, .ready)
        XCTAssertEqual(viewModel.head, main)
    }

    func testNotARepositoryGitUnavailableAndFailure() async {
        let fake = FakeGitHistory()
        fake.setHead(.failure(.notARepository), for: "/plain")
        fake.setHead(.failure(.gitUnavailable), for: "/nogit")
        fake.setHead(.failure(.failed("fatal: detected dubious ownership")), for: "/odd")
        let viewModel = GitHistoryViewModel(services: fake.services)

        await viewModel.setContext(local("/plain")).value
        XCTAssertEqual(viewModel.status, .notARepository)
        await viewModel.setContext(local("/nogit")).value
        XCTAssertEqual(viewModel.status, .gitUnavailable)
        await viewModel.setContext(local("/odd")).value
        XCTAssertEqual(viewModel.status, .failed("fatal: detected dubious ownership"))
        XCTAssertNil(viewModel.head)
    }

    func testRepositoryWithoutCommitsSaysSo() async {
        let fake = FakeGitHistory()
        fake.setHead(.success(GitHead(oid: nil, branch: "main")), for: "/fresh")
        let viewModel = GitHistoryViewModel(services: fake.services)

        await viewModel.setContext(local("/fresh")).value

        XCTAssertEqual(viewModel.status, .noCommits)
        XCTAssertEqual(viewModel.head?.branch, "main")
    }

    func testSameContextDoesNotReload() async {
        let fake = FakeGitHistory()
        fake.setHead(.success(main), for: "/repo")
        let viewModel = GitHistoryViewModel(services: fake.services)

        await viewModel.setContext(local("/repo")).value
        await viewModel.setContext(local("/repo")).value

        XCTAssertEqual(fake.headReadRoots, ["/repo"])
    }

    /// A slow read for the previous Explorer Root finishing after the
    /// switch must never show up under the new one.
    func testResultsForASupersededRootAreDiscarded() async {
        let fake = FakeGitHistory()
        fake.setHead(.success(GitHead(oid: "old", branch: "old-branch")), for: "/slow")
        fake.setDelay(0.3, for: "/slow")
        fake.setHead(.success(main), for: "/fast")
        let viewModel = GitHistoryViewModel(services: fake.services)

        let slow = viewModel.setContext(local("/slow"))
        let fast = viewModel.setContext(local("/fast"))
        await fast.value
        await slow.value

        XCTAssertEqual(viewModel.context, local("/fast"))
        XCTAssertEqual(viewModel.head, main)
        XCTAssertEqual(viewModel.status, .ready)
    }

    func testSwitchingAwayClearsThePreviousHeadImmediately() async {
        let fake = FakeGitHistory()
        fake.setHead(.success(main), for: "/repo")
        fake.setDelay(0.3, for: "/other")
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/repo")).value

        let pending = viewModel.setContext(local("/other"))

        XCTAssertNil(viewModel.head)
        XCTAssertEqual(viewModel.status, .loading)
        await pending.value
    }

    func testReadsRunOffTheMainThread() async {
        let recorder = ThreadRecorder()
        let viewModel = GitHistoryViewModel(services: GitHistoryServices(
            head: { _ in
                recorder.record(Thread.isMainThread)
                return .success(GitHead(oid: "a", branch: "main"))
            },
            branches: { _ in
                recorder.record(Thread.isMainThread)
                return .success([])
            },
            repository: { root in
                recorder.record(Thread.isMainThread)
                return .success(GitRepositoryLocation(workTree: root, gitDirectory: root, commonDirectory: root))
            },
            logPage: { _, _, _, _ in
                recorder.record(Thread.isMainThread)
                return .success(GitLogPage(commits: fakeCommits(1), hasMore: false))
            },
            commitDetail: { _, commit in
                recorder.record(Thread.isMainThread)
                return .success(GitCommitDetail(sha: commit.sha, message: "", files: []))
            },
            makeMonitor: { _, _ in nil }
        ))

        await viewModel.setContext(local("/repo")).value
        await viewModel.toggleExpanded("c-0").value

        XCTAssertEqual(recorder.values, [false, false, false, false, false])
    }

    func testEmptyStateMessages() {
        XCTAssertEqual(GitHistoryStatus.noSession.message, "Select a session to browse its history.")
        XCTAssertEqual(GitHistoryStatus.remote.message, "Git History is available for sessions running on this Mac.")
        XCTAssertEqual(GitHistoryStatus.notARepository.message, "This folder is not a git repository.")
        XCTAssertNotNil(GitHistoryStatus.gitUnavailable.message?.range(of: "git was not found"))
        XCTAssertEqual(GitHistoryStatus.noCommits.message, "No commits yet.")
        XCTAssertEqual(GitHistoryStatus.failed("fatal: x").message, "fatal: x")
        XCTAssertNil(GitHistoryStatus.ready.message)
        XCTAssertNil(GitHistoryStatus.loading.message)
    }
}
