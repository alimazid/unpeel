import XCTest
@testable import UnpeelNative

@MainActor
final class ExplorerPanelStateTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "unpeel.explorer.paneltests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testDefaultsAreHiddenAndDefaultWidth() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = ExplorerPanelState(defaults: defaults)

        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.width, 260)
    }

    func testToggleAndWidthPersist() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ExplorerPanelState(defaults: defaults)

        state.toggle()
        state.width = 333

        let reopened = ExplorerPanelState(defaults: defaults)
        XCTAssertTrue(reopened.isVisible)
        XCTAssertEqual(reopened.width, 333)
    }

    func testWidthIsClamped() {
        XCTAssertEqual(ExplorerPanelState.clamp(10), 180)
        XCTAssertEqual(ExplorerPanelState.clamp(300), 300)
        XCTAssertEqual(ExplorerPanelState.clamp(9000), 520)
    }

    func testOutOfRangeStoredWidthIsClampedOnLoad() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5.0, forKey: "unpeel.explorer.width")

        XCTAssertEqual(ExplorerPanelState(defaults: defaults).width, 180)
    }
}
