import XCTest
@testable import UnpeelGit

final class GitReaderHeadTests: XCTestCase {
    private var reader: GitReader!

    override func setUpWithError() throws {
        let git = try XCTUnwrap(GitExecutableResolver.system.resolve())
        reader = GitReader(runner: GitRunner(resolver: GitExecutableResolver { git }))
    }

    /// A repo with one pushed commit on `main` tracking `origin/main`, plus
    /// a second clone of the same origin for making "someone else pushed".
    private func trackedRepo() throws -> (local: GitTestRepo, origin: GitTestRepo, other: GitTestRepo) {
        let local = try GitTestRepo()
        try local.write("a.txt", "a")
        try local.commit("first")
        let origin = try local.addBareOrigin()
        try local.git("push", "-q", "-u", "origin", "main")
        let other = try GitTestRepo(initialize: false)
        try other.git("clone", "-q", origin.root, ".")
        return (local, origin, other)
    }

    private func pushFromOther(_ other: GitTestRepo, _ message: String) throws {
        try other.write("\(UUID().uuidString).txt", message)
        try other.commit(message)
        try other.git("push", "-q", "origin", "main")
    }

    func testBranchInSyncWithUpstream() throws {
        let (local, origin, other) = try trackedRepo()
        defer { [local, origin, other].forEach { $0.delete() } }

        let head = try reader.status(at: local.root).map(\.head).get()

        XCTAssertEqual(head.branch, "main")
        XCTAssertEqual(head.upstream, "origin/main")
        XCTAssertEqual(head.ahead, 0)
        XCTAssertEqual(head.behind, 0)
        XCTAssertEqual(head.oid, try local.output("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(head.displayName, "main")
    }

    func testAheadOnly() throws {
        let (local, origin, other) = try trackedRepo()
        defer { [local, origin, other].forEach { $0.delete() } }
        try local.write("b.txt", "b"); try local.commit("second")
        try local.write("c.txt", "c"); try local.commit("third")

        let head = try reader.status(at: local.root).map(\.head).get()

        XCTAssertEqual(head.ahead, 2)
        XCTAssertEqual(head.behind, 0)
    }

    func testBehindOnlyAsOfTheLastFetch() throws {
        let (local, origin, other) = try trackedRepo()
        defer { [local, origin, other].forEach { $0.delete() } }
        try pushFromOther(other, "theirs")

        // Nothing fetched yet: the reader never fetches, so it cannot know.
        XCTAssertEqual(try reader.status(at: local.root).map(\.head).get().behind, 0)

        try local.git("fetch", "-q")
        let head = try reader.status(at: local.root).map(\.head).get()
        XCTAssertEqual(head.ahead, 0)
        XCTAssertEqual(head.behind, 1)
    }

    func testDiverged() throws {
        let (local, origin, other) = try trackedRepo()
        defer { [local, origin, other].forEach { $0.delete() } }
        try pushFromOther(other, "theirs")
        try local.git("fetch", "-q")
        try local.write("mine.txt", "mine"); try local.commit("mine")

        let head = try reader.status(at: local.root).map(\.head).get()

        XCTAssertEqual(head.ahead, 1)
        XCTAssertEqual(head.behind, 1)
    }

    func testBranchWithoutUpstreamHasNoCounts() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.commit("first")
        try repo.git("checkout", "-q", "-b", "feature/x")

        let head = try reader.status(at: repo.root).map(\.head).get()

        XCTAssertEqual(head.branch, "feature/x")
        XCTAssertNil(head.upstream)
        XCTAssertNil(head.ahead)
        XCTAssertNil(head.behind)
    }

    func testDetachedHeadUsesTheWorktreeMarker() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let sha = try repo.commit("first")
        try repo.git("checkout", "-q", "--detach")

        let head = try reader.status(at: repo.root).map(\.head).get()

        XCTAssertNil(head.branch)
        XCTAssertTrue(head.isDetached)
        XCTAssertEqual(head.oid, sha)
        XCTAssertEqual(head.displayName, "detached@\(sha.prefix(12))")
        XCTAssertNil(head.ahead)
    }

    func testEmptyRepositoryHasABranchButNoCommits() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }

        let head = try reader.status(at: repo.root).map(\.head).get()

        XCTAssertEqual(head.branch, "main")
        XCTAssertNil(head.oid)
        XCTAssertFalse(head.hasCommits)
    }

    func testSubdirectoryOfARepositoryReadsTheRepository() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write("docs/readme.md", "x")
        try repo.commit("first")

        XCTAssertEqual(try reader.status(at: repo.path("docs")).map(\.head).get().branch, "main")
    }

    func testNotARepository() throws {
        let plain = try GitTestRepo(initialize: false); defer { plain.delete() }

        XCTAssertEqual(reader.status(at: plain.root).map(\.head), .failure(.notARepository))
    }

    func testGitUnavailable() {
        let reader = GitReader(runner: GitRunner(resolver: GitExecutableResolver { nil }))

        XCTAssertEqual(reader.status(at: "/tmp").map(\.head), .failure(.gitUnavailable))
    }

    func testParsesPorcelainHeaders() {
        let raw = "# branch.oid abc\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +3 -4\0"
        XCTAssertEqual(
            GitHead.parse(porcelainV2: Data(raw.utf8)),
            GitHead(oid: "abc", branch: "main", upstream: "origin/main", ahead: 3, behind: 4)
        )
        // Upstream configured but gone: no `branch.ab` line, so no counts.
        let gone = "# branch.oid abc\0# branch.head main\0# branch.upstream origin/gone\0"
        XCTAssertEqual(
            GitHead.parse(porcelainV2: Data(gone.utf8)),
            GitHead(oid: "abc", branch: "main", upstream: "origin/gone", ahead: nil, behind: nil)
        )
        let initial = "# branch.oid (initial)\0# branch.head main\0"
        XCTAssertEqual(GitHead.parse(porcelainV2: Data(initial.utf8)), GitHead(oid: nil, branch: "main"))
        let detached = "# branch.oid abc\0# branch.head (detached)\0"
        XCTAssertEqual(GitHead.parse(porcelainV2: Data(detached.utf8)), GitHead(oid: "abc", branch: nil))
    }
}
