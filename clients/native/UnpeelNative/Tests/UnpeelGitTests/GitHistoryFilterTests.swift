import XCTest
@testable import UnpeelGit

@MainActor
final class GitHistoryFilterTests: XCTestCase {
    private func local(_ root: String) -> ExplorerContext {
        .local(root: root, projectRoot: root)
    }

    /// `/repo` on `main` with a local `topic` and a remote `origin/main`;
    /// each scope lists different commits.
    private func scripted(_ root: String = "/repo") -> FakeGitHistory {
        let fake = FakeGitHistory()
        fake.setHead(.success(GitHead(oid: "m-1", branch: "main")), for: root)
        fake.setBranches([localBranch("main"), localBranch("topic"), remoteBranch("origin/main")], for: root)
        fake.setCommits(fakeCommits(2, prefix: "m"), for: root, scope: .head)
        fake.setCommits(fakeCommits(3, prefix: "t"), for: root, scope: .ref("refs/heads/topic"))
        fake.setCommits(fakeCommits(1, prefix: "o"), for: root, scope: .ref("refs/remotes/origin/main"))
        fake.setCommits(fakeCommits(4, prefix: "all"), for: root, scope: .allBranches)
        return fake
    }

    func testDefaultsToTheCheckedOutBranchAndListsBranches() async {
        let fake = scripted()
        let viewModel = GitHistoryViewModel(services: fake.services)

        await viewModel.setContext(local("/repo")).value

        XCTAssertEqual(viewModel.filter, .checkedOut)
        XCTAssertEqual(viewModel.filterTitle, "main")
        XCTAssertEqual(viewModel.localBranches.map(\.name), ["main", "topic"])
        XCTAssertEqual(viewModel.remoteBranches.map(\.name), ["origin/main"])
        XCTAssertEqual(viewModel.commits.map(\.sha), ["m-1", "m-0"])
    }

    func testChoosingABranchReloadsItsLog() async {
        let fake = scripted()
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/repo")).value

        await viewModel.selectFilter(.branch(localBranch("topic"))).value
        XCTAssertEqual(viewModel.filter, .branch(localBranch("topic")))
        XCTAssertEqual(viewModel.filterTitle, "topic")
        XCTAssertEqual(viewModel.commits.map(\.sha), ["t-2", "t-1", "t-0"])

        await viewModel.selectFilter(.branch(remoteBranch("origin/main"))).value
        XCTAssertEqual(viewModel.commits.map(\.sha), ["o-0"])

        await viewModel.selectFilter(.allBranches).value
        XCTAssertEqual(viewModel.filterTitle, "All branches")
        XCTAssertEqual(viewModel.commits.map(\.sha), ["all-3", "all-2", "all-1", "all-0"])
        XCTAssertEqual(fake.logCalls.last?.scope, .allBranches)
    }

    func testIsChosenTreatsTheCheckedOutBranchAsTheDefault() async {
        let fake = scripted()
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/repo")).value

        XCTAssertTrue(viewModel.isChosen(.checkedOut))
        XCTAssertTrue(viewModel.isChosen(.branch(localBranch("main"))))
        XCTAssertFalse(viewModel.isChosen(.branch(localBranch("topic"))))
        XCTAssertFalse(viewModel.isChosen(.allBranches))
    }

    func testChoosingTheCheckedOutBranchByNameIsTheDefault() async {
        let fake = scripted()
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/repo")).value
        await viewModel.selectFilter(.allBranches).value

        await viewModel.selectFilter(.branch(localBranch("main"))).value

        XCTAssertEqual(viewModel.filter, .checkedOut)
        XCTAssertEqual(fake.logCalls.last?.scope, .head)
    }

    func testSelectingTheCurrentFilterReadsNothing() async {
        let fake = scripted()
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/repo")).value

        await viewModel.selectFilter(.checkedOut).value

        XCTAssertEqual(fake.logCalls.count, 1)
    }

    func testExplorerRootChangeResetsTheFilter() async {
        let fake = scripted("/a")
        fake.setHead(.success(GitHead(oid: "x", branch: "dev")), for: "/b")
        fake.setCommits(fakeCommits(1, prefix: "b"), for: "/b")
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/a")).value
        await viewModel.selectFilter(.branch(localBranch("topic"))).value

        await viewModel.setContext(local("/b")).value

        XCTAssertEqual(viewModel.filter, .checkedOut)
        XCTAssertEqual(viewModel.filterTitle, "dev")
        XCTAssertEqual(viewModel.commits.map(\.sha), ["b-0"])
    }

    func testADeletedSelectedBranchFallsBackToTheCheckedOutBranch() async {
        let fake = scripted()
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/repo")).value
        await viewModel.selectFilter(.branch(localBranch("topic"))).value

        fake.setBranches([localBranch("main"), remoteBranch("origin/main")], for: "/repo")
        await viewModel.refresh().value

        XCTAssertEqual(viewModel.filter, .checkedOut)
        XCTAssertEqual(viewModel.commits.map(\.sha), ["m-1", "m-0"])
        XCTAssertEqual(viewModel.localBranches.map(\.name), ["main"])
    }

    func testADetachedHeadIsTheDefaultTitle() async {
        let fake = scripted()
        fake.setHead(.success(GitHead(oid: "0123456789abcdef0123", branch: nil)), for: "/repo")
        let viewModel = GitHistoryViewModel(services: fake.services)

        await viewModel.setContext(local("/repo")).value

        XCTAssertEqual(viewModel.filterTitle, "detached@0123456789ab")
    }

    func testAFilterResultForASupersededChoiceIsDiscarded() async {
        let fake = scripted()
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local("/repo")).value
        fake.setLogDelay(0.2, for: "/repo")

        let slow = viewModel.selectFilter(.branch(localBranch("topic")))
        fake.setLogDelay(nil, for: "/repo")
        let fast = viewModel.selectFilter(.allBranches)
        await fast.value
        await slow.value

        XCTAssertEqual(viewModel.filter, .allBranches)
        XCTAssertEqual(viewModel.commits.map(\.sha), ["all-3", "all-2", "all-1", "all-0"])
    }

    /// The History Branch Filter only ever reads: choosing every entry in a
    /// real repository leaves HEAD, the index and the working tree as they
    /// were.
    func testChoosingEveryEntryNeverChangesTheRepository() async throws {
        let repository = try GitTestRepo(); defer { repository.delete() }
        try repository.write("a.txt", "a")
        try repository.commit("base")
        try repository.git("branch", "topic")
        try repository.write("a.txt", "changed, unstaged")
        try repository.write("staged.txt", "staged")
        try repository.git("add", "staged.txt")
        func snapshot() throws -> [String] {
            [
                try repository.output("rev-parse", "HEAD"),
                try repository.output("symbolic-ref", "HEAD"),
                try repository.output("status", "--porcelain=v1"),
                try repository.output("diff"),
            ]
        }
        let before = try snapshot()
        let viewModel = GitHistoryViewModel(services: .reading(GitReader()))
        await viewModel.setContext(local(repository.root)).value

        for branch in viewModel.localBranches + viewModel.remoteBranches {
            await viewModel.selectFilter(.branch(branch)).value
            XCTAssertEqual(try snapshot(), before, branch.name)
        }
        await viewModel.selectFilter(.allBranches).value
        await viewModel.selectFilter(.checkedOut).value

        XCTAssertEqual(try snapshot(), before)
        XCTAssertEqual(viewModel.localBranches.map(\.name), ["main", "topic"])
    }
}
