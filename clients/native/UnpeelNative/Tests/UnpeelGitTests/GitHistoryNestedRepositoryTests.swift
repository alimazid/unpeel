import Foundation
import XCTest
@testable import UnpeelGit

/// Fork-only: nested repositories. Git History for an Explorer Root that is
/// not a repository: the history of the nested repository chosen in it.
@MainActor
final class GitHistoryNestedRepositoryTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let fake = FakeGitHistory()
    private let finder = FakeNestedFinder()

    override func setUp() async throws {
        suite = "unpeel.git.nested-history-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func local(_ root: String) -> ExplorerContext {
        .local(root: root, projectRoot: root)
    }

    private func makeRepository(_ root: String, prefix: String, branches: [String] = ["main"]) {
        fake.setHead(.success(GitHead(oid: "\(prefix)-2", branch: "main")), for: root)
        fake.setBranches(branches.map(localBranch), for: root)
        fake.setCommits(fakeCommits(3, prefix: prefix), for: root)
        fake.setLocation(
            GitRepositoryLocation(workTree: root, gitDirectory: root + "/.git", commonDirectory: root + "/.git"),
            for: root
        )
    }

    private func makeModel() -> GitHistoryViewModel {
        let hub = GitRepositoryHub(services: fake.hubServices)
        let roots = GitRepositoryRoots(hub: hub, choices: GitRepositoryChoiceStore(defaults: defaults), services: finder.services)
        return GitHistoryViewModel(services: fake.services(sharing: hub, roots: roots), changeDebounce: 0)
    }

    func testALoneNestedRepositoryShowsItsHistory() async {
        finder.set(["/p/app"], in: "/p")
        makeRepository("/p/app", prefix: "app")
        let model = makeModel()

        await model.setContext(local("/p")).value

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.commits.map(\.sha), ["app-2", "app-1", "app-0"])
        XCTAssertEqual(model.root, "/p/app")
        XCTAssertEqual(model.repository?.chosen, "/p/app")
        XCTAssertEqual(model.repository?.isAutomatic, true)
        XCTAssertEqual(Set(fake.logCalls.map(\.root)), ["/p/app"])
    }

    func testSeveralNestedRepositoriesAreOfferedInsteadOfAHistory() async {
        finder.set(["/p/api", "/p/web"], in: "/p")
        makeRepository("/p/api", prefix: "api")
        makeRepository("/p/web", prefix: "web")
        let model = makeModel()

        await model.setContext(local("/p")).value

        XCTAssertEqual(model.status, .notARepository)
        XCTAssertEqual(model.repository?.nested, ["/p/api", "/p/web"])
        XCTAssertNil(model.repository?.chosen)
        XCTAssertTrue(model.commits.isEmpty)
        XCTAssertTrue(fake.logCalls.isEmpty)
    }

    func testChoosingANestedRepositoryShowsAndWatchesIt() async {
        finder.set(["/p/api", "/p/web"], in: "/p")
        makeRepository("/p/api", prefix: "api")
        makeRepository("/p/web", prefix: "web")
        let model = makeModel()
        await model.setContext(local("/p")).value

        await model.chooseRepository("/p/web").value

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.commits.first?.sha, "web-2")
        XCTAssertEqual(model.repository?.chosen, "/p/web")
        XCTAssertEqual(model.location?.workTree, "/p/web")
        XCTAssertTrue(fake.monitors.active.contains { $0.location?.gitDirectory == "/p/web/.git" })
    }

    func testSwitchingRepositoriesStartsTheListOver() async {
        finder.set(["/p/api", "/p/web"], in: "/p")
        makeRepository("/p/api", prefix: "api", branches: ["main", "topic"])
        fake.setCommits(fakeCommits(1, prefix: "topic"), for: "/p/api", scope: .ref("refs/heads/topic"))
        makeRepository("/p/web", prefix: "web")
        let model = makeModel()
        await model.setContext(local("/p")).value
        await model.chooseRepository("/p/api").value
        await model.selectFilter(.branch(localBranch("topic"))).value
        await model.toggleExpanded("topic-0").value

        await model.chooseRepository("/p/web").value

        XCTAssertEqual(model.filter, .checkedOut)
        XCTAssertNil(model.expanded)
        XCTAssertEqual(model.commits.map(\.sha), ["web-2", "web-1", "web-0"])
        XCTAssertEqual(model.branches.map(\.name), ["main"])
        XCTAssertFalse(fake.monitors.active.contains { $0.location?.gitDirectory == "/p/api/.git" })
    }

    /// A branch chosen while the new repository is still being resolved
    /// must not leave the old repository's list behind.
    func testAFilterChosenWhileSwitchingRepositoriesDoesNotKeepTheOldRepository() async throws {
        finder.set(["/p/api", "/p/web"], in: "/p")
        makeRepository("/p/api", prefix: "api", branches: ["main", "topic"])
        fake.setCommits(fakeCommits(1, prefix: "topic"), for: "/p/api", scope: .ref("refs/heads/topic"))
        makeRepository("/p/web", prefix: "web")
        let model = makeModel()
        await model.setContext(local("/p")).value
        await model.chooseRepository("/p/api").value
        finder.setSearchDelay(0.3)

        let switching = model.chooseRepository("/p/web")
        try await Task.sleep(nanoseconds: 50_000_000)
        await model.selectFilter(.branch(localBranch("topic"))).value
        await switching.value

        XCTAssertEqual(model.repository?.chosen, "/p/web")
        XCTAssertEqual(model.filter, .checkedOut)
        XCTAssertEqual(model.commits.map(\.sha), ["web-2", "web-1", "web-0"])
        XCTAssertEqual(model.status, .ready)
    }

    func testChoosingNoneShowsTheFolderAgain() async {
        finder.set(["/p/app"], in: "/p")
        makeRepository("/p/app", prefix: "app")
        let model = makeModel()
        await model.setContext(local("/p")).value

        await model.chooseRepository(nil).value

        XCTAssertEqual(model.status, .notARepository)
        XCTAssertNil(model.repository?.chosen)
        XCTAssertEqual(model.repository?.nested, ["/p/app"])
        XCTAssertNil(model.head)
        XCTAssertTrue(model.commits.isEmpty)
    }

    func testARepositoryRootShowsItsOwnHistoryWithoutASearch() async {
        makeRepository("/repo", prefix: "c")
        let model = makeModel()

        await model.setContext(local("/repo")).value

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.root, "/repo")
        XCTAssertEqual(model.repository?.folder, .repository)
        XCTAssertTrue(finder.searchedFolders.isEmpty)
    }

    func testCollapsingLetsGoOfTheNestedRepositoryAndTheFolder() async {
        finder.set(["/p/app"], in: "/p")
        makeRepository("/p/app", prefix: "app")
        let model = makeModel()
        await model.setContext(local("/p")).value
        XCTAssertFalse(fake.monitors.active.isEmpty)

        model.suspend()

        XCTAssertTrue(fake.monitors.active.isEmpty)
        XCTAssertEqual(model.commits.count, 3)
    }

    func testExpandingAgainSearchesTheFolderAfresh() async {
        finder.set(["/p/app"], in: "/p")
        makeRepository("/p/app", prefix: "app")
        let model = makeModel()
        await model.setContext(local("/p")).value
        model.suspend()

        finder.set(["/p/app", "/p/new"], in: "/p")
        await model.setContext(local("/p")).value

        XCTAssertEqual(model.repository?.nested, ["/p/app", "/p/new"])
        XCTAssertEqual(model.status, .notARepository)
    }

    func testANewExplorerRootForgetsTheRepository() async {
        finder.set(["/p/app"], in: "/p")
        makeRepository("/p/app", prefix: "app")
        makeRepository("/repo", prefix: "c")
        let model = makeModel()
        await model.setContext(local("/p")).value

        await model.setContext(local("/repo")).value

        XCTAssertEqual(model.root, "/repo")
        XCTAssertEqual(model.repository?.folder, .repository)
        XCTAssertEqual(model.commits.first?.sha, "c-2")
    }
}
