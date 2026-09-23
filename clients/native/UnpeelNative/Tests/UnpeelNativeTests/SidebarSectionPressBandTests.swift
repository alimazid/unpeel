import AppKit
import XCTest
@testable import UnpeelNative

/// Fork-only: sidebar sections. The detached drag monitor arms a press only
/// inside the PROJECTS list's visible band. Rows used to scroll under the
/// 38 pt titlebar glass; inside the section nothing covers the list (the
/// header sits outside the scroll view and the fade only dims rows), so the
/// band excludes nothing at the top.
@MainActor
final class SidebarSectionPressBandTests: XCTestCase {
    private let occlusion = SidebarSessionDragController.pressBandTopOcclusion

    func testBandHasNoTopOcclusion() {
        XCTAssertEqual(occlusion, 0)
    }

    func testFirstRowTopEdgeAtRestAcceptsPress() {
        let viewport = CGRect(x: 0, y: 0, width: 280, height: 400)
        XCTAssertTrue(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: SidebarSectionMetrics.projectsTopInset + 2),
                visibleRect: viewport,
                topOcclusion: occlusion
            ),
            "the first row's top edge is pressable at rest"
        )
    }

    func testPointJustBelowVisibleTopAccepted() {
        let viewport = CGRect(x: 0, y: 120, width: 280, height: 400)
        XCTAssertTrue(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.minY + 1),
                visibleRect: viewport,
                topOcclusion: occlusion
            ),
            "a row dimmed by the fade is still pressable"
        )
    }

    func testPointOutsideViewportRefused() {
        let viewport = CGRect(x: 0, y: 120, width: 280, height: 400)
        XCTAssertFalse(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.maxY + 5),
                visibleRect: viewport,
                topOcclusion: occlusion
            ),
            "rows below the viewport are not pressable"
        )
        XCTAssertFalse(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.minY - 5),
                visibleRect: viewport,
                topOcclusion: occlusion
            ),
            "rows scrolled above the viewport are not pressable"
        )
    }

    func testHelperStillHonoursAnOcclusion() {
        let viewport = CGRect(x: 0, y: 120, width: 280, height: 400)
        XCTAssertFalse(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.minY + 5),
                visibleRect: viewport,
                topOcclusion: 10
            )
        )
    }
}
