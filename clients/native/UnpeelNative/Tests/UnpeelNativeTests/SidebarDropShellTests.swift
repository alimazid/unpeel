import CoreGraphics
import XCTest
@testable import UnpeelNative

/// Project and group drop shells are no longer registered frames: each
/// registered row carries its owner chain, and the drag controller derives a
/// block's shell as the union of the mounted rows it owns (#43). These tests
/// pin what a point resolves to through the controller's static surface.
@MainActor
final class SidebarDropShellTests: XCTestCase {
    private typealias Controller = SidebarSessionDragController

    private static let width: CGFloat = 260
    private static let rowHeight: CGFloat = 28

    private func frame(slot: Int, height: CGFloat = rowHeight) -> CGRect {
        CGRect(x: 0, y: CGFloat(slot) * Self.rowHeight, width: Self.width, height: height)
    }

    private func record(
        _ kind: Controller.RowKind?,
        _ frame: CGRect,
        owners: [Controller.ShellOwner]
    ) -> Controller.RowRecord {
        Controller.RowRecord(kind: kind, frame: frame, owners: owners)
    }

    func testDropOnAnEmptyExpandedGroupsPlaceholderFilesIntoThatGroup() {
        let rows: [String: Controller.RowRecord] = [
            "root": record(.project, frame(slot: 0), owners: [.project("root")]),
            "group": record(
                .folderItem(parentID: "root", pinned: false, depth: 1),
                frame(slot: 1),
                owners: [.project("root"), .group("group")]
            ),
            "empty:group": record(
                nil, frame(slot: 2), owners: [.project("root"), .group("group")]
            ),
        ]

        let hit = Controller.row(at: CGPoint(x: 120, y: 2.5 * Self.rowHeight), in: rows)

        XCTAssertEqual(hit?.kind, .groupShell(projectID: "group"))
    }

    func testDropOnAnEmptyTopLevelProjectsPlaceholderFilesIntoThatProject() {
        let rows: [String: Controller.RowRecord] = [
            "root": record(.project, frame(slot: 0), owners: [.project("root")]),
            "empty:root": record(nil, frame(slot: 1), owners: [.project("root")]),
        ]

        let hit = Controller.row(at: CGPoint(x: 120, y: 1.5 * Self.rowHeight), in: rows)

        XCTAssertEqual(hit?.kind, .projectShell(projectID: "root"))
    }

    /// root ▸ header, group (header, a, 14pt of blank wash, b), then c.
    private var groupWithBlankWash: [String: Controller.RowRecord] {
        let group: [Controller.ShellOwner] = [.project("root"), .group("group")]
        return [
            "root": record(.project, frame(slot: 0), owners: [.project("root")]),
            "group": record(
                .folderItem(parentID: "root", pinned: false, depth: 1),
                frame(slot: 1),
                owners: group
            ),
            "a": record(
                .session(projectID: "group", pinned: false, depth: 1),
                CGRect(x: 0, y: 56, width: Self.width, height: 28),
                owners: group
            ),
            "b": record(
                .session(projectID: "group", pinned: false, depth: 1),
                CGRect(x: 0, y: 98, width: Self.width, height: 28),
                owners: group
            ),
            "c": record(
                .session(projectID: "root", pinned: false, depth: 0),
                CGRect(x: 0, y: 126, width: Self.width, height: 28),
                owners: [.project("root")]
            ),
        ]
    }

    func testDropOnBlankGroupWashFilesIntoTheGroupNotItsProject() {
        let hit = Controller.row(at: CGPoint(x: 120, y: 90), in: groupWithBlankWash)

        XCTAssertEqual(hit?.kind, .groupShell(projectID: "group"))
        XCTAssertEqual(
            hit?.frame,
            CGRect(x: 0, y: 28, width: Self.width, height: 98),
            "the shell is the union of the group's header and rows"
        )
        XCTAssertEqual(hit?.isDraggable, false, "a shell is never a drag source")
    }

    func testBlankWashOfANestedGroupFilesIntoTheInnermostGroup() {
        let outer: [Controller.ShellOwner] = [.project("root"), .group("outer")]
        let inner = outer + [.group("inner")]
        let rows: [String: Controller.RowRecord] = [
            "root": record(.project, frame(slot: 0), owners: [.project("root")]),
            "outer": record(
                .folderItem(parentID: "root", pinned: false, depth: 1),
                frame(slot: 1),
                owners: outer
            ),
            "inner": record(
                .folderItem(parentID: "outer", pinned: false, depth: 2),
                frame(slot: 2),
                owners: inner
            ),
            "a": record(
                .session(projectID: "inner", pinned: false, depth: 2),
                CGRect(x: 0, y: 98, width: Self.width, height: 28),
                owners: inner
            ),
            "b": record(
                .session(projectID: "outer", pinned: false, depth: 1),
                frame(slot: 5),
                owners: outer
            ),
        ]

        let hit = Controller.row(at: CGPoint(x: 120, y: 90), in: rows)

        XCTAssertEqual(hit?.kind, .groupShell(projectID: "inner"))
    }

    func testSemanticRowsWinOverTheShellsThatContainThem() {
        XCTAssertEqual(
            Controller.row(at: CGPoint(x: 120, y: 70), in: groupWithBlankWash)?.kind,
            .session(projectID: "group", pinned: false, depth: 1)
        )
        XCTAssertEqual(
            Controller.row(at: CGPoint(x: 120, y: 40), in: groupWithBlankWash)?.kind,
            .folderItem(parentID: "root", pinned: false, depth: 1),
            "the group header stays a draggable folder row"
        )
    }

    func testOverlappingSemanticRowsResolveToTheSmallest() {
        let rows: [String: Controller.RowRecord] = [
            "tall": record(
                .session(projectID: "root", pinned: false, depth: 0),
                CGRect(x: 0, y: 0, width: Self.width, height: 80),
                owners: [.project("root")]
            ),
            "short": record(
                .session(projectID: "root", pinned: false, depth: 0),
                CGRect(x: 0, y: 20, width: Self.width, height: 28),
                owners: [.project("root")]
            ),
        ]

        XCTAssertEqual(Controller.row(at: CGPoint(x: 120, y: 30), in: rows)?.id, "short")
    }

    func testAPointOutsideEveryBlockHitsNothing() {
        XCTAssertNil(Controller.row(at: CGPoint(x: 120, y: 400), in: groupWithBlankWash))
    }

    // MARK: Pinned drags without registered shells

    /// root ▸ header 0–28, group (header 28–56, pinned g1 56–84, wash
    /// 84–98, g2 98–126), root's own blank 126–140, other (header 140–168,
    /// wash 168–182, o1 182–210); then the empty project far (header
    /// 210–238, placeholder 238–266).
    private var pinnedLayout: [String: Controller.RowRecord] {
        let group: [Controller.ShellOwner] = [.project("root"), .group("group")]
        let other: [Controller.ShellOwner] = [.project("root"), .group("other")]
        func row(_ y: CGFloat) -> CGRect {
            CGRect(x: 0, y: y, width: Self.width, height: Self.rowHeight)
        }
        return [
            "root": record(.project, row(0), owners: [.project("root")]),
            "group": record(
                .folderItem(parentID: "root", pinned: true, depth: 1),
                row(28),
                owners: group
            ),
            "g1": record(.session(projectID: "group", pinned: true, depth: 1), row(56), owners: group),
            "g2": record(.session(projectID: "group", pinned: false, depth: 1), row(98), owners: group),
            "other": record(
                .folderItem(parentID: "root", pinned: false, depth: 1),
                row(140),
                owners: other
            ),
            "o1": record(.session(projectID: "other", pinned: false, depth: 1), row(182), owners: other),
            "far": record(.project, row(210), owners: [.project("far")]),
            "empty:far": record(nil, row(238), owners: [.project("far")]),
        ]
    }

    private func pinnedAction(
        partition parentID: String, source sourceID: String, at y: CGFloat
    ) -> Controller.PinnedSidebarHitAction? {
        guard let hit = Controller.row(at: CGPoint(x: 120, y: y), in: pinnedLayout) else {
            return nil
        }
        return Controller.pinnedSidebarHitAction(
            boundary: .partition(parentID: parentID),
            sourceID: sourceID,
            targetID: hit.id,
            targetKind: hit.kind,
            firstReorderID: nil
        )
    }

    func testPinnedSessionAllowsItsOwnGroupsWashAndDeniesEveryOtherBlock() {
        XCTAssertEqual(pinnedAction(partition: "group", source: "g1", at: 90), .allow)
        XCTAssertEqual(
            pinnedAction(partition: "group", source: "g1", at: 175), .deny,
            "a sibling group's wash is outside the pinned partition"
        )
        XCTAssertEqual(
            pinnedAction(partition: "group", source: "g1", at: 133), .deny,
            "the parent project's blank space is outside the group's partition"
        )
        XCTAssertEqual(
            pinnedAction(partition: "group", source: "g1", at: 250), .deny,
            "another project's placeholder is outside the partition"
        )
    }

    func testPinnedSessionOfAProjectAllowsThatProjectsBlankSpace() {
        XCTAssertEqual(pinnedAction(partition: "root", source: "r1", at: 133), .allow)
        XCTAssertEqual(pinnedAction(partition: "root", source: "r1", at: 250), .deny)
    }

    func testPinnedGroupAllowsItsOwnWashAndDeniesASiblingGroups() {
        XCTAssertEqual(pinnedAction(partition: "root", source: "group", at: 90), .allow)
        XCTAssertEqual(pinnedAction(partition: "root", source: "group", at: 175), .deny)
    }

    // MARK: Project reorder target

    /// alpha ▸ header 0–28 and four Sessions 28–140 (midpoint 70); a 1pt
    /// stack gap; beta ▸ header 141–169 and two Sessions 169–225.
    private var twoProjects: [String: Controller.RowRecord] {
        var rows: [String: Controller.RowRecord] = [
            "alpha": record(.project, frame(slot: 0), owners: [.project("alpha")]),
            "beta": record(
                .project,
                CGRect(x: 0, y: 141, width: Self.width, height: 28),
                owners: [.project("beta")]
            ),
        ]
        for index in 0..<4 {
            rows["a\(index)"] = record(
                .session(projectID: "alpha", pinned: false, depth: 0),
                frame(slot: index + 1),
                owners: [.project("alpha")]
            )
        }
        for index in 0..<2 {
            rows["b\(index)"] = record(
                .session(projectID: "beta", pinned: false, depth: 0),
                CGRect(x: 0, y: 169 + CGFloat(index) * 28, width: Self.width, height: 28),
                owners: [.project("beta")]
            )
        }
        return rows
    }

    func testProjectBlockSplitsAboveAndBelowAtTheBlocksMidpoint() {
        XCTAssertEqual(
            Controller.projectBlock(at: CGPoint(x: 120, y: 10), in: twoProjects),
            .init(id: "alpha", below: false)
        )
        XCTAssertEqual(
            Controller.projectBlock(at: CGPoint(x: 120, y: 69), in: twoProjects),
            .init(id: "alpha", below: false),
            "the header alone would have put this point below"
        )
        XCTAssertEqual(
            Controller.projectBlock(at: CGPoint(x: 120, y: 120), in: twoProjects),
            .init(id: "alpha", below: true),
            "a nested Session row doesn't punch a hole in its project's block"
        )
        XCTAssertEqual(
            Controller.projectBlock(at: CGPoint(x: 120, y: 160), in: twoProjects),
            .init(id: "beta", below: false)
        )
        XCTAssertEqual(
            Controller.projectBlock(at: CGPoint(x: 120, y: 200), in: twoProjects),
            .init(id: "beta", below: true)
        )
    }

    func testTheGapBetweenProjectBlocksHitsNoBlock() {
        XCTAssertNil(Controller.projectBlock(at: CGPoint(x: 120, y: 140.5), in: twoProjects))
    }

    func testAPartlyMountedBlockSplitsAtTheMidpointOfItsMountedPart() {
        // Only Sessions 3–5 of a long project are mounted (its header and
        // first rows scrolled out of the lazy window): 112–196, midpoint 154.
        let rows = (3..<6).reduce(into: [String: Controller.RowRecord]()) { rows, index in
            rows["s\(index)"] = record(
                .session(projectID: "long", pinned: false, depth: 0),
                CGRect(x: 0, y: CGFloat(index + 1) * 28, width: Self.width, height: 28),
                owners: [.project("long")]
            )
        }

        XCTAssertEqual(
            Controller.projectBlock(at: CGPoint(x: 120, y: 150), in: rows),
            .init(id: "long", below: false)
        )
        XCTAssertEqual(
            Controller.projectBlock(at: CGPoint(x: 120, y: 158), in: rows),
            .init(id: "long", below: true)
        )
    }

    func testATopLevelGroupHasNoProjectBlockSoItsHeaderAnswers() {
        let group: [Controller.ShellOwner] = [.group("folder")]
        let rows: [String: Controller.RowRecord] = [
            "folder": record(.project, frame(slot: 0), owners: group),
            "f1": record(
                .session(projectID: "folder", pinned: false, depth: 0),
                frame(slot: 1),
                owners: group
            ),
            "f2": record(
                .session(projectID: "folder", pinned: false, depth: 0),
                frame(slot: 2),
                owners: group
            ),
        ]

        XCTAssertEqual(
            Controller.projectBlock(at: CGPoint(x: 120, y: 20), in: rows),
            .init(id: "folder", below: true),
            "the header's own midpoint (14) splits it"
        )
        XCTAssertNil(
            Controller.projectBlock(at: CGPoint(x: 120, y: 40), in: rows),
            "a top-level group's rows are not a project block"
        )
    }
}
