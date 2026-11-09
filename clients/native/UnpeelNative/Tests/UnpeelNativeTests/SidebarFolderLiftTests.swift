import UnpeelShared
import XCTest
@testable import UnpeelNative

/// Fork-only (#53): what a lifted folder does to the list. It lists as
/// collapsed for the drag and drags in the one-slot gap; on a Host-served list a
/// pinned folder moves among the pinned folders only. No step runs a Host verb:
/// with no Host behind the fixture it fails into a modal NSAlert.
@MainActor
final class SidebarFolderLiftTests: XCTestCase {
    // MARK: Collapse on lift

    func testALiftedFolderListsAsCollapsedForTheDrag() {
        let store = makeStore(expanded: ["project", "alpha", "beta"])
        XCTAssertEqual(rowIDs(store), [
            "folder:project", "folder:alpha", "session:a1", "folder:beta", "session:b1",
            "folder:gamma", "session:s1", "session:s2",
        ])

        store.collapseFolderForLift("beta")

        XCTAssertEqual(rowIDs(store), [
            "folder:project", "folder:alpha", "session:a1", "folder:beta",
            "folder:gamma", "session:s1", "session:s2",
        ])
        let header = store.sidebarTreeRows.first { $0.id == "folder:beta" }
        XCTAssertEqual(header?.content.isExpanded, false, "its header reads collapsed too")
    }

    func testEndingTheLiftBringsTheFolderBack() {
        let store = makeStore(expanded: ["project", "alpha", "beta"])
        let before = rowIDs(store)

        store.collapseFolderForLift("beta")
        store.endFolderLift()

        XCTAssertEqual(rowIDs(store), before)
    }

    func testALiftNeverSavesTheFolderAsCollapsed() {
        let store = makeStore(expanded: ["project", "alpha", "beta"])

        store.collapseFolderForLift("beta")

        XCTAssertTrue(store.expandedProjectIDs.contains("beta"), "a quit mid-drag restores it open")
    }

    func testAFolderCollapsedBeforeTheLiftStaysCollapsed() {
        let store = makeStore(expanded: ["project", "alpha"])
        let before = rowIDs(store)

        store.collapseFolderForLift("beta")
        XCTAssertEqual(rowIDs(store), before)
        store.endFolderLift()

        XCTAssertEqual(rowIDs(store), before)
        XCTAssertFalse(store.expandedProjectIDs.contains("beta"))
    }

    // MARK: Which rows a drag reorders among

    func testARegularDragReordersTheWholeListWhenNothingIsPinned() throws {
        let store = makeStore(expanded: ["project"])

        let section = try reorderSection(store, draggedID: "gamma", pinned: false)

        XCTAssertEqual(section.ids, ["alpha", "beta", "gamma", "s1", "s2"])
        XCTAssertTrue(section.headerAnchorsTop)
    }

    func testAPinnedFolderReordersAmongThePinnedFoldersOnly() throws {
        let store = makeStore(expanded: ["project"], pinnedFolders: ["alpha", "gamma"])

        let section = try reorderSection(store, draggedID: "gamma", pinned: true)

        XCTAssertEqual(section.ids, ["alpha", "gamma"])
        XCTAssertTrue(section.headerAnchorsTop)
    }

    func testAnUnpinnedFolderHasNoSlotAboveAPinnedOne() throws {
        let store = makeStore(expanded: ["project"], pinnedFolders: ["gamma"])

        let section = try reorderSection(store, draggedID: "beta", pinned: false)

        XCTAssertEqual(section.ids, ["alpha", "beta", "s1", "s2"])
        XCTAssertFalse(section.headerAnchorsTop, "the pinned block sits between the header and this list")
    }

    func testASessionHasNoSlotAboveAPinnedFolder() throws {
        let store = makeStore(expanded: ["project"], pinnedFolders: ["alpha"])

        let section = try reorderSection(store, draggedID: "s2", pinned: false)

        XCTAssertEqual(section.ids, ["beta", "gamma", "s1", "s2"])
    }

    // MARK: A pinned folder's drop on a Host-served list

    func testAPinnedFolderDropsAmongThePinnedFolders() throws {
        let store = makeStore(expanded: ["project"], pinnedFolders: ["alpha", "beta"])

        store.previewPinnedSessionMove(projectID: "project", draggedID: "beta", over: "alpha")

        let node = try XCTUnwrap(store.findDisplayNode("project"))
        XCTAssertEqual(
            store.renderedDisplayedItems(in: node).map(\.id),
            ["beta", "alpha", "gamma", "s1", "s2"]
        )
        XCTAssertEqual(store.hostCommitOrder(in: node), ["beta", "alpha", "gamma", "s1", "s2"])
    }

    func testAPinnedSessionStillDropsAmongThePinnedSessions() throws {
        let store = UnpeelStore.sidebarFixture(
            snapshot: Self.snapshot(pinnedFolders: ["alpha"], pinnedSessions: ["s1", "s2"]),
            expandedProjectIDs: ["project"]
        )
        let node = try XCTUnwrap(store.findDisplayNode("project"))
        let before = store.renderedPinnedSessions(in: node).map(\.id)

        store.previewPinnedSessionMove(projectID: "project", draggedID: before[1], over: before[0])

        let moved = try XCTUnwrap(store.findDisplayNode("project"))
        XCTAssertEqual(store.renderedPinnedSessions(in: moved).map(\.id), [before[1], before[0]])
        XCTAssertEqual(store.renderedDisplayedItems(in: moved).first?.id, "alpha", "the pinned folder stays put")
    }

    // MARK: Helpers

    private func reorderSection(
        _ store: UnpeelStore,
        draggedID: String,
        pinned: Bool
    ) throws -> SidebarReorderSection {
        store.sidebarReorderSection(
            in: try XCTUnwrap(store.findDisplayNode("project")),
            pinned: pinned,
            draggedID: draggedID
        )
    }

    private func makeStore(
        expanded: Set<String>,
        pinnedFolders: Set<String> = []
    ) -> UnpeelStore {
        UnpeelStore.sidebarFixture(
            snapshot: Self.snapshot(pinnedFolders: pinnedFolders),
            expandedProjectIDs: expanded
        )
    }

    private func rowIDs(_ store: UnpeelStore) -> [String] {
        store.sidebarTreeRows.map(\.id)
    }

    private static func snapshot(
        pinnedFolders: Set<String>,
        pinnedSessions: Set<String> = []
    ) -> RemoteBootstrapSnapshot {
        let folders = ["alpha", "beta", "gamma"].map { id in
            RemoteProjectSummary(
                id: id,
                name: id,
                path: "/fixture/\(id)",
                parentProjectID: "project",
                isGroup: true,
                pinned: pinnedFolders.contains(id) ? true : nil
            )
        }
        let sessions: [(id: String, projectID: String)] = [
            ("s1", "project"), ("s2", "project"), ("a1", "alpha"), ("b1", "beta"),
        ]
        return RemoteBootstrapSnapshot(
            folders: [],
            projects: [
                RemoteProjectSummary(id: "project", name: "Project", path: "/fixture/project"),
            ] + folders,
            presets: [],
            sessions: sessions.map { session in
                RemoteSessionSummary(
                    id: session.id,
                    projectID: session.projectID,
                    title: session.id,
                    command: "zsh",
                    createdAtUnixMs: 1,
                    status: .running,
                    activity: .idle,
                    pinned: pinnedSessions.contains(session.id)
                )
            },
            capturedAtUnixMs: 1
        )
    }
}
