import CoreGraphics
import XCTest
@testable import UnpeelNative

/// A project's or group's drop shell is the union of the registered frames
/// of the mounted rows that name it in their owner chain (#43). These tests
/// pin what a point resolves to through the drag controller's static surface.
@MainActor
final class SidebarDropShellTests: XCTestCase {
    private typealias Controller = SidebarSessionDragController

    private static let width: CGFloat = 260
    /// One row's height; every layout below is in multiples of it.
    private static let row: CGFloat = 28

    private func frame(y: CGFloat, height: CGFloat = row) -> CGRect {
        CGRect(x: 0, y: y, width: Self.width, height: height)
    }

    private func record(
        _ kind: Controller.RowKind?,
        _ frame: CGRect,
        owners: [Controller.ShellOwner]
    ) -> Controller.RowRecord {
        Controller.RowRecord(
            kind: kind, frame: frame, owners: owners, isDraggable: true, token: UUID()
        )
    }

    private func session(in projectID: String, depth: Int, pinned: Bool = false) -> Controller.RowKind {
        .session(projectID: projectID, pinned: pinned, depth: depth)
    }

    private func folder(in parentID: String, depth: Int, pinned: Bool = false) -> Controller.RowKind {
        .folderItem(parentID: parentID, pinned: pinned, depth: depth)
    }

    private func hit(_ y: CGFloat, in rows: [String: Controller.RowRecord]) -> Controller.RowHit? {
        Controller.row(at: CGPoint(x: 120, y: y), in: rows)
    }

    // MARK: Placeholders

    func testDropOnAnEmptyExpandedGroupsPlaceholderFilesIntoThatGroup() {
        let group: [Controller.ShellOwner] = [.project("root"), .group("group")]
        let rows = [
            "root": record(.project, frame(y: 0), owners: [.project("root")]),
            "group": record(folder(in: "root", depth: 1), frame(y: Self.row), owners: group),
            "empty:group": record(nil, frame(y: 2 * Self.row), owners: group),
        ]

        XCTAssertEqual(hit(2.5 * Self.row, in: rows)?.kind, .groupShell(projectID: "group"))
    }

    func testDropOnAnEmptyTopLevelProjectsPlaceholderFilesIntoThatProject() {
        let rows = [
            "root": record(.project, frame(y: 0), owners: [.project("root")]),
            "empty:root": record(nil, frame(y: Self.row), owners: [.project("root")]),
        ]

        XCTAssertEqual(hit(1.5 * Self.row, in: rows)?.kind, .projectShell(projectID: "root"))
    }

    // MARK: Blank wash and hit priority

    /// root ▸ header, then group (header, a, half a row of blank wash, b),
    /// then root's own Session c.
    private var groupWithBlankWash: [String: Controller.RowRecord] {
        let group: [Controller.ShellOwner] = [.project("root"), .group("group")]
        return [
            "root": record(.project, frame(y: 0), owners: [.project("root")]),
            "group": record(folder(in: "root", depth: 1), frame(y: Self.row), owners: group),
            "a": record(session(in: "group", depth: 1), frame(y: 2 * Self.row), owners: group),
            "b": record(session(in: "group", depth: 1), frame(y: 3.5 * Self.row), owners: group),
            "c": record(session(in: "root", depth: 0), frame(y: 4.5 * Self.row), owners: [.project("root")]),
        ]
    }

    func testDropOnBlankGroupWashFilesIntoTheGroupNotItsProject() {
        let washHit = hit(3.25 * Self.row, in: groupWithBlankWash)

        XCTAssertEqual(washHit?.kind, .groupShell(projectID: "group"))
        XCTAssertEqual(
            washHit?.frame,
            frame(y: Self.row, height: 3.5 * Self.row),
            "the shell is the union of the group's header and rows"
        )
        XCTAssertEqual(washHit?.isDraggable, false, "a shell is never a drag source")
    }

    func testBlankWashOfANestedGroupFilesIntoTheInnermostGroup() {
        let outer: [Controller.ShellOwner] = [.project("root"), .group("outer")]
        let inner = outer + [.group("inner")]
        let rows = [
            "root": record(.project, frame(y: 0), owners: [.project("root")]),
            "outer": record(folder(in: "root", depth: 1), frame(y: Self.row), owners: outer),
            "inner": record(folder(in: "outer", depth: 2), frame(y: 2 * Self.row), owners: inner),
            "a": record(session(in: "inner", depth: 2), frame(y: 3.5 * Self.row), owners: inner),
            "b": record(session(in: "outer", depth: 1), frame(y: 5 * Self.row), owners: outer),
        ]

        XCTAssertEqual(hit(3.25 * Self.row, in: rows)?.kind, .groupShell(projectID: "inner"))
    }

    func testSemanticRowsWinOverTheShellsThatContainThem() {
        XCTAssertEqual(hit(2.5 * Self.row, in: groupWithBlankWash)?.kind, session(in: "group", depth: 1))
        XCTAssertEqual(
            hit(1.5 * Self.row, in: groupWithBlankWash)?.kind,
            folder(in: "root", depth: 1),
            "the group header stays a draggable folder row"
        )
    }

    func testOverlappingSemanticRowsResolveToTheSmallest() {
        let rows = [
            "tall": record(session(in: "root", depth: 0), frame(y: 0, height: 3 * Self.row), owners: [.project("root")]),
            "short": record(session(in: "root", depth: 0), frame(y: Self.row), owners: [.project("root")]),
        ]

        XCTAssertEqual(hit(1.5 * Self.row, in: rows)?.id, "short")
    }

    func testAPointOutsideEveryBlockHitsNothing() {
        XCTAssertNil(hit(20 * Self.row, in: groupWithBlankWash))
    }

    // MARK: Pinned drags

    /// Rows top to bottom, half a row of blank between some of them:
    /// root header; group (header, pinned g1, blank, g2); root's own blank;
    /// other (header, blank, o1); then the empty project far (header,
    /// placeholder).
    private var pinnedLayout: [String: Controller.RowRecord] {
        let group: [Controller.ShellOwner] = [.project("root"), .group("group")]
        let other: [Controller.ShellOwner] = [.project("root"), .group("other")]
        return [
            "root": record(.project, frame(y: 0), owners: [.project("root")]),
            "group": record(folder(in: "root", depth: 1, pinned: true), frame(y: Self.row), owners: group),
            "g1": record(session(in: "group", depth: 1, pinned: true), frame(y: 2 * Self.row), owners: group),
            "g2": record(session(in: "group", depth: 1), frame(y: 3.5 * Self.row), owners: group),
            "other": record(folder(in: "root", depth: 1), frame(y: 5 * Self.row), owners: other),
            "o1": record(session(in: "other", depth: 1), frame(y: 6.5 * Self.row), owners: other),
            "far": record(.project, frame(y: 7.5 * Self.row), owners: [.project("far")]),
            "empty:far": record(nil, frame(y: 8.5 * Self.row), owners: [.project("far")]),
        ]
    }

    /// The y of each blank region in `pinnedLayout`.
    private static let groupWash = 3.25 * row
    private static let rootOwnBlank = 4.75 * row
    private static let otherWash = 6.25 * row
    private static let farPlaceholder = 9 * row

    private func pinnedAction(
        partition parentID: String, source sourceID: String, at y: CGFloat
    ) -> Controller.PinnedSidebarHitAction? {
        guard let target = hit(y, in: pinnedLayout) else { return nil }
        return Controller.pinnedSidebarHitAction(
            boundary: .partition(parentID: parentID),
            sourceID: sourceID,
            targetID: target.id,
            targetKind: target.kind,
            firstReorderID: nil
        )
    }

    func testPinnedSessionAllowsItsOwnGroupsWashAndDeniesEveryOtherBlock() {
        XCTAssertEqual(pinnedAction(partition: "group", source: "g1", at: Self.groupWash), .allow)
        XCTAssertEqual(
            pinnedAction(partition: "group", source: "g1", at: Self.otherWash), .deny,
            "a sibling group's wash is outside the pinned partition"
        )
        XCTAssertEqual(
            pinnedAction(partition: "group", source: "g1", at: Self.rootOwnBlank), .deny,
            "the parent project's blank space is outside the group's partition"
        )
        XCTAssertEqual(
            pinnedAction(partition: "group", source: "g1", at: Self.farPlaceholder), .deny,
            "another project's placeholder is outside the partition"
        )
    }

    func testPinnedSessionOfAProjectAllowsThatProjectsBlankSpace() {
        XCTAssertEqual(pinnedAction(partition: "root", source: "r1", at: Self.rootOwnBlank), .allow)
        XCTAssertEqual(pinnedAction(partition: "root", source: "r1", at: Self.farPlaceholder), .deny)
    }

    func testPinnedGroupAllowsItsOwnWashAndDeniesASiblingGroups() {
        XCTAssertEqual(pinnedAction(partition: "root", source: "group", at: Self.groupWash), .allow)
        XCTAssertEqual(pinnedAction(partition: "root", source: "group", at: Self.otherWash), .deny)
    }

    // MARK: Project reorder target

    /// alpha: header and four Sessions (0 to 5 rows, midpoint 2.5 rows); a
    /// 1pt stack gap; beta: header and two Sessions.
    private var twoProjects: [String: Controller.RowRecord] {
        let betaTop = 5 * Self.row + 1
        let alpha = (0..<4).map { index in
            ("a\(index)", record(
                session(in: "alpha", depth: 0),
                frame(y: CGFloat(index + 1) * Self.row),
                owners: [.project("alpha")]
            ))
        }
        let beta = (0..<2).map { index in
            ("b\(index)", record(
                session(in: "beta", depth: 0),
                frame(y: betaTop + CGFloat(index + 1) * Self.row),
                owners: [.project("beta")]
            ))
        }
        let headers = [
            ("alpha", record(.project, frame(y: 0), owners: [.project("alpha")])),
            ("beta", record(.project, frame(y: betaTop), owners: [.project("beta")])),
        ]
        return Dictionary(uniqueKeysWithValues: headers + alpha + beta)
    }

    private func block(_ y: CGFloat, in rows: [String: Controller.RowRecord]) -> Controller.ProjectBlockHit? {
        Controller.projectBlock(at: CGPoint(x: 120, y: y), in: rows)
    }

    func testProjectBlockSplitsAboveAndBelowAtTheBlocksMidpoint() {
        XCTAssertEqual(block(0.5 * Self.row, in: twoProjects), .init(id: "alpha", below: false))
        XCTAssertEqual(
            block(2.4 * Self.row, in: twoProjects), .init(id: "alpha", below: false),
            "the header alone would have put this point below"
        )
        XCTAssertEqual(
            block(4 * Self.row, in: twoProjects), .init(id: "alpha", below: true),
            "a nested Session row doesn't punch a hole in its project's block"
        )
        XCTAssertEqual(block(5.5 * Self.row, in: twoProjects), .init(id: "beta", below: false))
        XCTAssertEqual(block(7.5 * Self.row, in: twoProjects), .init(id: "beta", below: true))
    }

    func testTheGapBetweenProjectBlocksHitsNoBlock() {
        XCTAssertNil(block(5 * Self.row + 0.5, in: twoProjects))
    }

    func testAPartlyMountedBlockSplitsAtTheMidpointOfItsMountedPart() {
        // Only Sessions 3–5 of a long project are mounted (its header and
        // first rows sit outside the lazy window): rows 4 to 7, midpoint 5.5.
        let rows = Dictionary(uniqueKeysWithValues: (3..<6).map { index in
            ("s\(index)", record(
                session(in: "long", depth: 0),
                frame(y: CGFloat(index + 1) * Self.row),
                owners: [.project("long")]
            ))
        })

        XCTAssertEqual(block(5.4 * Self.row, in: rows), .init(id: "long", below: false))
        XCTAssertEqual(block(5.6 * Self.row, in: rows), .init(id: "long", below: true))
    }

    func testATopLevelGroupHasNoProjectBlockSoItsHeaderAnswers() {
        let group: [Controller.ShellOwner] = [.group("folder")]
        let rows = [
            "folder": record(.project, frame(y: 0), owners: group),
            "f1": record(session(in: "folder", depth: 0), frame(y: Self.row), owners: group),
            "f2": record(session(in: "folder", depth: 0), frame(y: 2 * Self.row), owners: group),
        ]

        XCTAssertEqual(
            block(0.7 * Self.row, in: rows), .init(id: "folder", below: true),
            "the header's own midpoint splits it"
        )
        XCTAssertNil(block(1.5 * Self.row, in: rows), "a top-level group's rows are not a project block")
    }
}
