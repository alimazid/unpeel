import XCTest
@testable import UnpeelGit

/// The status read behind Git Status Decorations (and Git History's
/// header), against real throwaway repositories.
final class GitReaderStatusTests: XCTestCase {
    private var reader: GitReader!

    override func setUpWithError() throws {
        let git = try XCTUnwrap(GitExecutableResolver.system.resolve())
        reader = GitReader(runner: GitRunner(resolver: GitExecutableResolver { git }))
    }

    private func committedRepo(_ files: [String: String]) throws -> GitTestRepo {
        let repo = try GitTestRepo()
        for (path, contents) in files { try repo.write(path, contents) }
        try repo.commit("first")
        return repo
    }

    private func kinds(_ status: GitStatus) -> [String: GitChangeKind] {
        Dictionary(status.entries.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    private func entry(_ status: GitStatus, _ path: String) -> GitStatusEntry? {
        status.entries.first { $0.path == path }
    }

    func testACleanTreeHasNoEntriesAndItsHead() throws {
        let repo = try committedRepo(["a.txt": "a"]); defer { repo.delete() }

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(status.entries, [])
        XCTAssertEqual(status.head.branch, "main")
        XCTAssertEqual(status.head.oid, try repo.output("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testEachSingleState() throws {
        let repo = try committedRepo(["edited.txt": "1", "gone.txt": "2", "unstaged-gone.txt": "3", "staged-edit.txt": "4"])
        defer { repo.delete() }
        try repo.write("edited.txt", "changed")
        try repo.git("rm", "-q", "gone.txt")
        try repo.remove("unstaged-gone.txt")
        try repo.write("staged-edit.txt", "changed"); try repo.git("add", "staged-edit.txt")
        try repo.write("added.txt", "new"); try repo.git("add", "added.txt")
        try repo.write("loose.txt", "untracked")

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(kinds(status), [
            "edited.txt": .modified,
            "gone.txt": .deleted,
            "unstaged-gone.txt": .deleted,
            "staged-edit.txt": .modified,
            "added.txt": .added,
            "loose.txt": .untracked,
        ])
    }

    /// git lists a folder holding only untracked files once, as the folder.
    func testAnUntrackedFolderIsOneDirectoryEntry() throws {
        let repo = try committedRepo(["a.txt": "a"]); defer { repo.delete() }
        try repo.write("fresh/deep/one.txt", "1")
        try repo.write("fresh/two.txt", "2")

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(status.entries, [GitStatusEntry(path: "fresh", kind: .untracked, isDirectory: true)])
    }

    /// Staged and unstaged changes to one file become one letter:
    /// conflict > deleted > modified > type change > renamed > copied >
    /// added > untracked.
    func testStagedAndUnstagedChangesCombineByPrecedence() throws {
        let repo = try committedRepo(["to-rename.txt": String(repeating: "line\n", count: 20), "edit-then-delete.txt": "x"])
        defer { repo.delete() }
        try repo.write("add-then-edit.txt", "1"); try repo.git("add", "add-then-edit.txt")
        try repo.write("add-then-edit.txt", "2")
        try repo.write("add-then-delete.txt", "1"); try repo.git("add", "add-then-delete.txt")
        try repo.remove("add-then-delete.txt")
        try repo.write("edit-then-delete.txt", "y"); try repo.git("add", "edit-then-delete.txt")
        try repo.remove("edit-then-delete.txt")
        try repo.git("mv", "to-rename.txt", "renamed.txt")
        try repo.write("renamed.txt", String(repeating: "line\n", count: 20) + "more\n")

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(kinds(status), [
            "add-then-edit.txt": .modified,
            "add-then-delete.txt": .deleted,
            "edit-then-delete.txt": .deleted,
            "renamed.txt": .modified,
        ])
        XCTAssertEqual(entry(status, "renamed.txt")?.originalPath, "to-rename.txt")
    }

    func testARenameCarriesItsOriginalPath() throws {
        let repo = try committedRepo(["docs/old name.md": "hello\n"]); defer { repo.delete() }
        try repo.git("mv", "docs/old name.md", "docs/new name.md")

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(status.entries, [
            GitStatusEntry(path: "docs/new name.md", originalPath: "docs/old name.md", kind: .renamed),
        ])
    }

    /// Copies are reported only when the repository asks for copy
    /// detection; the record then carries its source.
    func testACopyCarriesItsOriginalPath() throws {
        let numbers = (1...50).map(String.init).joined(separator: "\n") + "\n"
        let repo = try committedRepo(["a.txt": numbers]); defer { repo.delete() }
        try repo.git("config", "status.renames", "copies")
        try repo.write("b.txt", numbers)
        try repo.write("a.txt", numbers + "51\n")
        try repo.git("add", "-A")

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(entry(status, "b.txt"), GitStatusEntry(path: "b.txt", originalPath: "a.txt", kind: .copied))
        XCTAssertEqual(entry(status, "a.txt")?.kind, .modified)
    }

    func testAMergeConflictIsConflicted() throws {
        let repo = try committedRepo(["base.txt": "base"]); defer { repo.delete() }
        try repo.git("checkout", "-q", "-b", "other")
        try repo.write("both.txt", "theirs"); try repo.commit("theirs")
        try repo.git("checkout", "-q", "main")
        try repo.write("both.txt", "ours"); try repo.commit("ours")
        try repo.git(["merge", "-q", "other"], allowFailure: true)

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(kinds(status), ["both.txt": .conflicted])
    }

    func testAFileReplacedByALinkIsATypeChange() throws {
        let repo = try committedRepo(["target.txt": "t", "link": "was a file"]); defer { repo.delete() }
        try repo.remove("link")
        try FileManager.default.createSymbolicLink(atPath: repo.path("link"), withDestinationPath: "target.txt")

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(kinds(status), ["link": .typeChanged])
    }

    func testPathsWithSpacesQuotesAndNewlines() throws {
        let repo = try committedRepo(["a.txt": "a"]); defer { repo.delete() }
        let names = ["with space.txt", "qu\"ote.txt", "new\nline.txt", "tab\there.txt"]
        for name in names { try repo.write(name, "x") }

        let status = try reader.status(at: repo.root).get()

        XCTAssertEqual(Set(status.entries.map(\.path)), Set(names))
        XCTAssertTrue(status.entries.allSatisfy { $0.kind == .untracked })
    }

    /// From a folder inside the repository only that folder's changes are
    /// read; paths stay relative to the work tree.
    func testASubfolderRootReadsItsOwnSubtree() throws {
        let repo = try committedRepo(["app/main.swift": "1", "other/readme.md": "2"]); defer { repo.delete() }
        try repo.write("app/main.swift", "changed")
        try repo.write("other/readme.md", "changed")

        let status = try reader.status(at: repo.path("app")).get()

        XCTAssertEqual(kinds(status), ["app/main.swift": .modified])
        XCTAssertEqual(status.head.branch, "main")
    }

    func testAnEmptyRepositoryHasAHeadWithoutCommits() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write("first.txt", "1")

        let status = try reader.status(at: repo.root).get()

        XCTAssertFalse(status.head.hasCommits)
        XCTAssertEqual(kinds(status), ["first.txt": .untracked])
    }

    func testNotARepository() throws {
        let folder = try GitTestRepo(initialize: false); defer { folder.delete() }

        XCTAssertEqual(reader.status(at: folder.root).failure, .notARepository)
    }

    func testGitUnavailable() throws {
        let folder = try GitTestRepo(initialize: false); defer { folder.delete() }
        let reader = GitReader(runner: GitRunner(resolver: GitExecutableResolver { nil }))

        XCTAssertEqual(reader.status(at: folder.root).failure, .gitUnavailable)
    }

    func testPrecedenceOrder() {
        let ordered: [GitChangeKind] = [.conflicted, .deleted, .modified, .typeChanged, .renamed, .copied, .added, .untracked]
        for (index, kind) in ordered.enumerated() {
            for weaker in ordered.dropFirst(index + 1) {
                XCTAssertEqual(GitChangeKind.strongest(kind, weaker), kind, "\(kind) over \(weaker)")
                XCTAssertEqual(GitChangeKind.strongest(weaker, kind), kind, "\(kind) over \(weaker)")
            }
        }
        XCTAssertEqual(Set(ordered), Set(GitChangeKind.allCases))
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
