import XCTest
@testable import UnpeelExplorer

@MainActor
final class ExplorerStateStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "unpeel.explorer.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testRoundTripsStatePerRoot() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = RootViewState(expanded: ["/r/a", "/r/a/b"], selection: ["/r/a/b/c.txt"], scrollOffset: 42)

        ExplorerStateStore(defaults: defaults).save(state, forRoot: "/r")

        let reopened = ExplorerStateStore(defaults: defaults)
        XCTAssertEqual(reopened.state(forRoot: "/r"), state)
        XCTAssertNil(reopened.state(forRoot: "/other"))
    }

    func testKeepsOnlyTheMostRecentlyUsedRoots() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExplorerStateStore(defaults: defaults)
        let empty = RootViewState(expanded: [], selection: [], scrollOffset: 0)

        for index in 0..<(ExplorerStateStore.maxRoots + 5) {
            store.save(empty, forRoot: "/r\(index)", now: Date(timeIntervalSince1970: Double(index)))
        }

        XCTAssertNil(store.state(forRoot: "/r0"))
        XCTAssertNil(store.state(forRoot: "/r4"))
        XCTAssertNotNil(store.state(forRoot: "/r5"))
        XCTAssertNotNil(store.state(forRoot: "/r\(ExplorerStateStore.maxRoots + 4)"))
    }

    func testFilterDefaultsOffAndPersists() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExplorerStateStore(defaults: defaults)

        XCTAssertEqual(store.filter, VisibilityFilter(showHidden: false, showIgnored: false))
        store.filter = VisibilityFilter(showHidden: true, showIgnored: false)

        XCTAssertEqual(ExplorerStateStore(defaults: defaults).filter, VisibilityFilter(showHidden: true, showIgnored: false))
    }

    func testCorruptStoredDataIsTreatedAsEmpty() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "unpeel.explorer.roots")

        XCTAssertNil(ExplorerStateStore(defaults: defaults).state(forRoot: "/r"))
    }
}
