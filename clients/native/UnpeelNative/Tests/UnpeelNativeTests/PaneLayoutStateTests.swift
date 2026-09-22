import Foundation
import XCTest
@testable import UnpeelNative

/// Swift-side unit tests for the split-tree pane model. Cross-implementation
/// operation semantics live in the shared fixture (see
/// PaneLayoutOperationsConformanceTests); these cover the Swift-only
/// contracts: id canonicalization, structural identity, clamping, error
/// paths the fixture cannot express, and legacy codec tolerance.
final class PaneLayoutStateTests: XCTestCase {
    private let paneA = "00000000-0000-4000-8000-00000000000a"
    private let paneB = "00000000-0000-4000-8000-00000000000b"
    private let paneC = "00000000-0000-4000-8000-00000000000c"
    private let groupID = "11111111-0000-4000-8000-000000000001"

    private func twoPaneState() -> PaneLayoutState {
        PaneLayoutState(groups: [
            PaneGroup(
                id: groupID,
                representativePaneID: paneA,
                root: .split(PaneSplit(
                    direction: .horizontal,
                    ratio: 0.6,
                    left: .leaf(Pane(id: paneA, content: .session(id: "s1"))),
                    right: .leaf(Pane(id: paneB, content: .session(id: "s2")))
                ))
            ),
        ])
    }

    // MARK: Identity

    func testNonUUIDPaneIDsAreReplacedWithCanonicalOnes() {
        let pane = Pane(id: "p1", content: .session(id: "s1"))
        XCTAssertNotEqual(pane.id, "p1")
        XCTAssertNotNil(UUID(uuidString: pane.id))
        XCTAssertEqual(pane.id, pane.id.lowercased())

        let canonical = Pane(id: paneA.uppercased(), content: .session(id: "s1"))
        XCTAssertEqual(canonical.id, paneA)
    }

    func testStructuralIdentityIgnoresRatioChanges() throws {
        var state = twoPaneState()
        let before = try XCTUnwrap(state.group(id: groupID)).root.structuralIdentity

        // Ratio-only mutations must not change SwiftUI identity: a divider
        // drag can never remount retained terminal surfaces.
        try state.resizeSplit(in: groupID, at: PaneSplitPath(), ratio: 0.31)
        let afterResize = try XCTUnwrap(state.group(id: groupID)).root.structuralIdentity
        XCTAssertEqual(before, afterResize)

        try state.equalize(groupID: groupID)
        let afterEqualize = try XCTUnwrap(state.group(id: groupID)).root.structuralIdentity
        XCTAssertEqual(before, afterEqualize)
    }

    func testStructuralIdentityTracksShapeAndContent() throws {
        var state = twoPaneState()
        let before = try XCTUnwrap(state.group(id: groupID)).root.structuralIdentity

        try state.insertSession(
            "s3", splitting: paneB, edge: .down, newPaneID: paneC
        )
        let afterInsert = try XCTUnwrap(state.group(id: groupID)).root.structuralIdentity
        XCTAssertNotEqual(before, afterInsert)

        try state.detachPane(paneC)
        let afterDetach = try XCTUnwrap(state.group(id: groupID)).root.structuralIdentity
        XCTAssertEqual(before, afterDetach)
    }

    // MARK: Clamping

    func testSplitInitClampsRatio() {
        let leaf = PaneNode.leaf(Pane(id: paneA, content: .session(id: "s1")))
        let other = PaneNode.leaf(Pane(id: paneB, content: .session(id: "s2")))
        XCTAssertEqual(
            PaneSplit(direction: .horizontal, ratio: 0.02, left: leaf, right: other).ratio,
            PaneLayoutState.minimumSplitRatio
        )
        XCTAssertEqual(
            PaneSplit(direction: .horizontal, ratio: 0.99, left: leaf, right: other).ratio,
            PaneLayoutState.maximumSplitRatio
        )
        XCTAssertEqual(
            PaneSplit(direction: .horizontal, ratio: .nan, left: leaf, right: other).ratio,
            0.5
        )
    }

    func testResizeRejectsNonFiniteRatio() {
        var state = twoPaneState()
        XCTAssertThrowsError(
            try state.resizeSplit(in: groupID, at: PaneSplitPath(), ratio: .nan)
        ) { error in
            XCTAssertEqual(error as? PaneLayoutError, .invalidRatio)
        }
    }

    // MARK: Error paths the fixture cannot express

    func testEmptySessionIDsAreRejected() {
        var state = twoPaneState()
        XCTAssertThrowsError(
            try state.insertSession("", splitting: paneA, edge: .right)
        ) { error in
            XCTAssertEqual(error as? PaneLayoutError, .invalidSessionID)
        }
        XCTAssertThrowsError(
            try state.insertSession("s9", beside: "", at: .right)
        ) { error in
            XCTAssertEqual(error as? PaneLayoutError, .invalidSessionID)
        }
    }

    func testCreateGroupRejectsSameSession() {
        var state = PaneLayoutState()
        XCTAssertThrowsError(
            try state.createGroup(
                representativeSessionID: "s1", adding: "s1", at: .right
            )
        ) { error in
            XCTAssertEqual(error as? PaneLayoutError, .sameSession)
        }
    }

    func testBindRejectsNonLauncherPane() {
        var state = twoPaneState()
        XCTAssertThrowsError(
            try state.bindLauncher(paneA, toSessionID: "s9")
        ) { error in
            XCTAssertEqual(error as? PaneLayoutError, .paneIsNotLauncher(paneA))
        }
    }

    // MARK: Preorder

    func testLeavesEnumerateInPreorder() {
        let root = PaneNode.split(PaneSplit(
            direction: .vertical,
            ratio: 0.5,
            left: .split(PaneSplit(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(Pane(id: paneA, content: .session(id: "s1"))),
                right: .leaf(Pane(id: paneB, content: .session(id: "s2")))
            )),
            right: .leaf(Pane(id: paneC, content: .session(id: "s3")))
        ))
        XCTAssertEqual(root.leaves.map(\.id), [paneA, paneB, paneC])
    }

    // MARK: Legacy codec tolerance

    func testVersionOneDecodesLegacyRustKeySpellings() throws {
        // The shipped v1 Rust codec wrote `representativePaneId`/`sessionId`
        // while Swift wrote `representativePaneID`/`sessionID`. Migration must
        // accept both so either frontend's dev-machine file upgrades.
        let json = """
        {
          "version": 1,
          "groups": [{
            "id": "\(groupID)",
            "representativePaneId": "\(paneA)",
            "panes": [
              { "id": "\(paneA)", "sessionId": "s1", "fraction": 0.7 },
              { "id": "\(paneB)", "sessionId": "s2", "fraction": 0.3 }
            ]
          }]
        }
        """
        let durable = try JSONDecoder().decode(
            DurablePaneLayout.self, from: Data(json.utf8)
        )
        let state = durable.restoredState()
        let group = try XCTUnwrap(state.groups.first)
        XCTAssertEqual(group.representativePaneID, paneA)
        XCTAssertEqual(group.sessionIDs, ["s1", "s2"])
        guard case let .split(split) = group.root else {
            return XCTFail("expected migrated split root")
        }
        XCTAssertEqual(split.direction, .horizontal)
        XCTAssertEqual(split.ratio, 0.7, accuracy: 1e-9)
    }

    func testUnknownFutureVersionDecodesEmptyButKeepsVersion() throws {
        let json = #"{"version": 99, "groups": [{"whatever": true}]}"#
        let durable = try JSONDecoder().decode(
            DurablePaneLayout.self, from: Data(json.utf8)
        )
        XCTAssertEqual(durable.version, 99)
        XCTAssertTrue(durable.groups.isEmpty)
        XCTAssertFalse(DurablePaneLayout.supportedVersions.contains(durable.version))
    }

    func testEncodeAlwaysWritesCurrentVersion() throws {
        let state = twoPaneState()
        let data = try JSONEncoder().encode(DurablePaneLayout(state: state))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["version"] as? Int, DurablePaneLayout.currentVersion)
        let groups = try XCTUnwrap(json["groups"] as? [[String: Any]])
        let root = try XCTUnwrap(groups.first?["root"] as? [String: Any])
        XCTAssertNotNil(root["split"])
    }

    // MARK: Durable round trip

    func testDurableRoundTripPreservesIDsAndGeometry() throws {
        var state = twoPaneState()
        try state.insertSession("s3", splitting: paneB, edge: .down, newPaneID: paneC)
        try state.resizeSplit(
            in: groupID,
            at: PaneSplitPath([.right]),
            ratio: 0.42
        )

        let encoded = try JSONEncoder().encode(DurablePaneLayout(state: state))
        let decoded = try JSONDecoder().decode(DurablePaneLayout.self, from: encoded)
        let restored = decoded.restoredState()

        XCTAssertEqual(restored.groups.map(\.id), state.groups.map(\.id))
        XCTAssertEqual(
            restored.groups.flatMap(\.panes).map(\.id),
            state.groups.flatMap(\.panes).map(\.id)
        )
        XCTAssertEqual(
            try XCTUnwrap(restored.group(id: groupID)).root.structuralIdentity,
            try XCTUnwrap(state.group(id: groupID)).root.structuralIdentity
        )
    }

    // MARK: Spatial navigation is geometry-independent

    func testSpatialNeighborUsesGridDimensionsNotRatios() throws {
        // Extreme ratios must not change neighbor answers: navigation uses
        // artificial grid dimensions, a pure function of the tree.
        var state = twoPaneState()
        try state.resizeSplit(in: groupID, at: PaneSplitPath(), ratio: 0.1)
        XCTAssertEqual(
            state.spatialNeighbor(ofPane: paneA, direction: .right)?.id,
            paneB
        )
        XCTAssertEqual(
            state.spatialNeighbor(ofPane: paneB, direction: .left)?.id,
            paneA
        )
        XCTAssertNil(state.spatialNeighbor(ofPane: paneA, direction: .up))
        XCTAssertNil(state.spatialNeighbor(ofPane: paneA, direction: .down))
    }

    // MARK: - Fork-only: markdown preview leaves

    private let previewPath = "/r/README.md"

    func testInsertMarkdownPreviewBesideSoloSessionCreatesGroupOnTheRight() throws {
        var state = PaneLayoutState(groups: [])
        let location = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let group = try XCTUnwrap(state.group(id: location.groupID))
        XCTAssertEqual(group.sessionIDs, ["s1"])
        XCTAssertEqual(group.root.leaves.map(\.content), [.session(id: "s1"), .markdownPreview(path: previewPath)])
        guard case let .split(split) = group.root else { return XCTFail("expected a split") }
        XCTAssertEqual(split.direction, .horizontal)
        XCTAssertEqual(split.ratio, 0.5)
        XCTAssertEqual(group.representativeSessionID, "s1")
    }

    func testInsertMarkdownPreviewBesideGroupedSessionSplitsThatLeaf() throws {
        var state = twoPaneState()
        let location = try state.insertMarkdownPreview(path: previewPath, beside: "s2", at: .right)
        XCTAssertEqual(location.groupID, groupID)
        let group = try XCTUnwrap(state.group(id: groupID))
        XCTAssertEqual(group.root.leaves.map(\.content), [.session(id: "s1"), .session(id: "s2"), .markdownPreview(path: previewPath)])
        XCTAssertEqual(group.root.sessionLeaves.count, 2)
    }

    func testLocationOfMarkdownPreviewFindsOnlyWithinTheSessionsGroup() throws {
        var state = twoPaneState()
        let inserted = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        XCTAssertEqual(state.location(ofMarkdownPreview: previewPath, inGroupContaining: "s2"), inserted)
        XCTAssertNil(state.location(ofMarkdownPreview: "/r/other.md", inGroupContaining: "s1"))
        XCTAssertNil(state.location(ofMarkdownPreview: previewPath, inGroupContaining: "s9"))
    }

    func testInsertMarkdownPreviewRejectsAnEmptyPath() throws {
        var state = twoPaneState()
        XCTAssertThrowsError(try state.insertMarkdownPreview(path: "", beside: "s1", at: .right)) {
            XCTAssertEqual($0 as? PaneLayoutError, .invalidMarkdownPreviewPath)
        }
    }

    // Fork-only: markdown preview pane — M6: previews are exempt from the
    // session cap, but not uncapped.
    func testInsertMarkdownPreviewCapsLeavesPerGroup() throws {
        var state = PaneLayoutState(groups: [])
        var location = try state.insertMarkdownPreview(path: "/r/0.md", beside: "s1", at: .right)
        for index in 1..<PaneLayoutState.maximumMarkdownPreviewLeafCount {
            location = try state.insertMarkdownPreview(path: "/r/\(index).md", beside: "s1", at: .right)
        }
        let group = try XCTUnwrap(state.group(id: location.groupID))
        XCTAssertEqual(
            group.root.leaves.filter { $0.content.markdownPreviewPath != nil }.count,
            PaneLayoutState.maximumMarkdownPreviewLeafCount
        )
        XCTAssertThrowsError(try state.insertMarkdownPreview(path: "/r/overflow.md", beside: "s1", at: .right)) {
            XCTAssertEqual($0 as? PaneLayoutError, .capacityReached(location.groupID))
        }
    }

    func testInsertingAPreviewClearsTheLauncherSnapshot() throws {
        var state = twoPaneState()
        _ = try state.insertLauncher(projectID: "p", splitting: paneA, edge: .right)
        XCTAssertNotNil(state.groups[0].preLauncherRoot)
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s2", at: .right)
        XCTAssertNil(state.groups[0].preLauncherRoot)
    }

    func testValidateCapacityStillCountsALiveLauncherWithPreviewsPresent() throws {
        var state = PaneLayoutState(groups: [])
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        for index in 2...(PaneLayoutState.maximumSessionLeafCount - 1) {
            try state.insertSession("s\(index)", beside: "s1", at: .right)
        }
        XCTAssertEqual(
            state.groups[0].root.sessionLeaves.count,
            PaneLayoutState.maximumSessionLeafCount - 1
        )
        _ = try state.insertLauncher(projectID: "p", beside: "s1", at: .right)
        XCTAssertThrowsError(try state.insertSession("s99", beside: "s1", at: .right))
        _ = try state.insertMarkdownPreview(path: "/r/more.md", beside: "s1", at: .right)
    }

    func testPreviewLeavesDoNotCountTowardTheSessionCap() throws {
        var state = PaneLayoutState(groups: [])
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        for index in 2...PaneLayoutState.maximumSessionLeafCount {
            try state.insertSession("s\(index)", beside: "s1", at: .right)
        }
        XCTAssertEqual(state.groups[0].root.sessionLeaves.count, PaneLayoutState.maximumSessionLeafCount)
        XCTAssertThrowsError(try state.insertSession("s99", beside: "s1", at: .right))
        _ = try state.insertMarkdownPreview(path: "/r/more.md", beside: "s1", at: .right)
    }

    func testDetachingTheLastSessionDissolvesTheGroupWithItsPreviews() throws {
        var state = PaneLayoutState(groups: [])
        let location = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let sessionPane = try XCTUnwrap(state.location(ofSession: "s1"))
        let change = try state.detachPane(sessionPane.paneID)
        XCTAssertTrue(change.dissolved)
        XCTAssertTrue(state.groups.isEmpty)
        XCTAssertNil(state.location(ofPane: location.paneID))
    }

    func testDetachingAPreviewKeepsASessionPlusPreviewGroupOtherwiseDissolves() throws {
        var state = PaneLayoutState(groups: [])
        let first = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let second = try state.insertMarkdownPreview(path: "/r/b.md", beside: "s1", at: .right)
        XCTAssertFalse(try state.detachPane(second.paneID).dissolved)
        XCTAssertEqual(state.groups.count, 1)
        XCTAssertTrue(try state.detachPane(first.paneID).dissolved)
        XCTAssertTrue(state.groups.isEmpty)
    }

    func testReconcileDropsPreviewsWhenTheirGroupLosesItsSessions() throws {
        var state = PaneLayoutState(groups: [])
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let changes = state.reconcile(eligibleSessionIDs: [])
        XCTAssertEqual(changes.map(\.dissolved), [true])
        XCTAssertTrue(state.groups.isEmpty)

        var kept = PaneLayoutState(groups: [])
        _ = try kept.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        XCTAssertTrue(kept.reconcile(eligibleSessionIDs: ["s1"]).isEmpty)
        XCTAssertEqual(kept.groups.count, 1)
    }

    func testDurableLayoutStripsPreviewLeaves() throws {
        var state = twoPaneState()
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let durable = try XCTUnwrap(DurablePaneGroup(group: state.groups[0]))
        XCTAssertEqual(durable.root.paneNode().leaves.map(\.content), [.session(id: "s1"), .session(id: "s2")])

        var solo = PaneLayoutState(groups: [])
        _ = try solo.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        XCTAssertNil(DurablePaneGroup(group: solo.groups[0]))
    }

    // Fork-only: markdown preview pane — the launcher-snapshot branch must
    // strip previews too, not just the direct-root branch above.
    func testDurableLayoutStripsPreviewsFromTheLauncherSnapshot() throws {
        var state = twoPaneState()
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        _ = try state.insertLauncher(projectID: "p", splitting: paneA, edge: .right)
        let durable = try XCTUnwrap(DurablePaneGroup(group: state.groups[0]))
        XCTAssertEqual(
            durable.root.paneNode().leaves.map(\.content),
            [.session(id: "s1"), .session(id: "s2")]
        )
    }

    func testStructuralIdentityDistinguishesPreviewPaths() throws {
        var a = PaneLayoutState(groups: [])
        _ = try a.insertMarkdownPreview(
            path: previewPath, beside: "s1", at: .right,
            newGroupID: groupID, newRepresentativePaneID: paneA, newPaneID: paneB
        )
        var b = PaneLayoutState(groups: [])
        _ = try b.insertMarkdownPreview(
            path: "/r/b.md", beside: "s1", at: .right,
            newGroupID: groupID, newRepresentativePaneID: paneA, newPaneID: paneB
        )
        XCTAssertNotEqual(a.groups[0].root.structuralIdentity, b.groups[0].root.structuralIdentity)
    }

    func testCanonicalizeDedupesPreviewPathsAndKeepsSessionPlusPreview() {
        let state = PaneLayoutState(groups: [
            PaneGroup(
                id: groupID,
                representativePaneID: paneA,
                root: .split(PaneSplit(
                    direction: .horizontal, ratio: 0.5,
                    left: .leaf(Pane(id: paneA, content: .session(id: "s1"))),
                    right: .split(PaneSplit(
                        direction: .horizontal, ratio: 0.5,
                        left: .leaf(Pane(id: paneB, content: .markdownPreview(path: previewPath))),
                        right: .leaf(Pane(id: paneC, content: .markdownPreview(path: previewPath)))
                    ))
                ))
            ),
        ])
        XCTAssertEqual(state.groups.count, 1)
        XCTAssertEqual(state.groups[0].root.leaves.map(\.id), [paneA, paneB])
    }
}
