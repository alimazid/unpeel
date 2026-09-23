import XCTest
@testable import UnpeelNative

final class ExplorerFocusCommandTests: XCTestCase {
    func testCollapsesOnlyWhenFocusedExpandedVisibleAndSidebarOpen() {
        XCTAssertEqual(
            ExplorerFocusCommand.action(treeFocused: true, explorerExpanded: true, explorerHidden: false, sidebarCollapsed: false),
            .collapseExplorer
        )
    }

    func testEveryOtherStateRevealsAndFocuses() {
        for treeFocused in [true, false] {
            for explorerExpanded in [true, false] {
                for explorerHidden in [true, false] {
                    for sidebarCollapsed in [true, false] {
                        let collapses = treeFocused && explorerExpanded && !explorerHidden && !sidebarCollapsed
                        if collapses { continue }
                        XCTAssertEqual(
                            ExplorerFocusCommand.action(
                                treeFocused: treeFocused,
                                explorerExpanded: explorerExpanded,
                                explorerHidden: explorerHidden,
                                sidebarCollapsed: sidebarCollapsed
                            ),
                            .revealAndFocus,
                            "focused=\(treeFocused) expanded=\(explorerExpanded) hidden=\(explorerHidden) collapsed=\(sidebarCollapsed)"
                        )
                    }
                }
            }
        }
    }

    func testMenuTitles() {
        XCTAssertEqual(ExplorerFocusCommand.menuTitle(for: .collapseExplorer), "Hide Explorer")
        XCTAssertEqual(ExplorerFocusCommand.menuTitle(for: .revealAndFocus), "Show Explorer")
    }
}
