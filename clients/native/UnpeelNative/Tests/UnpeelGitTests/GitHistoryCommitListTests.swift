import XCTest
@testable import UnpeelGit

@MainActor
final class GitHistoryCommitListTests: XCTestCase {
    private func local(_ root: String) -> ExplorerContext {
        .local(root: root, projectRoot: root)
    }

    private func repo(_ fake: FakeGitHistory, _ root: String = "/repo", commits: [GitCommit]) {
        fake.setHead(.success(GitHead(oid: commits.first?.sha, branch: "main")), for: root)
        fake.setCommits(commits, for: root)
    }

    func testFirstPageLoadsWithTheHeader() async {
        let fake = FakeGitHistory()
        let all = fakeCommits(450)
        repo(fake, commits: all)
        let viewModel = GitHistoryViewModel(services: fake.services, pageSize: 200)

        await viewModel.setContext(local("/repo")).value

        XCTAssertEqual(viewModel.status, .ready)
        XCTAssertEqual(viewModel.commits.map(\.sha), all.prefix(200).map(\.sha))
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertEqual(fake.logCalls, [.init(root: "/repo", scope: .head, offset: 0)])
    }

    func testDefaultPageSizeIsAboutTwoHundred() {
        XCTAssertEqual(GitHistoryViewModel.defaultPageSize, 200)
    }

    func testLoadMoreAppendsTheNextPage() async {
        let fake = FakeGitHistory()
        let all = fakeCommits(450)
        repo(fake, commits: all)
        let viewModel = GitHistoryViewModel(services: fake.services, pageSize: 200)
        await viewModel.setContext(local("/repo")).value

        await viewModel.loadMore().value
        XCTAssertEqual(viewModel.commits.map(\.sha), all.prefix(400).map(\.sha))
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.loadMore().value
        XCTAssertEqual(viewModel.commits.map(\.sha), all.map(\.sha))
        XCTAssertFalse(viewModel.hasMore)
    }

    func testLoadMoreAtTheEndReadsNothing() async {
        let fake = FakeGitHistory()
        repo(fake, commits: fakeCommits(3))
        let viewModel = GitHistoryViewModel(services: fake.services, pageSize: 200)
        await viewModel.setContext(local("/repo")).value

        await viewModel.loadMore().value

        XCTAssertEqual(fake.logCalls.count, 1)
        XCTAssertEqual(viewModel.commits.count, 3)
    }

    /// New commits landing on top between pages shift `--skip`, so the next
    /// page starts with commits already listed; they must not repeat.
    func testLoadMoreNeverDuplicatesCommits() async {
        let fake = FakeGitHistory()
        let original = fakeCommits(5)
        repo(fake, commits: original)
        let viewModel = GitHistoryViewModel(services: fake.services, pageSize: 3)
        await viewModel.setContext(local("/repo")).value

        fake.setCommits(fakeCommits(2, prefix: "new") + original, for: "/repo")
        while viewModel.hasMore { await viewModel.loadMore().value }

        // The new commits arrive through a refresh, not through paging.
        XCTAssertEqual(viewModel.commits.map(\.sha), original.map(\.sha))
        XCTAssertEqual(Set(viewModel.commits.map(\.sha)).count, viewModel.commits.count)
    }

    func testConcurrentLoadMoreRunsOnce() async {
        let fake = FakeGitHistory()
        repo(fake, commits: fakeCommits(10))
        let viewModel = GitHistoryViewModel(services: fake.services, pageSize: 3)
        await viewModel.setContext(local("/repo")).value
        fake.setLogDelay(0.1, for: "/repo")

        let first = viewModel.loadMore()
        let second = viewModel.loadMore()
        await first.value
        await second.value

        XCTAssertEqual(fake.logCalls.map(\.offset), [0, 3])
        XCTAssertEqual(viewModel.commits.count, 6)
    }

    func testAPageForASupersededRootIsDiscarded() async {
        let fake = FakeGitHistory()
        repo(fake, "/a", commits: fakeCommits(10, prefix: "a"))
        repo(fake, "/b", commits: fakeCommits(2, prefix: "b"))
        let viewModel = GitHistoryViewModel(services: fake.services, pageSize: 3)
        await viewModel.setContext(local("/a")).value
        fake.setLogDelay(0.2, for: "/a")

        let more = viewModel.loadMore()
        await viewModel.setContext(local("/b")).value
        await more.value

        XCTAssertEqual(viewModel.commits.map(\.sha), ["b-1", "b-0"])
        XCTAssertFalse(viewModel.hasMore)
    }

    func testSwitchingRootsClearsTheList() async {
        let fake = FakeGitHistory()
        repo(fake, "/a", commits: fakeCommits(3, prefix: "a"))
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/a")).value

        let pending = viewModel.setContext(.remote)

        XCTAssertTrue(viewModel.commits.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
        await pending.value
    }

    func testNoCommitsReadsNoLog() async {
        let fake = FakeGitHistory()
        fake.setHead(.success(GitHead(oid: nil, branch: "main")), for: "/fresh")
        let viewModel = GitHistoryViewModel(services: fake.services)

        await viewModel.setContext(local("/fresh")).value

        XCTAssertEqual(viewModel.status, .noCommits)
        XCTAssertTrue(fake.logCalls.isEmpty)
    }

    func testALogFailureIsShown() async {
        let fake = FakeGitHistory()
        repo(fake, commits: fakeCommits(2))
        fake.setLogFailure(.failed("fatal: bad object"), for: "/repo")
        let viewModel = GitHistoryViewModel(services: fake.services)

        await viewModel.setContext(local("/repo")).value

        XCTAssertEqual(viewModel.status, .failed("fatal: bad object"))
        XCTAssertTrue(viewModel.commits.isEmpty)
    }

    /// The real reader end to end: what the list holds is what `git log`
    /// says, page after page.
    func testRealRepositoryPagesMatchGitLog() async throws {
        let repository = try GitTestRepo(); defer { repository.delete() }
        for index in 0..<7 {
            try repository.commit("commit \(index)", date: 1_700_000_000 + index * 60)
        }
        let expected = try repository.output("log", "--format=%H").split(separator: "\n").map(String.init)
        let viewModel = GitHistoryViewModel(services: .reading(GitReader()), pageSize: 3)

        await viewModel.setContext(local(repository.root)).value
        while viewModel.hasMore { await viewModel.loadMore().value }

        XCTAssertEqual(viewModel.commits.map(\.sha), expected)
    }
}
