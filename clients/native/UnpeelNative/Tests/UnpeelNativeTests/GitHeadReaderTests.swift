import XCTest
@testable import UnpeelNative

/// Fork-only (#57): the read behind the sidebar's branch mark on this Mac. It
/// names a branch only when `.git/HEAD` itself says which one, because the mark
/// starts from it before `git symbolic-ref` answers.
final class GitHeadReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-head-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// A checkout whose `.git` is a directory with this HEAD.
    private func checkout(head: String) throws -> String {
        let repo = root.appendingPathComponent("repo-\(UUID().uuidString.prefix(6))")
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try head.write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return repo.path
    }

    func testABranchIsNamed() throws {
        let path = try checkout(head: "ref: refs/heads/feature-branch\n")

        XCTAssertEqual(GitHeadReader.checkedOutBranch(repoPath: path), "feature-branch")
    }

    func testASlashBranchKeepsItsWholeName() throws {
        let path = try checkout(head: "ref: refs/heads/feat/some-thing\n")

        XCTAssertEqual(GitHeadReader.checkedOutBranch(repoPath: path), "feat/some-thing")
    }

    func testADetachedHeadNamesNoBranch() throws {
        let path = try checkout(head: "1976b60d4f0d6c7e8a9b0c1d2e3f405162738495\n")

        XCTAssertNil(GitHeadReader.checkedOutBranch(repoPath: path))
    }

    /// A reftable repo's HEAD file is a stub: the real HEAD is in the reftable.
    func testTheReftableStubNamesNoBranch() throws {
        let path = try checkout(head: "ref: refs/heads/.invalid\n")

        XCTAssertNil(GitHeadReader.checkedOutBranch(repoPath: path))
    }

    func testAHeadOutsideRefsHeadsNamesNoBranch() throws {
        let path = try checkout(head: "ref: refs/remotes/origin/main\n")

        XCTAssertNil(GitHeadReader.checkedOutBranch(repoPath: path))
    }

    func testAFolderThatIsNoCheckoutNamesNoBranch() {
        XCTAssertNil(GitHeadReader.checkedOutBranch(repoPath: root.path))
    }

    /// A linked worktree's `.git` is a file with an absolute gitdir.
    func testALinkedWorktreesGitFileIsFollowed() throws {
        let gitdir = root.appendingPathComponent("main/.git/worktrees/linked")
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try "ref: refs/heads/linked-branch\n".write(
            to: gitdir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: \(gitdir.path)\n".write(
            to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(GitHeadReader.checkedOutBranch(repoPath: linked.path), "linked-branch")
    }

    /// A submodule's `.git` is a file with a relative gitdir.
    func testASubmodulesRelativeGitFileIsFollowed() throws {
        let gitdir = root.appendingPathComponent("outer/.git/modules/sub")
        try FileManager.default.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try "ref: refs/heads/sub-branch\n".write(
            to: gitdir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )
        let submodule = root.appendingPathComponent("outer/sub")
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/sub\n".write(
            to: submodule.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(GitHeadReader.checkedOutBranch(repoPath: submodule.path), "sub-branch")
    }

    /// The Host adapter's own read still shows a detached checkout's commit.
    func testCurrentBranchStillShowsADetachedHeadsShortCommit() throws {
        let path = try checkout(head: "1976b60d4f0d6c7e8a9b0c1d2e3f405162738495\n")

        XCTAssertEqual(GitHeadReader.currentBranch(repoPath: path), "1976b60")
    }

    /// Fork-only (#59): the Host adapter names a HEAD outside refs/heads the
    /// way the mark does once `git` answers, and never the reftable stub.
    func testCurrentBranchNamesAHeadOutsideRefsHeads() throws {
        let path = try checkout(head: "ref: refs/remotes/origin/main\n")

        XCTAssertEqual(GitHeadReader.currentBranch(repoPath: path), "origin/main")
    }

    func testCurrentBranchNamesNoBranchForTheReftableStub() throws {
        let path = try checkout(head: "ref: refs/heads/.invalid\n")

        XCTAssertNil(GitHeadReader.currentBranch(repoPath: path))
    }

    func testCurrentBranchKeepsASlashBranchWhole() throws {
        let path = try checkout(head: "ref: refs/heads/feat/some-thing\n")

        XCTAssertEqual(GitHeadReader.currentBranch(repoPath: path), "feat/some-thing")
    }
}
