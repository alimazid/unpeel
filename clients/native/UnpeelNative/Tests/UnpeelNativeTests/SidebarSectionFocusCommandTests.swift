import XCTest
@testable import UnpeelNative

final class SidebarSectionFocusCommandTests: XCTestCase {
    func testCollapsesOnlyWhenFocusedExpandedVisibleAndSidebarOpen() {
        XCTAssertEqual(
            SidebarSectionFocusCommand.action(focused: true, expanded: true, hidden: false, sidebarCollapsed: false),
            .collapse
        )
    }

    func testEveryOtherStateRevealsAndFocuses() {
        for focused in [true, false] {
            for expanded in [true, false] {
                for hidden in [true, false] {
                    for sidebarCollapsed in [true, false] {
                        let collapses = focused && expanded && !hidden && !sidebarCollapsed
                        if collapses { continue }
                        XCTAssertEqual(
                            SidebarSectionFocusCommand.action(
                                focused: focused,
                                expanded: expanded,
                                hidden: hidden,
                                sidebarCollapsed: sidebarCollapsed
                            ),
                            .revealAndFocus,
                            "focused=\(focused) expanded=\(expanded) hidden=\(hidden) collapsed=\(sidebarCollapsed)"
                        )
                    }
                }
            }
        }
    }

    func testMenuTitles() {
        XCTAssertEqual(SidebarSectionFocusCommand.menuTitle(for: .collapse, section: .explorer), "Hide Explorer")
        XCTAssertEqual(SidebarSectionFocusCommand.menuTitle(for: .revealAndFocus, section: .explorer), "Show Explorer")
    }
}
