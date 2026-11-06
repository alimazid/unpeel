import Testing
import UnpeelShared
@testable import UnpeelNative

/// Fork-only: the Super Agent in the Mac app — the Host's bootstrap fields,
/// the three menu items, and the Router's place in AGENTS.
struct SuperAgentTests {
    // MARK: - Bootstrap fields

    @Test @MainActor
    func remoteEntriesCarryTheRouterMarkAndTheWorkerMarker() {
        let router = UnpeelStore.sessionEntry(fromRemote: summary("router", superAgent: true))
        let worker = UnpeelStore.sessionEntry(fromRemote: summary("worker", routerID: "router"))
        let plain = UnpeelStore.sessionEntry(fromRemote: summary("plain"))

        #expect(router.superAgent)
        #expect(router.superAgentRouterID == nil)
        #expect(!worker.superAgent)
        #expect(worker.superAgentRouterID == "router")
        #expect(!plain.superAgent)
        #expect(plain.superAgentRouterID == nil)
    }

    @Test
    func remoteActivityRowsCarryTheRouterMarkAndTheWorkerMarker() {
        let slice = WorkspaceActivityMenuSlice(snapshot: snapshot([
            summary("router", activity: .working, superAgent: true),
            summary("worker", activity: .working, routerID: "router"),
        ]))

        #expect(slice.jobs.map(\.superAgent) == [true, false])
        #expect(slice.jobs.map(\.superAgentRouterID) == [nil, "router"])
    }

    // MARK: - Menu gating

    @Test
    func aClaudeCodeAgentCanBecomeTheSuperAgent() {
        #expect(menu(entry("claude"), routerID: nil) == offers(make: true))
        // Making another Session the Super Agent moves the Workers to it.
        #expect(menu(entry("claude"), routerID: "router") == offers(make: true, handOver: true))
    }

    @Test
    func otherAgentsCanOnlyBeHandedToTheSuperAgent() {
        #expect(menu(entry("codex", command: "codex"), routerID: nil) == offers())
        #expect(menu(entry("codex", command: "codex"), routerID: "router")
            == offers(handOver: true))
    }

    @Test
    func aShellIsOfferedNothing() {
        #expect(menu(entry("shell", command: "zsh"), routerID: "router") == offers())
    }

    @Test
    func theSuperAgentCanOnlyStopBeingOne() {
        let router = entry("router", superAgent: true)
        #expect(menu(router, routerID: "router") == offers(stopBeing: true))
        // A stopped Super Agent still holds the mark until it is cleared.
        let stopped = entry("router", status: .exited, superAgent: true)
        #expect(menu(stopped, routerID: "router") == offers(stopBeing: true))
    }

    @Test
    func aWorkerIsNotHandedOverAgain() {
        let worker = entry("worker", command: "codex", routerID: "router")
        #expect(menu(worker, routerID: "router") == offers())
        // A Claude Code Worker may still become the Super Agent itself.
        let claudeWorker = entry("worker", routerID: "router")
        #expect(menu(claudeWorker, routerID: "router") == offers(make: true))
        // A marker naming a Session that is no longer the Super Agent.
        let stale = entry("worker", command: "codex", routerID: "gone")
        #expect(menu(stale, routerID: "router") == offers(handOver: true))
    }

    @Test
    func theObservedRuntimeWinsOverTheLaunchCommand() {
        let claudeInShell = entry("a", command: "zsh", observed: "claude")
        #expect(menu(claudeInShell, routerID: nil) == offers(make: true))
        let codexFromClaude = entry("b", command: "claude", observed: "codex")
        #expect(menu(codexFromClaude, routerID: "router") == offers(handOver: true))
        // An observed program the catalog does not know is not an agent.
        let unknown = entry("c", command: "claude", observed: "vim")
        #expect(menu(unknown, routerID: "router") == offers())
    }

    @Test
    func aStoppedAgentIsOfferedNothing() {
        let stopped = entry("claude", status: .exited)
        #expect(menu(stopped, routerID: "router") == offers())
    }

    @Test
    func eachItemNeedsItsOwnHostOperation() {
        let claude = entry("claude")
        let router = entry("router", superAgent: true)
        let only: (String) -> (String) -> Bool = { id in { $0 == id } }
        let set = RemoteHostRuntime.HostOperation.superAgentSet
        let clear = RemoteHostRuntime.HostOperation.superAgentClear
        let handOver = RemoteHostRuntime.HostOperation.superAgentHandOver

        #expect(set == "session.super_agent.set")
        #expect(clear == "session.super_agent.clear")
        #expect(handOver == "session.super_agent.hand_over")
        #expect(SuperAgentMenu(session: claude, routerID: "router", supports: only(set))
            == offers(make: true))
        #expect(SuperAgentMenu(session: claude, routerID: "router", supports: only(handOver))
            == offers(handOver: true))
        #expect(SuperAgentMenu(session: router, routerID: "router", supports: only(set))
            == offers())
        #expect(SuperAgentMenu(session: router, routerID: "router", supports: only(clear))
            == offers(stopBeing: true))
    }

    @Test
    func theRouterIsTheSessionTheHostMarked() {
        let sessions = [summary("a"), summary("router", superAgent: true), summary("b")]
        #expect(SuperAgentMenu.routerID(in: sessions) == "router")
        #expect(SuperAgentMenu.routerID(in: [summary("a")]) == nil)
    }

    // MARK: - AGENTS

    @Test
    func theSuperAgentIsAlwaysListedLikeAPinnedSession() {
        let plain = entry("plain")
        let router = entry("router", superAgent: true)
        let pinned = entry("pinned")
        let nested = projectNode(id: "group", sessions: [pinned])
        let root = projectNode(sessions: [plain, router], worktrees: [nested])

        let listed = WorkspaceActivityMenuSlice.alwaysListedSessions(in: [root]) { id, project in
            id == "pinned" && project == "group"
        }

        // Sidebar order: the Router's project, then the group under it.
        #expect(listed.map(\.id) == ["router", "pinned"])
    }

    @Test
    func anIdleSuperAgentDoesNotChangeTheBellCounts() {
        let working = entry("working", status: .busy)
        let router = entry("router", superAgent: true)
        let slice = localSlice(sessions: [working, router], jobs: [working])

        let agents = GlobalActivityMenuSessions(currentWorkspace: slice, key: "local:a", row: nil)
        let bell = GlobalActivityMenuSessions(
            workspaces: [workspace("local:a")], foregroundKey: "local:a",
            foreground: slice, cachedSlice: { _ in nil }
        )

        #expect(agents.pinned.map(\.session.sessionID) == ["router"])
        #expect(agents.pinned.map(\.session.superAgent) == [true])
        for menu in [agents, bell] {
            #expect(menu.sectionCount == 1)
            #expect(menu.rowCount == 1)
        }
    }

    @Test
    func aWorkingSuperAgentIsListedOnceWithTheWork() {
        let router = entry("router", status: .busy, superAgent: true)
        let slice = localSlice(sessions: [router], jobs: [router])

        #expect(slice.jobs.map(\.sessionID) == ["router"])
        #expect(slice.jobs.map(\.superAgent) == [true])
        #expect(slice.pinned.isEmpty)
    }

    @Test
    func remoteSliceAlwaysListsAnIdleSuperAgent() {
        let slice = WorkspaceActivityMenuSlice(snapshot: snapshot([
            summary("plain"),
            summary("router", superAgent: true),
            summary("worker", routerID: "router"),
        ]))

        #expect(slice.pinned.map(\.sessionID) == ["router"])
        #expect(slice.jobs.isEmpty && slice.blockers.isEmpty && slice.finished.isEmpty)
    }

    // MARK: - Fixtures

    private func localSlice(
        sessions: [SessionEntry], jobs: [SessionEntry]
    ) -> WorkspaceActivityMenuSlice {
        let nodes = [projectNode(sessions: sessions)]
        let activity = ActivityMenuSessions(
            nodes: nodes,
            allSessions: sessions,
            jobs: jobs,
            finished: [],
            pinned: WorkspaceActivityMenuSlice.alwaysListedSessions(in: nodes) { _, _ in false }
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

    private func workspace(_ key: String) -> WorkspaceListRowModel {
        WorkspaceListRowModel(
            id: key, name: key, detail: "", icon: "", badge: nil,
            home: "/tmp/\(key)", tint: .blue,
            kind: .local(record: nil, isDefault: true, isCurrentInstance: true, isRunning: true)
        )
    }

    private func menu(_ session: SessionEntry, routerID: String?) -> SuperAgentMenu {
        SuperAgentMenu(session: session, routerID: routerID, supports: { _ in true })
    }

    private func offers(
        make: Bool = false, stopBeing: Bool = false, handOver: Bool = false
    ) -> SuperAgentMenu {
        SuperAgentMenu(canMake: make, canStopBeing: stopBeing, canHandOver: handOver)
    }

    private func entry(
        _ id: String,
        command: String = "claude",
        observed: String? = nil,
        status: SessionStatus = .idle,
        superAgent: Bool = false,
        routerID: String? = nil
    ) -> SessionEntry {
        var entry = SessionEntry(
            id: id, projectID: "project", label: id, command: command,
            createdAt: 0, status: status, activeRuntimeID: observed, lifecycleAtMs: 0
        )
        entry.superAgent = superAgent
        entry.superAgentRouterID = routerID
        return entry
    }

    private func summary(
        _ id: String,
        command: String = "claude",
        status: RemoteSessionStatus = .running,
        activity: RemoteActivityState = .idle,
        unread: Bool = false,
        pinned: Bool = false,
        superAgent: Bool = false,
        routerID: String? = nil
    ) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: id, projectID: "project", title: id, command: command,
            createdAtUnixMs: 1, status: status, activity: activity,
            unread: unread, pinned: pinned,
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
}
