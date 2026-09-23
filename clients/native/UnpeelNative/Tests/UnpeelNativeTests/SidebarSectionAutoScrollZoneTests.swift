import AppKit
import XCTest
@testable import UnpeelNative

/// Fork-only: sidebar sections. PROJECTS can be as short as 80 pt, where two
/// fixed 44 pt drag auto-scroll zones would overlap the whole viewport; the
/// effective zone is clamped to a quarter of the viewport height.
@MainActor
final class SidebarSectionAutoScrollZoneTests: XCTestCase {
    private let zone = SidebarSessionDragController.autoScrollZone

    func testTallViewportKeepsFullZone() {
        XCTAssertEqual(
            SidebarSessionDragController.effectiveAutoScrollZone(
                viewportHeight: 600,
                zone: zone
            ),
            44
        )
    }

    func testMinimumProjectsViewportClampsToQuarter() {
        XCTAssertEqual(
            SidebarSessionDragController.effectiveAutoScrollZone(
                viewportHeight: 80,
                zone: zone
            ),
            20
        )
    }

    func testDegenerateViewportHasNoZone() {
        XCTAssertEqual(
            SidebarSessionDragController.effectiveAutoScrollZone(
                viewportHeight: -10,
                zone: zone
            ),
            0
        )
    }
}
