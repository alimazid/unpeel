import AppKit
import Combine
import UnpeelShared
import XCTest
@testable import UnpeelNative

/// The store's cached live PROJECTS rows (#44). After every kind of store
/// change, the cache must equal a fresh flatten of the same store, so a
/// missed invalidation can never leave a stale sidebar. The store runs as a
/// client of a fixture Host (the shipped Local path) in the bundle's private
/// home (`TestHomeIsolationTests`). No step may run a Host verb: with no
/// Host behind the fixture it fails, and the failure opens a modal NSAlert
/// that blocks the test run.
@MainActor
final class SidebarTreeRowsCacheTests: XCTestCase {
    func testEveryKindOfStoreChangeKeepsTheCacheEqualToAFreshFlatten() {
        var host = FixtureHost()
        let store = makeStore(host)

        // Nodes.
        expectFreshRows(store, "a Session rename") {
            host.edit("s1") { $0.title = "renamed" }
            store.projectRemoteScope(snapshot: host.snapshot)
        }
        expectFreshRows(store, "a group label edit") {
            host.editProject("group") { $0.name = "Renamed group" }
            store.projectRemoteScope(snapshot: host.snapshot)
        }
        expectFreshRows(store, "a live → stopped change") {
            host.edit("s2") { $0.status = .exited }
            store.projectRemoteScope(snapshot: host.snapshot)
        }
        expectFreshRows(store, "a stopped → live change") {
            host.edit("s3") { $0.status = .running }
            store.projectRemoteScope(snapshot: host.snapshot)
        }
        expectFreshRows(store, "a busy/idle flip") {
            host.edit("s1") { $0.activity = .working }
            store.projectRemoteScope(snapshot: host.snapshot)
        }

        // Expansion.
        expectFreshRows(store, "collapsing a group") {
            store.toggleProjectExpanded("group")
        }
        expectFreshRows(store, "expanding a group") {
            store.toggleProjectExpanded("group")
        }

        // Pins and order.
        expectFreshRows(store, "a Host pin flag (nodes unchanged)") {
            host.edit("g1") { $0.pinned = true }
            store.projectRemoteScope(snapshot: host.snapshot)
        }
        expectFreshRows(store, "a pinned group") {
            host.editProject("group") { $0.pinned = true }
            store.projectRemoteScope(snapshot: host.snapshot)
        }
        expectFreshRows(store, "a Host row order change") {
            host.move("s1", after: "s3")
            store.projectRemoteScope(snapshot: host.snapshot)
        }
        expectFreshRows(store, "another frontend's folder-only move (session-order.json)") {
            host.editProject("project") { $0.sessionOrder = ["s3", "wt", "s1", "group"] }
            store.projectRemoteScope(snapshot: host.snapshot)
        }
        expectFreshRows(store, "a drag preview") {
            store.previewSessionMove(projectID: "project", draggedID: "s1", over: "s3")
        }
        expectFreshRows(store, "the worktrees feature turning off") {
            store.setExperimental(false, for: .worktrees)
        }
        expectFreshRows(store, "the worktrees feature turning on") {
            store.setExperimental(true, for: .worktrees)
        }

        // Stopped windowing (a Host-served list arrives windowed).
        expectFreshRows(store, "the Host's stopped window dropping a row") {
            host.remove("s2")
            store.projectRemoteScope(snapshot: host.snapshot)
        }

        // Pane membership.
        store.selectedSessionID = "s1"
        expectFreshRows(store, "opening a pane group") {
            store.splitTerminal(with: "s3", near: nil)
        }
        expectFreshRows(store, "closing the pane group") {
            guard let groupID = store.paneLayoutState.group(containingSession: "s1")?.id
            else { return XCTFail("splitting s3 next to s1 formed no pane group") }
            store.closeTerminalPaneGroup(groupID)
        }
        expectFreshRows(store, "reopening the pane group") {
            store.splitTerminal(with: "s3", near: nil)
        }
        expectFreshRows(store, "a pane member stopping") {
            host.edit("s3") { $0.status = .exited }
            store.projectRemoteScope(snapshot: host.snapshot)
        }
    }

    func testAScopeFlipKeepsTheCacheEqualToAFreshFlatten() {
        let host = FixtureHost()
        let store = makeStore(host)
        var elsewhere = FixtureHost()
        elsewhere.editProject("project") { $0.name = "Elsewhere" }
        elsewhere.edit("s1") { $0.title = "elsewhere" }
        let otherHome = LaunchConfig.unpeelDir
            .appendingPathComponent("scope-\(UUID().uuidString.prefix(6))").path

        expectFreshRows(store, "selecting another workspace") {
            store.selectLocalWorkspace(home: otherHome, name: "Elsewhere")
        }
        expectFreshRows(store, "that workspace's first bootstrap") {
            store.projectRemoteScope(snapshot: elsewhere.snapshot)
        }
        expectFreshRows(store, "back to Local") {
            store.selectHost(nil)
        }
        expectFreshRows(store, "Local's bootstrap again") {
            store.projectRemoteScope(snapshot: host.snapshot)
        }
    }

    /// The Controller's own stopped window applies to lists it scans from
    /// disk (Host-served lists arrive windowed): the launch seed, before
    /// the first bootstrap.
    func testTheLocalStoppedWindowKeepsTheCacheEqualToAFreshFlatten() throws {
        _ = NSApplication.shared
        let store = UnpeelStore(paneLayoutController: PaneLayoutController(
            fileURL: LaunchConfig.unpeelDir
                .appendingPathComponent("panes-\(UUID().uuidString.prefix(6)).json")
        ))
        let token = UUID().uuidString.prefix(6).lowercased()
        let projectDirectory = LaunchConfig.unpeelDir.appendingPathComponent("window-\(token)")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectID = store.addEphemeralProject(path: projectDirectory.path)
        let stoppedIDs = (0..<8).map { "stopped-\(token)-\($0)" }
        for (index, id) in stoppedIDs.enumerated() {
            try writeStoppedManifest(id: id, projectID: projectID, createdAt: 1_000 + Int64(index))
        }
        defer { store.setSidebarStoppedLimit(UnpeelStore.defaultSidebarStoppedLimit) }
        store.setSidebarStoppedLimit(3)
        store.rescan()
        store.expandedProjectIDs = [projectID]
        XCTAssertTrue(
            store.sidebarTreeRows.contains { $0.id == "session:\(stoppedIDs[7])" },
            "the scanned stopped rows render"
        )

        expectFreshRows(store, "a smaller stopped limit") {
            store.setSidebarStoppedLimit(1)
        }
        expectFreshRows(store, "a larger stopped limit") {
            store.setSidebarStoppedLimit(10)
        }
        expectFreshRows(store, "the window closing again") {
            store.setSidebarStoppedLimit(3)
        }
        expectFreshRows(store, "selecting a stopped row past the window") {
            store.selectedSessionID = stoppedIDs[0]
        }
        expectFreshRows(store, "a newly stopped Session") {
            try? self.writeStoppedManifest(
                id: "stopped-\(token)-new", projectID: projectID, createdAt: 2_000
            )
            store.rescan()
        }
    }

    /// The target of a remove confirmation or a rename stays past the
    /// Controller's own stopped window, and leaves it when that ends.
    func testAConfirmOrRenameKeepsAStoppedRowPastTheWindowUntilItEnds() throws {
        _ = NSApplication.shared
        let store = UnpeelStore(paneLayoutController: PaneLayoutController(
            fileURL: LaunchConfig.unpeelDir
                .appendingPathComponent("panes-\(UUID().uuidString.prefix(6)).json")
        ))
        let token = UUID().uuidString.prefix(6).lowercased()
        let projectDirectory = LaunchConfig.unpeelDir.appendingPathComponent("inline-\(token)")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectID = store.addEphemeralProject(path: projectDirectory.path)
        let stoppedIDs = (0..<5).map { "inline-\(token)-\($0)" }
        for (index, id) in stoppedIDs.enumerated() {
            try writeStoppedManifest(id: id, projectID: projectID, createdAt: 1_000 + Int64(index))
        }
        defer { store.setSidebarStoppedLimit(UnpeelStore.defaultSidebarStoppedLimit) }
        store.setSidebarStoppedLimit(3)
        store.rescan()
        store.expandedProjectIDs = [projectID]
        let pastWindow = "session:\(stoppedIDs[0])"
        XCTAssertFalse(store.sidebarTreeRows.contains { $0.id == pastWindow }, "the oldest row is windowed")

        store.confirmingRemoveSessionID = stoppedIDs[0]
        XCTAssertTrue(store.sidebarTreeRows.contains { $0.id == pastWindow }, "a remove confirmation keeps it")
        store.confirmingRemoveSessionID = nil
        XCTAssertFalse(store.sidebarTreeRows.contains { $0.id == pastWindow }, "the cancel windows it again")

        store.editingSessionID = stoppedIDs[0]
        XCTAssertTrue(store.sidebarTreeRows.contains { $0.id == pastWindow }, "a rename keeps it")
        store.editingSessionID = nil
        XCTAssertFalse(store.sidebarTreeRows.contains { $0.id == pastWindow }, "the end of the rename windows it again")
    }

    /// A stop confirmation arms only on a working row, which no window hides.
    /// It counts once that Session stops with the confirmation open, so this
    /// checks the edges reach the choke-point.
    func testAStopConfirmationRebuildsTheRowsWhenItOpensAndCloses() {
        var host = FixtureHost()
        host.edit("s1") {
            $0.activity = .working
            $0.resumable = true
        }
        host.hostCapabilities = [RemoteHostRuntime.HostOperation.stop]
        let store = makeStore(host, heldInRuntime: true)
        let closed = store.sidebarTreeRows

        store.requestStopSession("s1")
        XCTAssertEqual(store.confirmingStopSessionID, "s1")
        let armed = store.sidebarTreeRows
        XCTAssertFalse(sameBuffer(closed, armed), "arming must reach the choke-point")

        store.cancelStopConfirm()
        XCTAssertFalse(sameBuffer(armed, store.sidebarTreeRows), "cancelling must reach the choke-point")
    }

    func testReadingTheRowsNeverPublishes() {
        let store = makeStore(FixtureHost())
        var publishes = 0
        let observer = store.objectWillChange.sink { publishes += 1 }
        defer { observer.cancel() }

        _ = store.sidebarTreeRows
        store.invalidateSidebarLists()
        _ = store.sidebarTreeRows
        _ = store.sidebarTreeRows

        XCTAssertEqual(publishes, 0, "the cached rows are plain storage, never observed")
    }

    // MARK: The list memo (#48)

    func testACancelledDragPutsTheRowsBack() {
        let store = makeStore(FixtureHost(), heldInRuntime: true)
        let before = store.sidebarTreeRows

        store.previewSessionMove(projectID: "project", draggedID: "s1", over: "s2")
        XCTAssertNotEqual(store.sidebarTreeRows.map(\.id), before.map(\.id), "the preview moved s1")
        store.cancelSessionReorder(projectID: "project")

        XCTAssertEqual(store.sidebarTreeRows, before)
    }

    /// A rename on another row defers the projection the cancel re-runs, so
    /// nothing else can drop the previewed order or render the rollback.
    func testACancelledDragPutsTheRowsBackWhileARenameDefersTheProjection() {
        let store = makeStore(FixtureHost(), heldInRuntime: true)
        store.editingSessionID = "s3"
        let before = store.sidebarTreeRows

        store.previewSessionMove(projectID: "project", draggedID: "s1", over: "s2")
        XCTAssertNotEqual(store.sidebarTreeRows.map(\.id), before.map(\.id), "the preview moved s1")
        var publishes = 0
        let observer = store.objectWillChange.sink { publishes += 1 }
        defer { observer.cancel() }
        store.cancelSessionReorder(projectID: "project")

        XCTAssertEqual(store.sidebarTreeRows, before)
        XCTAssertGreaterThan(publishes, 0, "the rollback must render")
    }

    // MARK: Helpers

    private func makeStore(_ host: FixtureHost, heldInRuntime: Bool = false) -> UnpeelStore {
        let store = UnpeelStore.sidebarFixture(
            snapshot: host.snapshot,
            expandedProjectIDs: ["project", "group", "wt", "other"],
            heldInRuntime: heldInRuntime
        )
        XCTAssertFalse(store.sidebarTreeRows.isEmpty, "the fixture Host's tree renders")
        return store
    }

    /// The cache hands back the buffer it built, so two reads held alive share
    /// one only when nothing rebuilt between them.
    private func sameBuffer(_ lhs: [SidebarTreeRow], _ rhs: [SidebarTreeRow]) -> Bool {
        lhs.withUnsafeBufferPointer(\.baseAddress) == rhs.withUnsafeBufferPointer(\.baseAddress)
    }

    /// Warms the cache, applies `change`, then checks that the change reached
    /// the rows and that the cached rows equal a fresh flatten.
    private func expectFreshRows(
        _ store: UnpeelStore,
        _ change: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ mutate: () -> Void
    ) {
        let before = store.sidebarTreeRows
        mutate()
        let cached = store.sidebarTreeRows
        let fresh = freshRows(store)
        XCTAssertNotEqual(before, fresh, "\(change) must change the rows", file: file, line: line)
        XCTAssertEqual(
            cached.map(\.id), fresh.map(\.id),
            "after \(change), the cached row ids are stale", file: file, line: line
        )
        XCTAssertEqual(cached, fresh, "after \(change), the cached rows are stale", file: file, line: line)
    }

    /// An exited hosted Session as the disk scan reads it.
    private func writeStoppedManifest(id: String, projectID: String, createdAt: Int64) throws {
        let directory = LaunchConfig.appSessionsDir.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "session": [
                "id": id, "project_id": projectID, "label": id,
                "command": "zsh", "created_at": createdAt,
            ],
            "state": "exited",
            "updated_at": createdAt,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("manifest.json"))
    }

    /// The live page's flatten with every store memo dropped first.
    private func freshRows(_ store: UnpeelStore) -> [SidebarTreeRow] {
        store.invalidateSidebarLists()
        return SidebarTreeFlattener.rows(
            topLevelNodes: store.displayNodes,
            expandedProjectIDs: store.expandedProjectIDs,
            hiddenSessionIDs: store.activePaneMemberSessionIDs,
            pinnedItems: { store.renderedPinnedItems(in: $0) },
            regularItems: { store.renderedDisplayedItems(in: $0) }
        )
    }
}

/// A Host bootstrap the tests edit step by step: one project holding three
/// Sessions, a group, a worktree and a second project.
private struct FixtureHost {
    struct Session {
        let id: String
        let projectID: String
        var title: String
        var status: RemoteSessionStatus = .running
        var activity: RemoteActivityState = .idle
        var pinned = false
        var resumable = false
        let createdAt: Int64
    }

    struct Project {
        let id: String
        var name: String
        let parentID: String?
        var isGroup = false
        var worktreeBranch: String?
        var pinned = false
        var sessionOrder: [String]?
    }

    private(set) var projects: [Project] = [
        Project(id: "project", name: "Project", parentID: nil),
        Project(id: "group", name: "Group", parentID: "project", isGroup: true),
        Project(id: "wt", name: "wt", parentID: "project", worktreeBranch: "feature"),
        Project(id: "other", name: "Other", parentID: nil),
    ]
    private(set) var sessions: [Session] = [
        Session(id: "s1", projectID: "project", title: "one", createdAt: 5),
        Session(id: "s2", projectID: "project", title: "two", createdAt: 4),
        Session(id: "s3", projectID: "project", title: "three", status: .exited, createdAt: 3),
        Session(id: "g1", projectID: "group", title: "group one", createdAt: 2),
        Session(id: "g2", projectID: "group", title: "group two", createdAt: 1),
        Session(id: "w1", projectID: "wt", title: "worktree one", createdAt: 6),
        Session(id: "o1", projectID: "other", title: "other one", createdAt: 7),
    ]
    var hostCapabilities: [String]?

    mutating func edit(_ id: String, _ change: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
    }

    mutating func editProject(_ id: String, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[index])
    }

    mutating func move(_ id: String, after anchorID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        let anchor = sessions.firstIndex(where: { $0.id == anchorID }) ?? sessions.count - 1
        sessions.insert(session, at: anchor + 1)
    }

    mutating func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
    }

    var snapshot: RemoteBootstrapSnapshot {
        RemoteBootstrapSnapshot(
            hostProtocol: hostCapabilities.map { RemoteHostProtocolDescriptor(capabilities: $0) },
            folders: [],
            projects: projects.enumerated().map { index, project in
                RemoteProjectSummary(
                    id: project.id,
                    name: project.name,
                    path: "/fixture/\(project.id)",
                    parentProjectID: project.parentID,
                    worktreeBranch: project.worktreeBranch,
                    isGroup: project.isGroup ? true : nil,
                    pinned: project.pinned ? true : nil,
                    sortOrder: index,
                    sessionOrder: project.sessionOrder
                )
            },
            presets: [],
            sessions: sessions.map { session in
                RemoteSessionSummary(
                    id: session.id,
                    projectID: session.projectID,
                    title: session.title,
                    command: "zsh",
                    createdAtUnixMs: session.createdAt,
                    status: session.status,
                    activity: session.activity,
                    pinned: session.pinned,
                    capabilities: session.resumable
                        ? RemoteSessionCapabilities(restart: false, notifyWhenDone: false, resumable: true)
                        : nil
                )
            },
            capturedAtUnixMs: 1
        )
    }
}
