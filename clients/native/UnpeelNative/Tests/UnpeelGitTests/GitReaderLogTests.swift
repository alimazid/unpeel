import XCTest
@testable import UnpeelGit

final class GitReaderLogTests: XCTestCase {
    private var reader: GitReader!

    override func setUpWithError() throws {
        let git = try XCTUnwrap(GitExecutableResolver.system.resolve())
        reader = GitReader(runner: GitRunner(resolver: GitExecutableResolver { git }))
    }

    /// `count` commits one minute apart, oldest first; returns their SHAs
    /// newest first (the order the log lists them).
    private func commits(_ count: Int, in repo: GitTestRepo, start: Int = 1_700_000_000) throws -> [String] {
        var shas: [String] = []
        for index in 0..<count {
            shas.append(try repo.commit("commit \(index)", date: start + index * 60))
        }
        return shas.reversed()
    }

    func testFirstPageListsNewestFirstWithEveryField() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let first = try repo.commit("first subject", date: 1_700_000_000, author: "Ada Lovelace")
        let second = try repo.commit("second subject\n\nbody line", date: 1_700_000_600, author: "Grace Hopper")

        let page = try reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 200).get()

        XCTAssertEqual(page.commits.map(\.sha), [second, first])
        XCTAssertFalse(page.hasMore)
        let top = page.commits[0]
        XCTAssertEqual(top.subject, "second subject")
        XCTAssertEqual(top.author, "Grace Hopper")
        XCTAssertEqual(top.date, Date(timeIntervalSince1970: 1_700_000_600))
        XCTAssertEqual(top.parents, [first])
        XCTAssertEqual(page.commits[1].parents, [])
    }

    func testExactlyOnePageHasNoMore() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let shas = try commits(3, in: repo)

        let page = try reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 3).get()

        XCTAssertEqual(page.commits.map(\.sha), shas)
        XCTAssertFalse(page.hasMore)
    }

    func testOneMoreThanAPageHasMoreAndTheNextPageHoldsIt() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let shas = try commits(4, in: repo)

        let first = try reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 3).get()
        let second = try reader.logPage(at: repo.root, scope: .head, offset: 3, limit: 3).get()

        XCTAssertEqual(first.commits.map(\.sha), Array(shas.prefix(3)))
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.commits.map(\.sha), [shas[3]])
        XCTAssertFalse(second.hasMore)
    }

    func testOffsetPastTheEndIsAnEmptyPage() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        _ = try commits(2, in: repo)

        let page = try reader.logPage(at: repo.root, scope: .head, offset: 5, limit: 3).get()

        XCTAssertEqual(page, GitLogPage(commits: [], hasMore: false))
    }

    func testTagsBranchesAndHeadAreLabels() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let old = try repo.commit("old", date: 1_700_000_000)
        try repo.git("tag", "v1.0", old)
        try repo.git("tag", "-a", "v1.1", "-m", "annotated", old)
        try repo.git("branch", "feature/x", old)
        let tip = try repo.commit("tip", date: 1_700_000_100)

        let page = try reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 10).get()
        let byID = Dictionary(uniqueKeysWithValues: page.commits.map { ($0.sha, $0) })

        XCTAssertTrue(try XCTUnwrap(byID[tip]).isHead)
        XCTAssertEqual(byID[tip]?.refs, [GitRefLabel(kind: .head, name: "HEAD"), GitRefLabel(kind: .localBranch, name: "main")])
        XCTAssertFalse(try XCTUnwrap(byID[old]).isHead)
        XCTAssertEqual(
            Set(byID[old]?.refs ?? []),
            [GitRefLabel(kind: .tag, name: "v1.0"), GitRefLabel(kind: .tag, name: "v1.1"), GitRefLabel(kind: .localBranch, name: "feature/x")]
        )
    }

    func testDetachedHeadIsMarkedHead() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let first = try repo.commit("first", date: 1_700_000_000)
        try repo.commit("second", date: 1_700_000_100)
        try repo.git("checkout", "-q", first)

        let page = try reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 10).get()

        XCTAssertEqual(page.commits.map(\.sha), [first])
        XCTAssertTrue(page.commits[0].isHead)
        XCTAssertEqual(page.commits[0].refs.first, GitRefLabel(kind: .head, name: "HEAD"))
    }

    func testRemoteBranchesAreLabelsButOriginHeadIsNot() {
        let decoration = "HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v2, refs/stash"
        XCTAssertEqual(GitRefLabel.parse(decoration: decoration), [
            GitRefLabel(kind: .head, name: "HEAD"),
            GitRefLabel(kind: .localBranch, name: "main"),
            GitRefLabel(kind: .remoteBranch, name: "origin/main"),
            GitRefLabel(kind: .tag, name: "v2"),
        ])
        XCTAssertEqual(GitRefLabel.parse(decoration: ""), [])
    }

    func testSubjectsWithOddCharactersSurvive() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let subject = "fix: \"quotes\", tabs\tand ünïcödé — plus a, comma"
        try repo.commit(subject)

        let page = try reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 10).get()

        XCTAssertEqual(page.commits.first?.subject, subject)
    }

    func testRefScopeListsThatBranchOnly() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let base = try repo.commit("base", date: 1_700_000_000)
        try repo.git("checkout", "-q", "-b", "topic")
        let topic = try repo.commit("topic work", date: 1_700_000_100)
        try repo.git("checkout", "-q", "main")

        let head = try reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 10).get()
        let topicPage = try reader.logPage(at: repo.root, scope: .ref("refs/heads/topic"), offset: 0, limit: 10).get()

        XCTAssertEqual(head.commits.map(\.sha), [base])
        XCTAssertEqual(topicPage.commits.map(\.sha), [topic, base])
    }

    func testNotARepository() throws {
        let plain = try GitTestRepo(initialize: false); defer { plain.delete() }

        XCTAssertEqual(reader.logPage(at: plain.root, scope: .head, offset: 0, limit: 10), .failure(.notARepository))
    }
}
