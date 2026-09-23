import XCTest
@testable import UnpeelNative

@MainActor
final class SidebarSectionLayoutStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "unpeel.sidebarSections.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testFreshDefaultsGiveTheDefaultLayout() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SidebarSectionLayoutStore(defaults: defaults).layout, .default)
    }

    func testUpdatesPersistAcrossInstances() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarSectionLayoutStore(defaults: defaults)
        store.update { $0.settingCollapsed(.explorer, true) }

        XCTAssertFalse(store.layout.isExpanded(.explorer))
        XCTAssertFalse(SidebarSectionLayoutStore(defaults: defaults).layout.isExpanded(.explorer))
    }

    func testUnchangedUpdateWritesNothing() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarSectionLayoutStore(defaults: defaults)
        store.update { $0 }
        XCTAssertNil(defaults.data(forKey: SidebarSectionLayoutStore.layoutKey))
    }

    func testLegacyExplorerColumnKeysAreRemovedAndIgnored() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "unpeel.explorer.visible")
        defaults.set(333.0, forKey: "unpeel.explorer.width")

        let store = SidebarSectionLayoutStore(defaults: defaults)

        XCTAssertTrue(store.layout.isExpanded(.explorer))
        XCTAssertNil(defaults.object(forKey: "unpeel.explorer.visible"))
        XCTAssertNil(defaults.object(forKey: "unpeel.explorer.width"))
    }

    func testCorruptStoredLayoutFallsBackToDefault() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("garbage".utf8), forKey: SidebarSectionLayoutStore.layoutKey)
        XCTAssertEqual(SidebarSectionLayoutStore(defaults: defaults).layout, .default)
    }
}
