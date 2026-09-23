import AppKit
import XCTest
@testable import UnpeelNative

/// Fork-only: sidebar sections. The detached drag monitor arms a press only
/// inside the PROJECTS list's visible band. Rows used to scroll under the
/// 38 pt titlebar glass; inside the section only the short top fade covers
/// them, so the band must not swallow the first rows.
@MainActor
final class SidebarSectionPressBandTests: XCTestCase {
    private let ramp = SidebarSessionDragController.pressBandTopOcclusion

    func testBandOcclusionIsTheSectionFadeNotTheTitlebar() {
        XCTAssertEqual(ramp, SidebarSectionMetrics.projectsFadeRamp)
        XCTAssertLessThan(ramp, Theme.titlebarHeight)
    }

    func testFirstRowAtRestAcceptsPress() {
        let viewport = CGRect(x: 0, y: 0, width: 280, height: 400)
        let firstRowMidY = SidebarSectionMetrics.projectsTopInset
            + Theme.sessionRowHeight / 2
        XCTAssertTrue(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: firstRowMidY),
                visibleRect: viewport,
                topOcclusion: ramp
            ),
            "the first row's middle is below the fade, not under the titlebar"
        )
    }

    func testPointBelowFadeAcceptedAndInsideFadeRefused() {
        let viewport = CGRect(x: 0, y: 120, width: 280, height: 400)
        XCTAssertTrue(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.minY + ramp + 5),
                visibleRect: viewport,
                topOcclusion: ramp
            ),
            "5 pt below the fade ramp is pressable"
        )
        XCTAssertTrue(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.minY + Theme.titlebarHeight - 5),
                visibleRect: viewport,
                topOcclusion: ramp
            ),
            "the old titlebar band no longer refuses presses"
        )
        XCTAssertFalse(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.minY + ramp / 2),
                visibleRect: viewport,
                topOcclusion: ramp
            ),
            "a row faded out under the section header is not pressable"
        )
    }

    func testPointOutsideViewportRefused() {
        let viewport = CGRect(x: 0, y: 120, width: 280, height: 400)
        XCTAssertFalse(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.maxY + 5),
                visibleRect: viewport,
                topOcclusion: ramp
            ),
            "rows below the viewport are not pressable"
        )
        XCTAssertFalse(
            SidebarSessionDragController.pressIsInVisibleBand(
                point: CGPoint(x: 40, y: viewport.minY - 5),
                visibleRect: viewport,
                topOcclusion: ramp
            ),
            "rows scrolled above the viewport are not pressable"
        )
    }
}
