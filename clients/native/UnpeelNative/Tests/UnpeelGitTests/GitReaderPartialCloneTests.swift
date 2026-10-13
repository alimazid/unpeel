import XCTest
@testable import UnpeelGit

/// A partial clone lacks file contents until something reads them, and git
/// then fetches them from the remote — a write to the repository. Reads
/// never trigger that fetch; what needs contents does without them.
final class GitReaderPartialCloneTests: XCTestCase {
    private var reader: GitReader!

    override func setUpWithError() throws {
        let git = try XCTUnwrap(GitExecutableResolver.system.resolve())
        reader = GitReader(runner: GitRunner(resolver: GitExecutableResolver { git }))
    }

    /// A source repository whose last commit renames a file and edits it,
    /// so naming it a rename means comparing the two contents.
    private func repositoryWithAnEditedRename() throws -> GitTestRepo {
        let source = try GitTestRepo()
        let body = (0..<40).map { "line \($0)" }.joined(separator: "\n")
        try source.write("old.txt", body)
        try source.commit("first")
        try source.git("mv", "old.txt", "new.txt")
        try source.write("new.txt", body + "\nedited")
        try source.commit("rename and edit")
        return source
    }

    func testCommitDetailFetchesNothingAndListsTheFilesWithoutRenames() throws {
        let source = try repositoryWithAnEditedRename(); defer { source.delete() }
        let clone = try source.partialClone(checkout: false); defer { clone.delete() }
        let objectsBefore = try clone.objectFileCount()
        let commit = try XCTUnwrap(reader.logPage(at: clone.root, scope: .head, offset: 0, limit: 1).get().commits.first)

        let detail = try reader.commitDetail(at: clone.root, commit: commit).get()

        XCTAssertEqual(try clone.objectFileCount(), objectsBefore, "a read fetched objects into the partial clone")
        XCTAssertEqual(detail.message, "rename and edit")
        XCTAssertEqual(Set(detail.files), [
            GitChangedFile(kind: .deleted, path: "old.txt"),
            GitChangedFile(kind: .added, path: "new.txt"),
        ])
    }

    func testCommitDetailStillFindsRenamesWhenTheContentsArePresent() throws {
        let source = try repositoryWithAnEditedRename(); defer { source.delete() }
        let commit = try XCTUnwrap(reader.logPage(at: source.root, scope: .head, offset: 0, limit: 1).get().commits.first)

        let detail = try reader.commitDetail(at: source.root, commit: commit).get()

        XCTAssertEqual(detail.files, [GitChangedFile(kind: .renamed, path: "new.txt", oldPath: "old.txt")])
    }

    func testStatusOfAPartialCloneFetchesNothing() throws {
        let source = try repositoryWithAnEditedRename(); defer { source.delete() }
        let clone = try source.partialClone(checkout: true); defer { clone.delete() }
        try clone.git("mv", "new.txt", "moved.txt")
        try clone.write("untracked.txt", "x")
        let objectsBefore = try clone.objectFileCount()

        let status = try reader.status(at: clone.root).get()

        XCTAssertEqual(try clone.objectFileCount(), objectsBefore, "a read fetched objects into the partial clone")
        XCTAssertEqual(status.head.branch, "main")
        XCTAssertEqual(status.entries, [
            GitStatusEntry(path: "moved.txt", originalPath: "new.txt", kind: .renamed),
            GitStatusEntry(path: "untracked.txt", kind: .untracked),
        ])
    }
}
