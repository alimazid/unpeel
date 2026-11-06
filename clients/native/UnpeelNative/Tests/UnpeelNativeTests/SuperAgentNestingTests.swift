import Testing
import UnpeelShared
@testable import UnpeelNative

/// Fork-only: the Super Agent's running Workers listed indented under it in
/// AGENTS, wherever their Project is. Main actor: the list and the section
/// are views.
@MainActor
struct SuperAgentNestingTests {
    // MARK: - Nesting

    @Test
    func anIdleSuperAgentListsItsWorkingWorkerUnderIt() {
        let router = item("router", superAgent: true)
        let worker = item("worker", routerID: "router")

        let entries = ActivityMenuList.entries(
            blockers: [], jobs: [worker], finished: [], pinned: [router],
            nestsWorkers: true
        )

        // The Worker leaves the working group, so no divider is left over.
        #expect(rows(entries) == ["router:0", "worker:1"])
        #expect(entries.map(\.id) == [router.id, worker.id])
    }

    @Test
    func workersInEveryProjectAreListedUnderTheSuperAgentWithTheirOwnLook() {
        let router = item("router", project: "home", superAgent: true)
        let blocked = item("blocked", project: "api", routerID: "router")
        let working = item("working", project: "web", routerID: "router")
        let idle = item("idle", project: "docs", routerID: "router")
        let other = item("other", project: "web")

        let entries = ActivityMenuList.entries(
            blockers: [blocked], jobs: [router, working, other], finished: [], pinned: [],
            workers: [idle], nestsWorkers: true
        )

        #expect(rows(entries) == ["router:0", "blocked:1", "working:1", "idle:1", "other:0"])
        #expect(styles(entries)["blocked"] == ActivityMenuRowStyle.blocked.nested())
        #expect(styles(entries)["working"] == ActivityMenuRowStyle.working.nested())
        #expect(styles(entries)["idle"] == ActivityMenuRowStyle.idle.nested())
        #expect(styles(entries)["router"] == .working)
    }

    @Test
    func aStoppedWorkerIsNotNested() {
        let router = item("router", superAgent: true)
        let stopped = item("stopped", isLive: false, routerID: "router")

        let entries = ActivityMenuList.entries(
            blockers: [], jobs: [], finished: [stopped], pinned: [router],
            nestsWorkers: true
        )

        #expect(rows(entries) == ["stopped:0", "|pinned", "router:0"])
    }

    @Test
    func withoutTheSuperAgentWorkersStayWhereTheyAre() {
        let working = item("working", routerID: "router")
        let pinned = item("pinned", routerID: "router")
        let idle = item("idle", routerID: "router")

        let nested = ActivityMenuList.entries(
            blockers: [], jobs: [working], finished: [], pinned: [pinned],
            workers: [idle], nestsWorkers: true
        )
        let plain = ActivityMenuList.entries(
            blockers: [], jobs: [working], finished: [], pinned: [pinned]
        )

        // Idle Workers are listed under their Super Agent only.
        #expect(rows(nested) == ["working:0", "|pinned", "pinned:0"])
        #expect(rows(nested) == rows(plain))
    }

    @Test
    func aWorkerNestsOnlyUnderTheSuperAgentOfItsOwnWorkspace() {
        let router = item("router", workspace: "local:a", superAgent: true)
        let elsewhere = item("worker", workspace: "local:b", routerID: "router")

        let entries = ActivityMenuList.entries(
            blockers: [], jobs: [elsewhere], finished: [], pinned: [router],
            nestsWorkers: true
        )

        #expect(rows(entries) == ["worker:0", "|pinned", "router:0"])
    }

    @Test
    func theDropdownsNeverNest() {
        let router = item("router", superAgent: true)
        let worker = item("worker", routerID: "router")

        let entries = ActivityMenuList.entries(
            blockers: [], jobs: [router, worker], finished: [], pinned: [],
            workers: [item("idle", routerID: "router")]
        )

        #expect(rows(entries) == ["router:0", "worker:0"])
    }

    // MARK: - Membership

    @Test
    func theLocalSliceListsIdleRunningWorkersApart() {
        let router = entry("router", superAgent: true)
        let working = entry("working", status: .busy, routerID: "router")
        let idle = entry("idle", routerID: "router")
        let stopped = entry("stopped", status: .exited, routerID: "router")
        let plain = entry("plain")
        let nodes = [
            projectNode(id: "home", sessions: [router, plain]),
            projectNode(id: "web", sessions: [working, stopped], worktrees: [
                projectNode(id: "web-wt", sessions: [idle]),
            ]),
        ]

        let candidates = WorkspaceActivityMenuSlice.runningWorkers(in: nodes)
        let slice = localSlice(nodes: nodes, jobs: [working], workers: candidates)

        #expect(candidates.map(\.id) == ["working", "idle"])
        #expect(slice.jobs.map(\.sessionID) == ["working"])
        #expect(slice.workers.map(\.sessionID) == ["idle"])
        #expect(slice.pinned.map(\.sessionID) == ["router"])
    }

    @Test
    func theRemoteSliceListsIdleRunningWorkersApart() {
        let slice = WorkspaceActivityMenuSlice(snapshot: snapshot([
            summary("router", superAgent: true),
            summary("working", activity: .working, routerID: "router"),
            summary("idle", routerID: "router"),
            summary("stopped", status: .exited, routerID: "router"),
            summary("pinnedStopped", status: .exited, pinned: true, routerID: "router"),
            summary("plain"),
        ]))

        #expect(slice.jobs.map(\.sessionID) == ["working"])
        #expect(slice.workers.map(\.sessionID) == ["idle"])
        #expect(slice.pinned.map(\.sessionID) == ["router", "pinnedStopped"])
        #expect(slice.pinned.map(\.isLive) == [true, false])
    }

    @Test
    func idleWorkersDoNotChangeTheBellCounts() {
        let working = entry("working", status: .busy)
        let router = entry("router", superAgent: true)
        let idle = entry("idle", routerID: "router")
        let nodes = [projectNode(id: "home", sessions: [working, router, idle])]
        let slice = localSlice(
            nodes: nodes, jobs: [working],
            workers: WorkspaceActivityMenuSlice.runningWorkers(in: nodes)
        )

        let agents = GlobalActivityMenuSessions(currentWorkspace: slice, key: "local:a", row: nil)
        let bell = GlobalActivityMenuSessions(
            workspaces: [workspace("local:a")], foregroundKey: "local:a",
            foreground: slice, cachedSlice: { _ in nil }
        )

        #expect(agents.workers.map(\.session.sessionID) == ["idle"])
        for menu in [agents, bell] {
            #expect(menu.sectionCount == 1)
            #expect(menu.rowCount == 1)
        }
        // The AGENTS section ends inline state only for rows it dropped.
        #expect(AgentsSectionPanel.sessionIDs(agents) == ["working", "router", "idle"])
    }

    @Test
    func anIdleWorkerWithoutItsSuperAgentIsNotARowOfTheSection() {
        let idle = entry("idle", routerID: "gone")
        let nodes = [projectNode(id: "home", sessions: [idle])]
        let slice = localSlice(
            nodes: nodes, jobs: [],
            workers: WorkspaceActivityMenuSlice.runningWorkers(in: nodes)
        )

        let agents = GlobalActivityMenuSessions(currentWorkspace: slice, key: "local:a", row: nil)

        #expect(agents.workers.map(\.session.sessionID) == ["idle"])
        #expect(AgentsSectionPanel.sessionIDs(agents).isEmpty)
    }

    // MARK: - Fixtures

    /// Each row as `<session id>:<depth>`; dividers as `|<name>`.
    private func rows(_ entries: [ActivityMenuList.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case let .row(item, style): return "\(item.session.sessionID):\(style.depth)"
            case let .divider(name): return "|" + name
            }
        }
    }

    private func styles(_ entries: [ActivityMenuList.Entry]) -> [String: ActivityMenuRowStyle] {
        entries.reduce(into: [:]) { result, entry in
            if case let .row(item, style) = entry { result[item.session.sessionID] = style }
        }
    }

    private func localSlice(
        nodes: [ProjectNode], jobs: [SessionEntry], workers: [SessionEntry]
    ) -> WorkspaceActivityMenuSlice {
        let activity = ActivityMenuSessions(
            nodes: nodes,
            allSessions: nodes.flatMap(\.sessions),
            jobs: jobs,
            finished: [],
            pinned: WorkspaceActivityMenuSlice.alwaysListedSessions(in: nodes) { _, _ in false },
            workers: workers
        )
        return WorkspaceActivityMenuSlice(
            local: activity,
            projectName: { $0 },
            projectID: { $0.projectID },
            statusLabel: { _ in "Idle" },
            alertBody: { _ in nil }
        )
    }

    private func projectNode(
        id: String,
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

    private func workspace(_ key: String) -> WorkspaceListRowModel {
        WorkspaceListRowModel(
            id: key, name: key, detail: "", icon: "", badge: nil,
            home: "/tmp/\(key)", tint: .blue,
            kind: .local(record: nil, isDefault: true, isCurrentInstance: true, isRunning: true)
        )
    }

    private func entry(
        _ id: String,
        status: SessionStatus = .idle,
        superAgent: Bool = false,
        routerID: String? = nil
    ) -> SessionEntry {
        var entry = SessionEntry(
            id: id, projectID: "project", label: id, command: "claude",
            createdAt: 0, status: status, lifecycleAtMs: 0
        )
        entry.superAgent = superAgent
        entry.superAgentRouterID = routerID
        return entry
    }

    private func summary(
        _ id: String,
        status: RemoteSessionStatus = .running,
        activity: RemoteActivityState = .idle,
        pinned: Bool = false,
        superAgent: Bool = false,
        routerID: String? = nil
    ) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: id, projectID: "project", title: id, command: "claude",
            createdAtUnixMs: 1, status: status, activity: activity,
            unread: false, pinned: pinned,
            superAgent: superAgent, superAgentRouterID: routerID
        )
    }

    private func snapshot(_ sessions: [RemoteSessionSummary]) -> RemoteBootstrapSnapshot {
        RemoteBootstrapSnapshot(
            folders: [],
            projects: [RemoteProjectSummary(id: "project", name: "Project", path: "/project")],
            presets: [],
            sessions: sessions,
            capturedAtUnixMs: 1
        )
    }

    private func item(
        _ id: String,
        workspace: String = "local:a",
        project: String = "project",
        isLive: Bool = true,
        superAgent: Bool = false,
        routerID: String? = nil
    ) -> GlobalActivityMenuItem {
        GlobalActivityMenuItem(
            workspaceKey: workspace, workspaceName: "", workspaceTint: .none,
            session: WorkspaceActivityMenuSession(
                sessionID: id, projectID: project, title: id, command: "claude",
                projectPath: project, status: isLive ? "Idle" : "Exited", alertBody: nil,
                isLive: isLive, superAgent: superAgent, superAgentRouterID: routerID
            )
        )
    }
}
