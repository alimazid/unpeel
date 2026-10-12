import XCTest
@testable import UnpeelGit

final class GitReaderDetailTests: XCTestCase {
    private var reader: GitReader!

    override func setUpWithError() throws {
        let git = try XCTUnwrap(GitExecutableResolver.system.resolve())
        reader = GitReader(runner: GitRunner(resolver: GitExecutableResolver { git }))
    }

    private func headCommit(_ repo: GitTestRepo) throws -> GitCommit {
        try XCTUnwrap(reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 1).get().commits.first)
    }

    func testAddedModifiedAndDeletedFiles() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write("keep.txt", "one")
        try repo.write("gone.txt", "bye")
        try repo.commit("first")
        try repo.write("keep.txt", "two")
        try repo.remove("gone.txt")
        try repo.write("new/file.txt", "hi")
        try repo.commit("second")

        let detail = try reader.commitDetail(at: repo.root, commit: try headCommit(repo)).get()

        XCTAssertEqual(Set(detail.files), [
            GitChangedFile(kind: .modified, path: "keep.txt"),
            GitChangedFile(kind: .deleted, path: "gone.txt"),
            GitChangedFile(kind: .added, path: "new/file.txt"),
        ])
    }

    func testRenamesKeepBothNames() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let body = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        try repo.write("old name.txt", body)
        try repo.commit("first")
        try FileManager.default.createDirectory(atPath: repo.path("docs"), withIntermediateDirectories: true)
        try repo.git("mv", "old name.txt", "docs/new name.txt")
        try repo.commit("rename")

        let detail = try reader.commitDetail(at: repo.root, commit: try headCommit(repo)).get()

        XCTAssertEqual(detail.files, [GitChangedFile(kind: .renamed, path: "docs/new name.txt", oldPath: "old name.txt")])
    }

    func testCopiesKeepBothNames() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let body = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        try repo.write("source.txt", body)
        try repo.commit("first")
        // A copy is detected from a file changed in the same commit.
        try repo.write("source.txt", body + "\nmore")
        try repo.write("copy.txt", body)
        try repo.commit("copy")

        let detail = try reader.commitDetail(at: repo.root, commit: try headCommit(repo)).get()

        XCTAssertTrue(detail.files.contains(GitChangedFile(kind: .copied, path: "copy.txt", oldPath: "source.txt")), "\(detail.files)")
        XCTAssertTrue(detail.files.contains(GitChangedFile(kind: .modified, path: "source.txt")))
    }

    func testRootCommitListsEverythingAsAdded() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write("a.txt", "a")
        try repo.write("b/c.txt", "c")
        try repo.commit("root")

        let detail = try reader.commitDetail(at: repo.root, commit: try headCommit(repo)).get()

        XCTAssertEqual(Set(detail.files), [GitChangedFile(kind: .added, path: "a.txt"), GitChangedFile(kind: .added, path: "b/c.txt")])
    }

    func testMergeCommitIsComparedWithItsFirstParent() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write("base.txt", "base")
        try repo.commit("base")
        try repo.git("checkout", "-q", "-b", "side")
        try repo.write("side.txt", "side")
        try repo.commit("side")
        try repo.git("checkout", "-q", "main")
        try repo.write("main.txt", "main")
        try repo.commit("main")
        try repo.git("merge", "-q", "--no-ff", "-m", "merge side", "side")

        let merge = try headCommit(repo)
        XCTAssertTrue(merge.isMerge)
        let detail = try reader.commitDetail(at: repo.root, commit: merge).get()

        // Against the first parent (main), the merge brought in side.txt only.
        XCTAssertEqual(detail.files, [GitChangedFile(kind: .added, path: "side.txt")])
    }

    func testPathsWithSpacesQuotesAndNewlines() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.commit("empty start")
        let odd = "dir with space/qu\"ote\nnew line.txt"
        try repo.write(odd, "x")
        try repo.commit("odd")

        let detail = try reader.commitDetail(at: repo.root, commit: try headCommit(repo)).get()

        XCTAssertEqual(detail.files, [GitChangedFile(kind: .added, path: odd)])
    }

    func testFullMultiParagraphMessage() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let message = "feat: subject line\n\nFirst paragraph\nwraps here.\n\n- a bullet\n- another"
        try repo.commit(message)

        let detail = try reader.commitDetail(at: repo.root, commit: try headCommit(repo)).get()

        XCTAssertEqual(detail.message, message)
    }

    func testRepositoryLocationOfAMainCheckoutAndAWorktree() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write("docs/readme.md", "x")
        try repo.commit("first")
        let worktreeParent = try GitTestRepo(initialize: false); defer { worktreeParent.delete() }
        let worktree = worktreeParent.path("wt")
        try repo.git("worktree", "add", "-q", "-b", "wt-branch", worktree)

        let main = try reader.repository(at: repo.path("docs")).get()
        XCTAssertEqual(main.workTree, repo.root)
        XCTAssertEqual(main.gitDirectory, repo.path(".git"))
        XCTAssertEqual(main.commonDirectory, repo.path(".git"))

        let linked = try reader.repository(at: worktree).get()
        XCTAssertEqual(linked.workTree, worktree)
        XCTAssertEqual(linked.gitDirectory, repo.path(".git/worktrees/wt"))
        XCTAssertEqual(linked.commonDirectory, repo.path(".git"))
    }
}
