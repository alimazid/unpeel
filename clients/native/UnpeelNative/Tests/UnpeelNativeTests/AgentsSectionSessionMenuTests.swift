import Testing
import UnpeelShared
@testable import UnpeelNative

/// Fork-only: the AGENTS section lists the current workspace only and gives
/// its rows the PROJECTS session menu, with inline rename and confirmations
/// owned by exactly one surface.
struct AgentsSectionSessionMenuTests {
    @Test
    func currentWorkspaceProjectionKeepsOnlyTheForegroundRows() {
        let menu = GlobalActivityMenuSessions(
            currentWorkspace: localSlice(),
            key: "local:a",
            row: workspace("local:a", name: "Alpha", tint: .blue)
        )

        #expect(menu.jobs.map(\.session.sessionID) == ["working"])
        #expect(menu.blockers.map(\.session.sessionID) == ["blocked"])
        #expect(menu.finished.map(\.session.sessionID) == ["finished"])
        #expect(menu.pinned.map(\.session.sessionID) == ["pinned"])
        let all = menu.jobs + menu.blockers + menu.finished + menu.pinned
        #expect(all.allSatisfy { $0.workspaceKey == "local:a" })
        #expect(all.allSatisfy { $0.workspaceName == "Alpha" && $0.workspaceTint == .blue })
    }

    @Test
    func currentWorkspaceProjectionWithoutAWorkspaceRowStillListsItsRows() {
        // Before the workspace rows load (or for a scope the list does not
        // know yet) the section must not come out empty.
        let menu = GlobalActivityMenuSessions(
            currentWorkspace: localSlice(), key: "local:a", row: nil
        )

        #expect(menu.jobs.map(\.workspaceKey) == ["local:a"])
        #expect(menu.rowCount == 3)
        #expect(menu.pinned.count == 1)
    }

    @Test
    func localSliceCarriesTheSidebarProjectOfEachSession() {
        let slice = localSlice(projectIDs: ["working": "group", "pinned": "worktree"])

        #expect(slice.jobs.map(\.projectID) == ["group"])
        #expect(slice.pinned.map(\.projectID) == ["worktree"])
        // Unresolved sessions fall back to their own project.
        #expect(slice.blockers.map(\.projectID) == ["project"])
    }

    @Test
    func remoteSliceCarriesTheSummaryProject() {
        let slice = WorkspaceActivityMenuSlice(snapshot: RemoteBootstrapSnapshot(
            folders: [],
            projects: [RemoteProjectSummary(id: "p", name: "Project", path: "/project")],
            presets: [],
            sessions: [RemoteSessionSummary(
                id: "s", projectID: "p", title: "t", command: "codex",
                createdAtUnixMs: 1, status: .running, activity: .working
            )],
            capturedAtUnixMs: 1
        ))

        #expect(slice.jobs.map(\.projectID) == ["p"])
    }

    @Test
    func sessionProjectIDsFollowTheNodeTheSidebarRendersTheSessionUnder() {
        let moved = session("moved", status: .idle) // own project: "project"
        let nested = session("nested", status: .idle)
        let worktree = projectNode(id: "worktree", sessions: [nested])
        let group = projectNode(id: "group", sessions: [moved])
        let root = projectNode(id: "project", sessions: [], worktrees: [worktree, group])
        // A duplicate later in the walk never overrides the first row.
        let duplicate = projectNode(id: "other", sessions: [moved])

        let ids = WorkspaceActivityMenuSlice.sessionProjectIDs(in: [root, duplicate])

        #expect(ids == ["moved": "group", "nested": "worktree"])
    }

    @Test
    func aConfirmArmedFromAgentsShowsOnlyInTheAgentsRow() {
        let agents = SessionRowInlineMode.resolve(
            sessionID: "s", on: .agentsSection,
            editing: nil, confirmingStop: nil, confirmingRemove: "s",
            confirmSurface: .agentsSection
        )
        let sidebar = SessionRowInlineMode.resolve(
            sessionID: "s", on: .sidebar,
            editing: nil, confirmingStop: nil, confirmingRemove: "s",
            confirmSurface: .agentsSection
        )

        #expect(agents == .confirmingRemove)
        #expect(sidebar == SessionRowInlineMode.none)
    }

    @Test
    func aConfirmArmedFromTheSidebarStaysOutOfAgents() {
        let agents = SessionRowInlineMode.resolve(
            sessionID: "s", on: .agentsSection,
            editing: nil, confirmingStop: "s", confirmingRemove: nil,
            confirmSurface: .sidebar
        )
        let sidebar = SessionRowInlineMode.resolve(
            sessionID: "s", on: .sidebar,
            editing: nil, confirmingStop: "s", confirmingRemove: nil,
            confirmSurface: .sidebar
        )

        #expect(agents == SessionRowInlineMode.none)
        #expect(sidebar == .confirmingStop)
    }

    @Test(arguments: [
        (UnpeelStore.SessionTitleEditorSurface.sidebar, SessionRowInlineMode.none, SessionRowInlineMode.renaming),
        (.agentsSection, .renaming, .none),
        (.paneHeader, .none, .none),
    ])
    func renameMountsOnlyOnTheSurfaceThatStartedIt(
        editor: UnpeelStore.SessionTitleEditorSurface,
        agentsMode: SessionRowInlineMode,
        sidebarMode: SessionRowInlineMode
    ) {
        func mode(_ surface: SessionRowSurface) -> SessionRowInlineMode {
            SessionRowInlineMode.resolve(
                sessionID: "s", on: surface,
                editing: ("s", editor), confirmingStop: nil, confirmingRemove: nil,
                confirmSurface: .sidebar
            )
        }

        #expect(mode(.agentsSection) == agentsMode)
        #expect(mode(.sidebar) == sidebarMode)
    }

    @Test
    func confirmationsOutrankRenameAndOtherSessionsShowNothing() {
        let confirming = SessionRowInlineMode.resolve(
            sessionID: "s", on: .agentsSection,
            editing: ("s", .agentsSection), confirmingStop: "s", confirmingRemove: "s",
            confirmSurface: .agentsSection
        )
        let other = SessionRowInlineMode.resolve(
            sessionID: "other", on: .agentsSection,
            editing: ("s", .agentsSection), confirmingStop: "s", confirmingRemove: "s",
            confirmSurface: .agentsSection
        )

        #expect(confirming == .confirmingRemove)
        #expect(other == SessionRowInlineMode.none)
    }

    @Test
    func inlineStateOfARowThatLeftTheSectionEnds() {
        let cleanup = AgentsSectionInlineCleanup.resolve(
            visibleSessionIDs: ["kept"],
            editing: ("gone", .agentsSection),
            confirmingStop: "gone",
            confirmingRemove: "gone",
            confirmSurface: .agentsSection
        )

        #expect(cleanup == AgentsSectionInlineCleanup(
            endsEditing: true, endsStopConfirm: true, endsRemoveConfirm: true
        ))
    }

    @Test
    func inlineStateOfAVisibleRowOrAnotherSurfaceStays() {
        let visible = AgentsSectionInlineCleanup.resolve(
            visibleSessionIDs: ["s"],
            editing: ("s", .agentsSection),
            confirmingStop: nil,
            confirmingRemove: "s",
            confirmSurface: .agentsSection
        )
        // PROJECTS and the pane header own their own rows.
        let elsewhere = AgentsSectionInlineCleanup.resolve(
            visibleSessionIDs: [],
            editing: ("s", .sidebar),
            confirmingStop: "s",
            confirmingRemove: nil,
            confirmSurface: .sidebar
        )

        #expect(visible == .none)
        #expect(elsewhere == .none)
    }

    @Test
    func activityListKeepsOneIdentityPerRowAcrossGroups() {
        let item = { (id: String) in
            GlobalActivityMenuItem(
                workspaceKey: "local:a", workspaceName: "", workspaceTint: .none,
                session: WorkspaceActivityMenuSession(
                    sessionID: id, projectID: "p", title: id, command: "codex",
                    projectPath: "p", status: "Idle", alertBody: nil
                )
            )
        }
        let entries = ActivityMenuList.entries(
            blockers: [item("b")], jobs: [item("j")], finished: [item("f")],
            pinned: [item("p")]
        )

        #expect(entries.map(\.id) == [
            item("b").id, "divider:blockers", item("j").id, "divider:jobs",
            item("f").id, "divider:pinned", item("p").id,
        ])
        // A finished agent that starts working keeps its row's identity.
        let moved = ActivityMenuList.entries(
            blockers: [], jobs: [item("f")], finished: [], pinned: []
        )
        #expect(moved.map(\.id) == [item("f").id])
    }

    // MARK: - Fixtures

    private func localSlice(projectIDs: [String: String] = [:]) -> WorkspaceActivityMenuSlice {
        let working = session("working", status: .busy)
        let blocked = session("blocked", status: .attention)
        let finished = session("finished", status: .idle)
        let pinned = session("pinned", status: .idle)
        let activity = ActivityMenuSessions(
            nodes: [projectNode(sessions: [working, blocked, finished, pinned])],
            allSessions: [working, blocked, finished, pinned],
            jobs: [working],
            finished: [finished],
            pinned: [pinned]
        )
        return WorkspaceActivityMenuSlice(
            local: activity,
            projectName: { $0 },
            projectID: { projectIDs[$0.id] ?? $0.projectID },
            statusLabel: { _ in "Idle" },
            alertBody: { _ in nil }
        )
    }

    private func session(_ id: String, status: SessionStatus) -> SessionEntry {
        SessionEntry(
            id: id, projectID: "project", label: id, command: "codex",
            createdAt: 0, status: status, lifecycleAtMs: 0
        )
    }

    private func projectNode(
        id: String = "project",
        sessions: [SessionEntry],
        worktrees: [ProjectNode] = []
    ) -> ProjectNode {
        ProjectNode(
            project: Project(
                id: id, name: id, path: "/tmp/\(id)", parentProjectID: nil,
                sortOrder: 0, isFolder: nil, worktreeBranch: nil,
                workspacesEnabled: nil, mcpBlocked: nil
            ),
            sessions: sessions,
            worktrees: worktrees
        )
    }

    private func workspace(_ key: String, name: String, tint: AppTint) -> WorkspaceListRowModel {
        WorkspaceListRowModel(
            id: key, name: name, detail: "", icon: "", badge: nil,
            home: "/tmp/\(key)", tint: tint,
            kind: .local(record: nil, isDefault: true, isCurrentInstance: true, isRunning: true)
        )
    }
}
