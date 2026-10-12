import XCTest
@testable import UnpeelNative

final class SidebarSectionLayoutTests: XCTestCase {
    private let minimums: [SidebarSectionID: CGFloat] = [.projects: 80, .explorer: 120]

    // MARK: Defaults

    // Fork-only: git support — GIT HISTORY is in the default stack but
    // starts collapsed, so a fresh sidebar looks like it did before.
    func testDefaultLayoutShowsEverySectionWithGitHistoryCollapsed() {
        let layout = SidebarSectionLayout.default
        XCTAssertEqual(layout.order, [.projects, .explorer, .gitHistory])
        XCTAssertEqual(layout.visible, [.projects, .explorer, .gitHistory])
        XCTAssertEqual(layout.expanded, [.projects, .explorer])
        XCTAssertEqual(layout.weight(of: .projects), 0.4, accuracy: 1e-9)
        XCTAssertEqual(layout.weight(of: .explorer), 0.6, accuracy: 1e-9)
        XCTAssertEqual(layout.weight(of: .gitHistory), 0.4, accuracy: 1e-9)
    }

    func testIdsCarryTitlesAndMinimums() {
        XCTAssertEqual(SidebarSectionID.projects.title, "PROJECTS")
        XCTAssertEqual(SidebarSectionID.explorer.title, "EXPLORER")
        XCTAssertEqual(SidebarSectionID.gitHistory.title, "GIT HISTORY")
        XCTAssertEqual(
            SidebarSectionID.minimumContentHeights,
            [.projects: 80, .explorer: 120, .gitHistory: 100]
        )
    }

    // MARK: Heights

    func testContentSpaceSubtractsHeadersAndSeparators() {
        let layout = SidebarSectionLayout.default
        XCTAssertEqual(layout.contentSpace(available: 600, headerHeight: 22, separatorHeight: 1), 600 - 66 - 2)
        let oneVisible = layout.settingHidden(.explorer, true).settingHidden(.gitHistory, true)
        XCTAssertEqual(oneVisible.contentSpace(available: 600, headerHeight: 22, separatorHeight: 1), 578)
        XCTAssertEqual(layout.contentSpace(available: 10, headerHeight: 22, separatorHeight: 1), 0)
    }

    func testHeightsFollowWeightsWhenMinimumsFit() {
        let heights = SidebarSectionLayout.default.contentHeights(space: 500, minimums: minimums)
        XCTAssertEqual(heights[.projects]!, 200, accuracy: 1e-6)
        XCTAssertEqual(heights[.explorer]!, 300, accuracy: 1e-6)
    }

    func testSingleExpandedSectionTakesAllSpace() {
        let layout = SidebarSectionLayout.default.settingCollapsed(.projects, true)
        XCTAssertEqual(layout.contentHeights(space: 500, minimums: minimums), [.explorer: 500])
    }

    func testNoExpandedSectionsGiveNoHeights() {
        let layout = SidebarSectionLayout.default
            .settingCollapsed(.projects, true)
            .settingCollapsed(.explorer, true)
        XCTAssertEqual(layout.contentHeights(space: 500, minimums: minimums), [:])
    }

    func testSectionBelowMinimumIsPinnedAndTheRestShared() {
        // 0.1 of 300 = 30 < 80 → projects pinned at 80, explorer gets 220.
        let layout = SidebarSectionLayout(
            order: [.projects, .explorer], hidden: [], collapsed: [],
            weights: [.projects: 0.1, .explorer: 0.9]
        )
        let heights = layout.contentHeights(space: 300, minimums: minimums)
        XCTAssertEqual(heights[.projects]!, 80, accuracy: 1e-6)
        XCTAssertEqual(heights[.explorer]!, 220, accuracy: 1e-6)
    }

    func testShortSpaceGivesMinimumsTopDownAndCompressesTheBottom() {
        let heights = SidebarSectionLayout.default.contentHeights(space: 150, minimums: minimums)
        XCTAssertEqual(heights[.projects]!, 80, accuracy: 1e-6)
        XCTAssertEqual(heights[.explorer]!, 70, accuracy: 1e-6)
        let tiny = SidebarSectionLayout.default.contentHeights(space: 50, minimums: minimums)
        XCTAssertEqual(tiny[.projects]!, 50, accuracy: 1e-6)
        XCTAssertEqual(tiny[.explorer]!, 0, accuracy: 1e-6)
    }

    // MARK: Divider

    func testDividerDragMovesHeightBetweenNeighbours() {
        let resized = SidebarSectionLayout.default.resizing(
            upper: .projects, lower: .explorer, by: 50, space: 500, minimums: minimums
        )
        let heights = resized.contentHeights(space: 500, minimums: minimums)
        XCTAssertEqual(heights[.projects]!, 250, accuracy: 1e-6)
        XCTAssertEqual(heights[.explorer]!, 250, accuracy: 1e-6)
        XCTAssertEqual(resized.weight(of: .projects) + resized.weight(of: .explorer), 1.0, accuracy: 1e-9)
    }

    func testDividerDragClampsAtBothMinimums() {
        let up = SidebarSectionLayout.default.resizing(
            upper: .projects, lower: .explorer, by: -1000, space: 500, minimums: minimums
        ).contentHeights(space: 500, minimums: minimums)
        XCTAssertEqual(up[.projects]!, 80, accuracy: 1e-6)
        XCTAssertEqual(up[.explorer]!, 420, accuracy: 1e-6)

        let down = SidebarSectionLayout.default.resizing(
            upper: .projects, lower: .explorer, by: 1000, space: 500, minimums: minimums
        ).contentHeights(space: 500, minimums: minimums)
        XCTAssertEqual(down[.projects]!, 380, accuracy: 1e-6)
        XCTAssertEqual(down[.explorer]!, 120, accuracy: 1e-6)
    }

    func testDividerDragIsIgnoredWhenANeighbourIsCollapsed() {
        let layout = SidebarSectionLayout.default.settingCollapsed(.explorer, true)
        XCTAssertEqual(
            layout.resizing(upper: .projects, lower: .explorer, by: 50, space: 500, minimums: minimums),
            layout
        )
    }

    // MARK: Collapse / hide

    func testCollapseKeepsWeightAndExpandRestoresIt() {
        let collapsed = SidebarSectionLayout.default.togglingCollapse(.explorer)
        XCTAssertFalse(collapsed.isExpanded(.explorer))
        XCTAssertTrue(collapsed.isVisible(.explorer))
        XCTAssertEqual(collapsed.contentHeights(space: 500, minimums: minimums), [.projects: 500])
        let expanded = collapsed.togglingCollapse(.explorer)
        XCTAssertEqual(expanded, SidebarSectionLayout.default)
    }

    func testHidingTheLastVisibleSectionIsRefused() {
        let one = SidebarSectionLayout.default.settingHidden(.projects, true).settingHidden(.gitHistory, true)
        XCTAssertEqual(one.visible, [.explorer])
        XCTAssertEqual(one.settingHidden(.explorer, true), one)
        XCTAssertEqual(one.settingHidden(.projects, false).visible, [.projects, .explorer])
    }

    func testRevealingShowsAndExpands() {
        let hidden = SidebarSectionLayout.default
            .settingCollapsed(.explorer, true)
            .settingHidden(.explorer, true)
        let revealed = hidden.revealing(.explorer)
        XCTAssertTrue(revealed.isExpanded(.explorer))
        XCTAssertEqual(revealed.visible, [.projects, .explorer, .gitHistory])
    }

    func testRevealingGitHistoryExpandsIt() {
        let revealed = SidebarSectionLayout.default.revealing(.gitHistory)
        XCTAssertEqual(revealed.expanded, [.projects, .explorer, .gitHistory])
    }

    // MARK: Persistence

    func testEncodeDecodeRoundTrip() {
        let layout = SidebarSectionLayout.default
            .resizing(upper: .projects, lower: .explorer, by: 30, space: 500, minimums: minimums)
            .settingCollapsed(.explorer, true)
        XCTAssertEqual(SidebarSectionLayout.decode(layout.encoded()), layout)
    }

    func testDecodeFallsBackToDefaultForNilGarbageAndUnknownVersion() {
        XCTAssertEqual(SidebarSectionLayout.decode(nil), .default)
        XCTAssertEqual(SidebarSectionLayout.decode(Data("not json".utf8)), .default)
        let future = #"{"version":2,"order":["explorer"],"hidden":[],"collapsed":[],"weights":{}}"#
        XCTAssertEqual(SidebarSectionLayout.decode(Data(future.utf8)), .default)
    }

    func testDecodeDropsUnknownIdsAndAppendsMissingKnownOnes() {
        let json = #"{"version":1,"order":["explorer","timeline"],"hidden":["timeline"],"collapsed":["explorer"],"weights":{"explorer":0.7,"timeline":0.3}}"#
        let layout = SidebarSectionLayout.decode(Data(json.utf8))
        XCTAssertEqual(layout.order, [.explorer, .projects, .gitHistory])
        XCTAssertEqual(layout.hidden, [])
        // An appended id takes its fresh-install state: PROJECTS expanded,
        // GIT HISTORY collapsed.
        XCTAssertEqual(layout.collapsed, [.explorer, .gitHistory])
        XCTAssertEqual(layout.weight(of: .explorer), 0.7, accuracy: 1e-9)
        XCTAssertEqual(layout.weight(of: .projects), 0.4, accuracy: 1e-9)
    }

    // Fork-only: git support — a layout saved before GIT HISTORY existed
    // gains it at the bottom, collapsed, so the existing sidebar does not
    // shift; everything the record said is kept.
    func testLayoutSavedBeforeGitHistoryGainsItCollapsed() {
        let json = #"{"version":1,"order":["projects","explorer"],"hidden":[],"collapsed":["projects"],"weights":{"projects":0.3,"explorer":0.7}}"#
        let layout = SidebarSectionLayout.decode(Data(json.utf8))
        XCTAssertEqual(layout.order, [.projects, .explorer, .gitHistory])
        XCTAssertEqual(layout.collapsed, [.projects, .gitHistory])
        XCTAssertEqual(layout.hidden, [])
        XCTAssertEqual(layout.expanded, [.explorer])
        XCTAssertEqual(layout.weight(of: .projects), 0.3, accuracy: 1e-9)
        XCTAssertEqual(layout.weight(of: .explorer), 0.7, accuracy: 1e-9)
        XCTAssertEqual(layout.contentHeights(space: 500, minimums: minimums), [.explorer: 500])
    }

    func testLayoutSavedWithHiddenSectionsKeepsThemHidden() {
        let json = #"{"version":1,"order":["projects","explorer"],"hidden":["projects"],"collapsed":[],"weights":{}}"#
        let layout = SidebarSectionLayout.decode(Data(json.utf8))
        XCTAssertEqual(layout.hidden, [.projects])
        XCTAssertEqual(layout.visible, [.explorer, .gitHistory])
        XCTAssertEqual(layout.expanded, [.explorer])
    }

    func testDecodeNeverHidesEverySection() {
        let json = #"{"version":1,"order":["projects","explorer","gitHistory"],"hidden":["projects","explorer","gitHistory"],"collapsed":[],"weights":{}}"#
        XCTAssertEqual(SidebarSectionLayout.decode(Data(json.utf8)).visible, [.projects, .explorer, .gitHistory])
    }

    func testDecodeIgnoresNonPositiveOrNonFiniteWeights() {
        let json = #"{"version":1,"order":["projects","explorer"],"hidden":[],"collapsed":[],"weights":{"projects":-1,"explorer":0}}"#
        let layout = SidebarSectionLayout.decode(Data(json.utf8))
        XCTAssertEqual(layout.weight(of: .projects), 0.4, accuracy: 1e-9)
        XCTAssertEqual(layout.weight(of: .explorer), 0.6, accuracy: 1e-9)
    }
}
