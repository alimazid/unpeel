import Foundation
import XCTest
@testable import UnpeelGit

/// Fork-only: nested repositories. The repository chosen for each Explorer
/// Root, remembered across launches.
@MainActor
final class GitRepositoryChoiceStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "unpeel.git.choice-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNothingIsChosenAtFirst() {
        XCTAssertNil(GitRepositoryChoiceStore(defaults: defaults).choice(forRoot: "/p"))
    }

    func testAChoiceIsRememberedPerRootAcrossStores() {
        GitRepositoryChoiceStore(defaults: defaults).save(.repository("web"), forRoot: "/p")
        GitRepositoryChoiceStore(defaults: defaults).save(.folder, forRoot: "/q")

        let store = GitRepositoryChoiceStore(defaults: defaults)

        XCTAssertEqual(store.choice(forRoot: "/p"), .repository("web"))
        XCTAssertEqual(store.choice(forRoot: "/q"), .folder)
        XCTAssertNil(store.choice(forRoot: "/r"))
    }

    func testANewChoiceReplacesTheOld() {
        let store = GitRepositoryChoiceStore(defaults: defaults)
        store.save(.repository("web"), forRoot: "/p")

        store.save(.repository("api"), forRoot: "/p")

        XCTAssertEqual(store.choice(forRoot: "/p"), .repository("api"))
    }

    func testOnlyTheMostRecentlyUsedRootsAreKept() {
        let store = GitRepositoryChoiceStore(defaults: defaults)
        for index in 0...GitRepositoryChoiceStore.maxRoots {
            store.save(.folder, forRoot: "/p\(index)", now: Date(timeIntervalSince1970: TimeInterval(index)))
        }

        XCTAssertNil(store.choice(forRoot: "/p0"))
        XCTAssertEqual(store.choice(forRoot: "/p\(GitRepositoryChoiceStore.maxRoots)"), .folder)
    }
}
