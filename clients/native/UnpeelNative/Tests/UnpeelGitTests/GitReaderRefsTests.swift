import XCTest
@testable import UnpeelGit

final class GitReaderRefsTests: XCTestCase {
    private var reader: GitReader!

    override func setUpWithError() throws {
        let git = try XCTUnwrap(GitExecutableResolver.system.resolve())
        reader = GitReader(runner: GitRunner(resolver: GitExecutableResolver { git }))
    }

    func testLocalBranchesThenRemoteTrackingBranchesEachInNameOrder() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.commit("first")
        try repo.git("branch", "zeta")
        try repo.git("branch", "alpha/topic")
        try repo.git("tag", "v1")
        let origin = try repo.addBareOrigin(); defer { origin.delete() }
        try repo.git("push", "-q", "origin", "main", "zeta")
        try repo.git("fetch", "-q", "origin")
        // `origin/HEAD` is a symref: never a choice of its own.
        try repo.git("remote", "set-head", "origin", "main")

        let refs = try reader.branches(at: repo.root).get()

        XCTAssertEqual(refs.map(\.name), ["alpha/topic", "main", "zeta", "origin/main", "origin/zeta"])
        XCTAssertEqual(refs.map(\.kind), [.localBranch, .localBranch, .localBranch, .remoteBranch, .remoteBranch])
        XCTAssertEqual(refs[1].fullName, "refs/heads/main")
        XCTAssertEqual(refs[3].fullName, "refs/remotes/origin/main")
    }

    func testEmptyRepositoryHasNoBranches() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }

        XCTAssertEqual(try reader.branches(at: repo.root).get(), [])
    }

    func testNotARepository() throws {
        let plain = try GitTestRepo(initialize: false); defer { plain.delete() }

        XCTAssertEqual(reader.branches(at: plain.root), .failure(.notARepository))
    }

    func testAllBranchesIncludesOtherBranchesByDate() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let base = try repo.commit("base", date: 1_700_000_000)
        try repo.git("checkout", "-q", "-b", "side")
        let side = try repo.commit("side work", date: 1_700_000_200)
        try repo.git("checkout", "-q", "main")
        let main = try repo.commit("main work", date: 1_700_000_100)
        let origin = try repo.addBareOrigin(); defer { origin.delete() }
        try repo.git("checkout", "-q", "-b", "pushed-only", base)
        let pushed = try repo.commit("pushed only", date: 1_700_000_300)
        try repo.git("push", "-q", "origin", "pushed-only")
        try repo.git("checkout", "-q", "main")
        try repo.git("branch", "-D", "pushed-only")
        try repo.git("fetch", "-q", "origin")

        let head = try reader.logPage(at: repo.root, scope: .head, offset: 0, limit: 10).get()
        let all = try reader.logPage(at: repo.root, scope: .allBranches, offset: 0, limit: 10).get()

        XCTAssertEqual(head.commits.map(\.sha), [main, base])
        XCTAssertEqual(all.commits.map(\.sha), [pushed, side, main, base])
    }
}
