import XCTest
@testable import UnpeelGit

@MainActor
final class GitHistoryLiveTests: XCTestCase {
    private func local(_ root: String) -> ExplorerContext {
        .local(root: root, projectRoot: root)
    }

    private func scripted(commits: Int = 5) -> FakeGitHistory {
        let fake = FakeGitHistory()
        fake.setHead(.success(GitHead(oid: "c-\(commits - 1)", branch: "main", upstream: "origin/main", ahead: 0, behind: 0)), for: "/repo")
        fake.setBranches([localBranch("main"), localBranch("topic")], for: "/repo")
        fake.setCommits(fakeCommits(commits), for: "/repo")
        fake.setCommits(fakeCommits(2, prefix: "t"), for: "/repo", scope: .ref("refs/heads/topic"))
        fake.setLocation(GitRepositoryLocation(workTree: "/repo", gitDirectory: "/repo/.git", commonDirectory: "/repo/.git"), for: "/repo")
        return fake
    }

    private func viewModel(_ fake: FakeGitHistory, pageSize: Int = 3) -> GitHistoryViewModel {
        GitHistoryViewModel(services: fake.services, pageSize: pageSize, changeDebounce: 0)
    }

    func testTheRepositoryIsWatchedWhileShown() async {
        let fake = scripted()
        let model = viewModel(fake)

        await model.setContext(local("/repo")).value

        XCTAssertEqual(fake.monitors.active.count, 1)
        XCTAssertEqual(fake.monitors.active.first?.location?.gitDirectory, "/repo/.git")
    }

    func testTheWatchIsReleasedWhenTheExplorerRootChanges() async {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value

        await model.setContext(.none).value

        XCTAssertEqual(fake.monitors.all.count, 1)
        XCTAssertTrue(fake.monitors.active.isEmpty)
    }

    func testRefreshesDoNotStackWatches() async {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value

        await model.refresh().value
        await model.repositoryDidChange().value

        XCTAssertEqual(fake.monitors.all.count, 1)
    }

    /// An agent commits while the user has scrolled two pages in and has a
    /// commit open: the new commit lands on top, nothing loaded is lost.
    func testAnExternalCommitLandsOnTopKeepingPagesAndTheExpandedCommit() async {
        let fake = scripted(commits: 8)
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.loadMore().value
        await model.toggleExpanded("c-3").value
        XCTAssertEqual(model.commits.count, 6)

        fake.setCommits(fakeCommits(1, prefix: "new") + fakeCommits(8), for: "/repo")
        fake.setHead(.success(GitHead(oid: "new-0", branch: "main", upstream: "origin/main", ahead: 1, behind: 0)), for: "/repo")
        await model.repositoryDidChange().value

        XCTAssertEqual(model.commits.map(\.sha), ["new-0", "c-7", "c-6", "c-5", "c-4", "c-3", "c-2"])
        XCTAssertEqual(model.expanded?.sha, "c-3")
        XCTAssertEqual(model.head?.ahead, 1)
        XCTAssertTrue(model.hasMore)
    }

    func testARewrittenTopReplacesTheList() async {
        let fake = scripted(commits: 4)
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.toggleExpanded("c-2").value

        // `commit --amend` of the tip: c-3 is gone, its replacement is new.
        fake.setCommits(fakeCommits(1, prefix: "amended") + Array(fakeCommits(4).dropFirst()), for: "/repo")
        await model.repositoryDidChange().value

        XCTAssertEqual(model.commits.map(\.sha), ["amended-0", "c-2", "c-1"])
        XCTAssertEqual(model.expanded?.sha, "c-2")
    }

    func testAnExternalCheckoutUpdatesTheHeaderAndTheDefaultList() async {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value

        fake.setHead(.success(GitHead(oid: "t-1", branch: "topic")), for: "/repo")
        fake.setCommits(fakeCommits(2, prefix: "t"), for: "/repo")
        await model.repositoryDidChange().value

        XCTAssertEqual(model.head?.branch, "topic")
        XCTAssertEqual(model.filter, .checkedOut)
        XCTAssertEqual(model.filterTitle, "topic")
        XCTAssertEqual(model.commits.map(\.sha), ["t-1", "t-0"])
    }

    func testAnExternalCheckoutKeepsABranchTheUserChose() async {
        let fake = scripted()
        fake.setBranches([localBranch("main"), localBranch("topic"), localBranch("other")], for: "/repo")
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.selectFilter(.branch(localBranch("topic"))).value

        fake.setHead(.success(GitHead(oid: "x", branch: "other")), for: "/repo")
        await model.repositoryDidChange().value

        XCTAssertEqual(model.filter, .branch(localBranch("topic")))
        XCTAssertEqual(model.commits.map(\.sha), ["t-1", "t-0"])
        XCTAssertEqual(model.head?.branch, "other")
    }

    /// Review fix: choosing a branch that an agent then checks out must not
    /// turn the choice into "follow HEAD" — it stays when HEAD moves on.
    func testAChosenBranchSurvivesBeingCheckedOutAndLeft() async {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.selectFilter(.branch(localBranch("topic"))).value

        fake.setHead(.success(GitHead(oid: "t-1", branch: "topic")), for: "/repo")
        await model.repositoryDidChange().value
        XCTAssertEqual(model.filter, .branch(localBranch("topic")))
        XCTAssertTrue(model.isChosen(.branch(localBranch("topic"))))
        XCTAssertTrue(model.filterShowsCheckedOutBranch)

        fake.setHead(.success(GitHead(oid: "c-4", branch: "main")), for: "/repo")
        await model.repositoryDidChange().value
        XCTAssertEqual(model.filter, .branch(localBranch("topic")))
        XCTAssertEqual(model.commits.map(\.sha), ["t-1", "t-0"])
        XCTAssertFalse(model.filterShowsCheckedOutBranch)
    }

    /// Review fix: a failed branch listing keeps the choice and the list.
    func testAFailedBranchListingKeepsTheChosenBranch() async {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.selectFilter(.branch(localBranch("topic"))).value

        fake.setBranchFailure(.failed("fatal: unable to read refs"), for: "/repo")
        await model.repositoryDidChange().value

        XCTAssertEqual(model.filter, .branch(localBranch("topic")))
        XCTAssertEqual(model.localBranches.map(\.name), ["main", "topic"])
        XCTAssertEqual(model.commits.map(\.sha), ["t-1", "t-0"])
    }

    func testANewBranchAppearsInTheFilter() async {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value

        fake.setBranches([localBranch("agent/fix"), localBranch("main"), localBranch("topic")], for: "/repo")
        await model.repositoryDidChange().value

        XCTAssertEqual(model.localBranches.map(\.name), ["agent/fix", "main", "topic"])
    }

    func testADeletedChosenBranchFallsBackOnAChange() async {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.selectFilter(.branch(localBranch("topic"))).value

        fake.setBranches([localBranch("main")], for: "/repo")
        await model.repositoryDidChange().value

        XCTAssertEqual(model.filter, .checkedOut)
        XCTAssertEqual(model.commits.map(\.sha), ["c-4", "c-3", "c-2"])
    }

    /// A burst of change signals (one commit touches the index, HEAD, refs
    /// and logs) costs one status read and one log-head read.
    func testABurstOfChangesIsOneRead() async {
        let fake = scripted()
        let model = GitHistoryViewModel(services: fake.services, pageSize: 3, changeDebounce: 0.05)
        await model.setContext(local("/repo")).value
        let statusReadsBefore = fake.statusReadRoots.count
        let logsBefore = fake.logCalls.count

        let tasks = (0..<5).map { _ in model.repositoryDidChange() }
        for task in tasks { await task.value }

        XCTAssertEqual(fake.statusReadRoots.count - statusReadsBefore, 1)
        XCTAssertEqual(fake.logCalls.count - logsBefore, 1)
    }

    /// A change that arrives while a refresh is reading is not lost: one
    /// more refresh follows, never more.
    func testAChangeDuringARefreshRunsExactlyOneMore() async {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        let before = fake.statusReadRoots.count
        fake.setDelay(0.15, for: "/repo")

        let first = model.repositoryDidChange()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let second = model.repositoryDidChange()
        let third = model.repositoryDidChange()
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(fake.statusReadRoots.count - before, 2)
    }

    func testTheMonitorSignalRefreshes() async throws {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        fake.setBranches([localBranch("main"), localBranch("new"), localBranch("topic")], for: "/repo")

        let monitor = try XCTUnwrap(fake.monitors.active.first)
        monitor.handler()
        for _ in 0..<50 where model.localBranches.count < 3 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.localBranches.map(\.name), ["main", "new", "topic"])
    }

    // MARK: - The shared signal (#5, #10)

    /// A Session's folder that becomes a repository is noticed without
    /// reselecting it: a non-repository is watched for a `.git`.
    func testAFolderThatBecomesARepositoryIsNoticed() async throws {
        let fake = FakeGitHistory()
        let model = viewModel(fake)
        await model.setContext(local("/plain")).value
        XCTAssertEqual(model.status, .notARepository)
        let folderWatch = try XCTUnwrap(fake.monitors.active.first)
        XCTAssertEqual(folderWatch.folder, "/plain")

        fake.setHead(.success(GitHead(oid: "c-1", branch: "main")), for: "/plain")
        fake.setCommits(fakeCommits(2), for: "/plain")
        folderWatch.handler()
        for _ in 0..<50 where model.status != .ready {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.commits.map(\.sha), ["c-1", "c-0"])
        XCTAssertEqual(fake.monitors.active.map(\.location?.gitDirectory), ["/plain/.git"])
    }

    // MARK: - Collapsed (#10)

    func testCollapsingKeepsWhatIsShownAndStopsWatching() async {
        let fake = scripted(commits: 8)
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.loadMore().value
        await model.toggleExpanded("c-3").value
        model.scrollOffset = 140
        let reads = fake.statusReadRoots.count

        model.suspend()

        XCTAssertTrue(fake.monitors.active.isEmpty)
        XCTAssertEqual(model.commits.count, 6)
        XCTAssertEqual(model.expanded?.sha, "c-3")
        XCTAssertEqual(model.scrollOffset, 140)
        await model.repositoryDidChange().value
        XCTAssertEqual(fake.statusReadRoots.count, reads, "nothing is read while collapsed")
    }

    /// A change that arrived just before collapsing, still waiting out its
    /// debounce, is dropped: nothing is read once collapsed.
    func testCollapsingDropsARefreshStillWaiting() async throws {
        let fake = scripted()
        let model = GitHistoryViewModel(services: fake.services, pageSize: 3, changeDebounce: 0.2)
        await model.setContext(local("/repo")).value
        let reads = fake.statusReadRoots.count

        let waiting = model.repositoryDidChange()
        model.suspend()
        await waiting.value
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(fake.statusReadRoots.count, reads)
    }

    /// Expanding again on the same root catches up in place: an agent's
    /// commit made meanwhile lands on top, and the loaded pages, the
    /// expanded commit and the scroll position stay.
    func testExpandingAgainCatchesUpInPlace() async {
        let fake = scripted(commits: 8)
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.loadMore().value
        await model.toggleExpanded("c-3").value
        model.scrollOffset = 140
        model.suspend()

        fake.setCommits(fakeCommits(1, prefix: "new") + fakeCommits(8), for: "/repo")
        fake.setHead(.success(GitHead(oid: "new-0", branch: "main", upstream: "origin/main", ahead: 1, behind: 0)), for: "/repo")
        await model.setContext(local("/repo")).value

        XCTAssertEqual(model.commits.map(\.sha), ["new-0", "c-7", "c-6", "c-5", "c-4", "c-3", "c-2"])
        XCTAssertEqual(model.expanded?.sha, "c-3")
        XCTAssertEqual(model.scrollOffset, 140)
        XCTAssertEqual(model.head?.ahead, 1)
        XCTAssertEqual(fake.monitors.active.count, 1)
    }

    func testAnotherRootAfterCollapsingStartsFresh() async {
        let fake = scripted()
        fake.setHead(.success(GitHead(oid: "o-0", branch: "main")), for: "/other")
        fake.setCommits(fakeCommits(1, prefix: "o"), for: "/other")
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        await model.toggleExpanded("c-4").value
        model.scrollOffset = 90
        model.suspend()

        await model.setContext(local("/other")).value

        XCTAssertEqual(model.commits.map(\.sha), ["o-0"])
        XCTAssertNil(model.expanded)
        XCTAssertEqual(model.scrollOffset, 0)
        XCTAssertEqual(fake.monitors.active.map(\.location?.workTree), ["/other"])
    }

    func testAChangeForAPreviousRootIsIgnored() async throws {
        let fake = scripted()
        let model = viewModel(fake)
        await model.setContext(local("/repo")).value
        let stale = try XCTUnwrap(fake.monitors.active.first)
        await model.setContext(.remote).value
        let reads = fake.statusReadRoots.count

        stale.handler()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(fake.statusReadRoots.count, reads)
        XCTAssertEqual(model.status, .remote)
    }
}
