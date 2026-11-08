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

    // MARK: Helpers

    private func makeStore(_ host: FixtureHost) -> UnpeelStore {
        // Scope switches set NSApp.appearance.
        _ = NSApplication.shared
        let panes = PaneLayoutController(
            fileURL: LaunchConfig.unpeelDir
                .appendingPathComponent("panes-\(UUID().uuidString.prefix(6)).json")
        )
        let store = UnpeelStore(paneLayoutController: panes)
        if !store.isExperimentalEnabled(.worktrees) {
            store.setExperimental(true, for: .worktrees)
        }
        store.markLocalHostClientStartedForTesting()
        store.expandedProjectIDs = ["project", "group", "wt", "other"]
        store.projectRemoteScope(snapshot: host.snapshot)
        XCTAssertFalse(store.sidebarTreeRows.isEmpty, "the fixture Host's tree renders")
        return store
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
                    pinned: session.pinned
                )
            },
            capturedAtUnixMs: 1
        )
    }
}
