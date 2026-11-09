import UnpeelShared
import XCTest
@testable import UnpeelNative

/// Fork-only (#50): what a Host-served list commits when a row lands, and how
/// the dropped order holds until the Host confirms it. No step runs the Host
/// verb: with no Host behind the fixture it fails into a modal NSAlert.
@MainActor
final class SidebarHostFolderOrderTests: XCTestCase {
    // MARK: What a drop commits

    func testADroppedFolderIsRankedWhereItLanded() throws {
        let store = makeStore()
        store.previewSessionMove(projectID: "project", draggedID: "beta", over: "alpha")

        XCTAssertEqual(try committedOrder(store), ["beta", "alpha", "s1", "s2"])
    }

    func testASessionOnlyDragLeavesTheFoldersUnranked() throws {
        let store = makeStore()
        store.previewSessionMove(projectID: "project", draggedID: "s2", over: "s1")

        XCTAssertEqual(try committedOrder(store), ["s2", "s1"])
    }

    func testASessionDroppedAboveAFolderRanksTheFolders() throws {
        let store = makeStore()
        store.previewSessionMove(projectID: "project", draggedID: "s1", over: "beta")

        XCTAssertEqual(try committedOrder(store), ["alpha", "s1", "beta", "s2"])
    }

    func testAListThatAlreadyRanksAFolderKeepsRankingIt() throws {
        let store = makeStore(order: ["alpha", "beta", "s1", "s2"])
        store.previewSessionMove(projectID: "project", draggedID: "s2", over: "s1")

        XCTAssertEqual(try committedOrder(store), ["alpha", "beta", "s2", "s1"])
    }

    func testAPinnedGroupAtTheTopIsStillTheDefaultSlot() throws {
        let store = makeStore(pinnedFolders: ["beta"])
        store.previewSessionMove(projectID: "project", draggedID: "s2", over: "s1")

        XCTAssertEqual(try committedOrder(store), ["s2", "s1"])
    }

    func testACrossProjectInsertLeavingFoldersAloneStaysSessionsOnly() {
        let store = makeStore()

        XCTAssertEqual(
            store.hostRegularOrder(
                projectID: "project",
                ids: ["alpha", "beta", "moved", "s1", "s2"]
            ),
            ["moved", "s1", "s2"]
        )
    }

    func testACrossProjectInsertAboveAFolderKeepsItsRanks() {
        let store = makeStore()
        let ids = ["moved", "alpha", "beta", "s1", "s2"]

        XCTAssertEqual(store.hostRegularOrder(projectID: "project", ids: ids), ids)
    }

    // MARK: Holding the dropped order

    func testAFolderMoveOutlastsAStaleBootstrapUntilTheHostConfirms() throws {
        let store = makeStore()
        store.previewSessionMove(projectID: "project", draggedID: "beta", over: "alpha")
        store.holdCommittedSessionOrder(
            projectID: "project",
            orderedIDs: try committedOrder(store)
        )
        XCTAssertEqual(try regularIDs(store), ["beta", "alpha", "s1", "s2"])

        // A bootstrap captured before the Host applied the write has no ranks.
        store.projectRemoteScope(snapshot: Self.snapshot())
        XCTAssertEqual(
            try regularIDs(store), ["beta", "alpha", "s1", "s2"],
            "a stale bootstrap must not snap the folder back"
        )

        store.projectRemoteScope(snapshot: Self.snapshot(order: ["beta", "alpha", "s1", "s2"]))
        XCTAssertEqual(try regularIDs(store), ["beta", "alpha", "s1", "s2"])

        // The hold let go, so a later Host order is authoritative again.
        store.projectRemoteScope(snapshot: Self.snapshot(order: ["alpha", "s1", "beta", "s2"]))
        XCTAssertEqual(try regularIDs(store), ["alpha", "s1", "beta", "s2"])
    }

    // MARK: Helpers

    private func makeStore(
        order: [String]? = nil,
        pinnedFolders: Set<String> = []
    ) -> UnpeelStore {
        // Collapsed folders: their rows stay out of the list under test.
        UnpeelStore.sidebarFixture(
            snapshot: Self.snapshot(order: order, pinnedFolders: pinnedFolders),
            expandedProjectIDs: ["project"]
        )
    }

    private func committedOrder(_ store: UnpeelStore) throws -> [String] {
        store.hostCommitOrder(in: try XCTUnwrap(store.findDisplayNode("project")))
    }

    private func regularIDs(_ store: UnpeelStore) throws -> [String] {
        store.renderedDisplayedItems(in: try XCTUnwrap(store.findDisplayNode("project")))
            .map(\.id)
    }

    private static func snapshot(
        order: [String]? = nil,
        pinnedFolders: Set<String> = []
    ) -> RemoteBootstrapSnapshot {
        let folders = ["alpha", "beta"].map { id in
            RemoteProjectSummary(
                id: id,
                name: id,
                path: "/fixture/\(id)",
                parentProjectID: "project",
                isGroup: true,
                pinned: pinnedFolders.contains(id) ? true : nil
            )
        }
        return RemoteBootstrapSnapshot(
            folders: [],
            projects: [
                RemoteProjectSummary(
                    id: "project",
                    name: "Project",
                    path: "/fixture/project",
                    sessionOrder: order
                ),
            ] + folders,
            presets: [],
            sessions: ["s1", "s2"].map { id in
                RemoteSessionSummary(
                    id: id,
                    projectID: "project",
                    title: id,
                    command: "zsh",
                    createdAtUnixMs: 1,
                    status: .running,
                    activity: .idle
                )
            },
            capturedAtUnixMs: 1
        )
    }
}
