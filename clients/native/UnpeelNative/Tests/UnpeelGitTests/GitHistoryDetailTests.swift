import XCTest
@testable import UnpeelGit

@MainActor
final class GitHistoryDetailTests: XCTestCase {
    private func local(_ root: String) -> ExplorerContext {
        .local(root: root, projectRoot: root)
    }

    private func loaded(_ fake: FakeGitHistory, root: String = "/repo", count: Int = 3) async -> GitHistoryViewModel {
        fake.setHead(.success(GitHead(oid: "c-\(count - 1)", branch: "main")), for: root)
        fake.setCommits(fakeCommits(count), for: root)
        let viewModel = GitHistoryViewModel(services: fake.services)
        await viewModel.setContext(local(root)).value
        return viewModel
    }

    func testExpandingACommitLoadsItsDetail() async {
        let fake = FakeGitHistory()
        let detail = GitCommitDetail(sha: "c-1", message: "subject 1\n\nbody", files: [GitChangedFile(kind: .modified, path: "a.txt")])
        fake.setDetail(.success(detail), for: "c-1")
        let viewModel = await loaded(fake)

        let task = viewModel.toggleExpanded("c-1")
        XCTAssertEqual(viewModel.expanded, GitExpandedCommit(sha: "c-1", state: .loading))
        await task.value

        XCTAssertEqual(viewModel.expanded, GitExpandedCommit(sha: "c-1", state: .loaded(detail)))
    }

    func testOnlyOneCommitIsExpandedAtATime() async {
        let fake = FakeGitHistory()
        let viewModel = await loaded(fake)

        await viewModel.toggleExpanded("c-2").value
        await viewModel.toggleExpanded("c-0").value

        XCTAssertEqual(viewModel.expanded?.sha, "c-0")
    }

    func testTogglingTheExpandedCommitCollapsesIt() async {
        let fake = FakeGitHistory()
        let viewModel = await loaded(fake)
        await viewModel.toggleExpanded("c-2").value

        await viewModel.toggleExpanded("c-2").value

        XCTAssertNil(viewModel.expanded)
    }

    func testDetailIsReadOncePerCommit() async {
        let fake = FakeGitHistory()
        let viewModel = await loaded(fake)

        await viewModel.toggleExpanded("c-2").value
        await viewModel.toggleExpanded("c-2").value
        await viewModel.toggleExpanded("c-2").value

        XCTAssertEqual(fake.detailReadSHAs, ["c-2"])
        XCTAssertEqual(viewModel.expanded?.state, .loaded(GitCommitDetail(sha: "c-2", message: "subject 2", files: [])))
    }

    func testADetailFailureIsShownInPlace() async {
        let fake = FakeGitHistory()
        fake.setDetail(.failure(.failed("fatal: bad object c-1")), for: "c-1")
        let viewModel = await loaded(fake)

        await viewModel.toggleExpanded("c-1").value

        XCTAssertEqual(viewModel.expanded, GitExpandedCommit(sha: "c-1", state: .failed("fatal: bad object c-1")))
        XCTAssertEqual(viewModel.status, .ready)
    }

    func testASlowDetailForAPreviouslyExpandedCommitIsDiscarded() async {
        let fake = FakeGitHistory()
        fake.setDetail(.success(GitCommitDetail(sha: "c-2", message: "slow", files: [])), for: "c-2", delay: 0.3)
        let viewModel = await loaded(fake)

        let slow = viewModel.toggleExpanded("c-2")
        await viewModel.toggleExpanded("c-0").value
        await slow.value

        XCTAssertEqual(viewModel.expanded?.sha, "c-0")
        XCTAssertEqual(viewModel.expanded?.state, .loaded(GitCommitDetail(sha: "c-0", message: "subject 0", files: [])))
    }

    func testDetailForASupersededRootIsDiscarded() async {
        let fake = FakeGitHistory()
        fake.setDetail(.success(GitCommitDetail(sha: "c-2", message: "slow", files: [])), for: "c-2", delay: 0.3)
        fake.setHead(.success(GitHead(oid: "x", branch: "main")), for: "/other")
        fake.setCommits(fakeCommits(1, prefix: "o"), for: "/other")
        let viewModel = await loaded(fake)

        let slow = viewModel.toggleExpanded("c-2")
        await viewModel.setContext(local("/other")).value
        await slow.value

        XCTAssertNil(viewModel.expanded)
        XCTAssertEqual(viewModel.commits.map(\.sha), ["o-0"])
    }

    func testChangingTheFilterKeepsTheExpandedCommitOnlyIfStillListed() async {
        let fake = FakeGitHistory()
        fake.setBranches([localBranch("main"), localBranch("topic")], for: "/repo")
        fake.setCommits([fakeCommits(3)[1]] + fakeCommits(2, prefix: "t"), for: "/repo", scope: .ref("refs/heads/topic"))
        fake.setCommits(fakeCommits(2, prefix: "x"), for: "/repo", scope: .allBranches)
        let viewModel = await loaded(fake)
        await viewModel.toggleExpanded("c-1").value

        await viewModel.selectFilter(.branch(localBranch("topic"))).value
        XCTAssertEqual(viewModel.expanded?.sha, "c-1")

        await viewModel.selectFilter(.allBranches).value
        XCTAssertNil(viewModel.expanded)
    }

    func testWorkTreePathOnlyForFilesThatStillExist() async throws {
        let tree = try GitTestRepo(initialize: false); defer { tree.delete() }
        try tree.write("docs/readme.md", "x")
        try FileManager.default.createDirectory(atPath: tree.path("folder"), withIntermediateDirectories: true)
        let fake = FakeGitHistory()
        fake.setLocation(GitRepositoryLocation(workTree: tree.root, gitDirectory: "", commonDirectory: ""), for: "/repo")
        let viewModel = await loaded(fake)

        XCTAssertEqual(viewModel.workTreePath(for: GitChangedFile(kind: .modified, path: "docs/readme.md")), tree.path("docs/readme.md"))
        XCTAssertNil(viewModel.workTreePath(for: GitChangedFile(kind: .deleted, path: "gone.txt")))
        XCTAssertNil(viewModel.workTreePath(for: GitChangedFile(kind: .added, path: "folder")), "a path that is now a folder")
        XCTAssertNil(viewModel.workTreePath(for: GitChangedFile(kind: .added, path: "../escape.txt")))
    }
}
