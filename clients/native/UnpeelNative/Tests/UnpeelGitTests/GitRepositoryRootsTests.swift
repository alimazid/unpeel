import Foundation
import XCTest
@testable import UnpeelGit

/// Fork-only: nested repositories. Which repository an Explorer Root's git
/// views read: its own, or — in a folder that is not one — a nested one,
/// chosen by the user or, when it is the only one, automatically.
@MainActor
final class GitRepositoryRootsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "unpeel.git.roots-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        holds.forEach { $0.cancel() }
        holds = []
        defaults.removePersistentDomain(forName: suite)
    }

    private var holds: [GitRepositorySubscription] = []

    /// Follows `root` for the rest of the test, the way a view does before
    /// it offers a choice, and resolves it.
    private func followed(_ roots: GitRepositoryRoots, _ root: String) async -> GitRepositoryRootState {
        holds.append(roots.subscribe(explorerRoot: root))
        return await roots.resolve(explorerRoot: root)
    }

    private let fake = FakeGitHistory()
    private let finder = FakeNestedFinder()

    private func makeRoots(hub: GitRepositoryHub? = nil) -> GitRepositoryRoots {
        GitRepositoryRoots(
            hub: hub ?? GitRepositoryHub(services: fake.hubServices),
            choices: GitRepositoryChoiceStore(defaults: defaults),
            services: finder.services
        )
    }

    private func makeRepository(_ root: String) {
        fake.setHead(.success(GitHead(oid: "c-0", branch: "main")), for: root)
    }

    func testARepositoryReadsItselfAndIsNotSearched() async {
        makeRepository("/repo")
        let roots = makeRoots()

        let state = await roots.resolve(explorerRoot: "/repo")

        XCTAssertEqual(state.folder, .repository)
        XCTAssertEqual(state.repositoryRoot, "/repo")
        XCTAssertNil(state.chosen)
        XCTAssertFalse(state.canChoose)
        XCTAssertTrue(finder.searchedFolders.isEmpty)
    }

    func testALoneNestedRepositoryIsChosenAutomatically() async {
        finder.set(["/p/app"], in: "/p")
        let roots = makeRoots()

        let state = await roots.resolve(explorerRoot: "/p")

        XCTAssertEqual(state.folder, .notARepository)
        XCTAssertEqual(state.nested, ["/p/app"])
        XCTAssertEqual(state.chosen, "/p/app")
        XCTAssertTrue(state.isAutomatic)
        XCTAssertEqual(state.repositoryRoot, "/p/app")
        XCTAssertTrue(state.canChoose)
    }

    func testSeveralNestedRepositoriesWaitForAChoice() async {
        finder.set(["/p/api", "/p/web"], in: "/p")
        let roots = makeRoots()

        let state = await roots.resolve(explorerRoot: "/p")

        XCTAssertEqual(state.nested, ["/p/api", "/p/web"])
        XCTAssertNil(state.chosen)
        XCTAssertEqual(state.repositoryRoot, "/p")
    }

    func testAFolderWithoutNestedRepositoriesReadsItself() async {
        let roots = makeRoots()

        let state = await roots.resolve(explorerRoot: "/p")

        XCTAssertEqual(state.folder, .notARepository)
        XCTAssertEqual(state.nested, [])
        XCTAssertEqual(state.repositoryRoot, "/p")
    }

    func testWithoutGitNothingIsSearched() async {
        fake.setHead(.failure(.gitUnavailable), for: "/p")
        finder.set(["/p/app"], in: "/p")
        let roots = makeRoots()

        let state = await roots.resolve(explorerRoot: "/p")

        XCTAssertEqual(state.folder, .unknown)
        XCTAssertEqual(state.repositoryRoot, "/p")
        XCTAssertTrue(finder.searchedFolders.isEmpty)
    }

    func testAChoiceIsUsedAndRememberedAcrossLaunches() async {
        finder.set(["/p/api", "/p/web"], in: "/p")
        let roots = makeRoots()
        _ = await followed(roots, "/p")

        XCTAssertTrue(roots.choose("/p/web", in: "/p"))
        let state = await roots.resolve(explorerRoot: "/p")
        let relaunched = await makeRoots().resolve(explorerRoot: "/p")

        XCTAssertEqual(state.chosen, "/p/web")
        XCTAssertFalse(state.isAutomatic)
        XCTAssertEqual(relaunched.chosen, "/p/web")
    }

    func testChoosingNoneStopsTheAutomaticChoice() async {
        finder.set(["/p/app"], in: "/p")
        let roots = makeRoots()
        _ = await followed(roots, "/p")

        XCTAssertTrue(roots.choose(nil, in: "/p"))
        let state = await roots.resolve(explorerRoot: "/p")

        XCTAssertNil(state.chosen)
        XCTAssertEqual(state.repositoryRoot, "/p")
        XCTAssertEqual(state.nested, ["/p/app"])
    }

    /// A repository deeper than the search goes, chosen from the EXPLORER,
    /// is offered alongside the ones found.
    func testADeeperRepositoryCanBeChosenAndIsListed() async {
        finder.set(["/p/web"], in: "/p")
        finder.addRepository("/p/a/b/deep")
        let roots = makeRoots()
        _ = await followed(roots, "/p")

        XCTAssertTrue(roots.choose("/p/a/b/deep", in: "/p"))
        let state = await roots.resolve(explorerRoot: "/p")

        XCTAssertEqual(state.chosen, "/p/a/b/deep")
        XCTAssertEqual(state.nested, ["/p/a/b/deep", "/p/web"])
    }

    func testAChosenRepositoryThatIsGoneFallsBack() async {
        finder.set(["/p/api", "/p/web"], in: "/p")
        let roots = makeRoots()
        _ = await followed(roots, "/p")
        XCTAssertTrue(roots.choose("/p/web", in: "/p"))

        finder.set(["/p/api"], in: "/p")
        let state = await makeRoots().resolve(explorerRoot: "/p")

        XCTAssertEqual(state.chosen, "/p/api")
        XCTAssertTrue(state.isAutomatic)
    }

    func testOnlyRepositoriesInsideTheFolderCanBeChosen() async {
        finder.set(["/p/app"], in: "/p")
        finder.addRepository("/elsewhere")
        let roots = makeRoots()
        _ = await followed(roots, "/p")

        XCTAssertFalse(roots.choose("/elsewhere", in: "/p"))
        XCTAssertFalse(roots.choose("/p", in: "/p"))
        XCTAssertFalse(roots.choose("/p/plain", in: "/p"))
        XCTAssertFalse(roots.choose("/pother/app", in: "/p"))
    }

    func testAnUnfollowedFolderOffersNoChoice() async {
        finder.set(["/p/api", "/p/web"], in: "/p")
        let roots = makeRoots()
        _ = await roots.resolve(explorerRoot: "/p")

        XCTAssertFalse(roots.choose("/p/web", in: "/p"))
    }

    func testARepositoryRootOffersNoChoice() async {
        makeRepository("/repo")
        finder.addRepository("/repo/vendor")
        let roots = makeRoots()
        _ = await followed(roots, "/repo")

        XCTAssertFalse(roots.choose("/repo/vendor", in: "/repo"))
        let state = await roots.resolve(explorerRoot: "/repo")
        XCTAssertEqual(state.repositoryRoot, "/repo")
    }

    func testAChoiceTellsTheFolderSubscribers() async {
        finder.set(["/p/api", "/p/web"], in: "/p")
        let roots = makeRoots()
        var heard = 0
        let subscription = roots.subscribe(explorerRoot: "/p") { heard += 1 }
        defer { subscription.cancel() }
        _ = await roots.resolve(explorerRoot: "/p")

        roots.choose("/p/web", in: "/p")

        XCTAssertEqual(heard, 1)
    }

    func testAFollowedFolderIsSearchedOnceUntilItChanges() async {
        finder.set(["/p/app"], in: "/p")
        let roots = makeRoots()
        let subscription = roots.subscribe(explorerRoot: "/p")
        defer { subscription.cancel() }

        async let first = roots.resolve(explorerRoot: "/p")
        async let second = roots.resolve(explorerRoot: "/p")
        _ = await (first, second)
        _ = await roots.resolve(explorerRoot: "/p")

        XCTAssertEqual(finder.searchedFolders, ["/p"])
    }

    func testFollowingAgainSearchesAfresh() async {
        finder.set(["/p/app"], in: "/p")
        let roots = makeRoots()
        let first = roots.subscribe(explorerRoot: "/p")
        _ = await roots.resolve(explorerRoot: "/p")
        first.cancel()

        finder.set(["/p/app", "/p/new"], in: "/p")
        let second = roots.subscribe(explorerRoot: "/p")
        defer { second.cancel() }
        let state = await roots.resolve(explorerRoot: "/p")

        XCTAssertEqual(state.nested, ["/p/app", "/p/new"])
        XCTAssertNil(state.chosen)
    }

    /// `git init` in the folder itself: its own repository wins from then on.
    func testAFolderBecomingARepositoryStopsUsingTheNestedOne() async {
        finder.set(["/p/app"], in: "/p")
        let roots = makeRoots()
        var heard = 0
        let subscription = roots.subscribe(explorerRoot: "/p") { heard += 1 }
        defer { subscription.cancel() }
        _ = await roots.resolve(explorerRoot: "/p")
        let folderWatch = try? XCTUnwrap(fake.monitors.active.first { $0.folder == "/p" })

        makeRepository("/p")
        folderWatch?.handler()
        await waitUntil { heard > 0 }
        let state = await roots.resolve(explorerRoot: "/p")

        XCTAssertEqual(heard, 1)
        XCTAssertEqual(state.folder, .repository)
        XCTAssertEqual(state.repositoryRoot, "/p")
    }

    func testRelativeNames() async {
        finder.set(["/p/api", "/p/services/billing"], in: "/p")
        let state = await makeRoots().resolve(explorerRoot: "/p")

        XCTAssertEqual(state.name(of: "/p/services/billing"), "services/billing")
        XCTAssertEqual(state.name(of: "/p/api"), "api")
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
