//
//  GlobalActivityMenu.swift
//  UnpeelNative
//
//  A compact, cached projection for the activity dropdown. Remote workspace
//  project trees are indexed once when their bootstrap changes; ordinary
//  SwiftUI redraws merge only the already-small active/blocked/unread rows.
//

import Combine
import Foundation
import UnpeelShared

struct WorkspaceActivityMenuSession: Equatable {
    let sessionID: String
    /// Fork-only: the project the sidebar lists the Session under (a moved
    /// Session's group, not its own project), for the AGENTS row's
    /// Pin/Unpin.
    let projectID: String
    let title: String
    let command: String
    let projectPath: String
    let status: String
    /// Latest App alert when it is this Session's newest activity.
    let alertBody: String?
    /// Fork-only: not stopped. Only a running Worker is nested under the
    /// Super Agent in AGENTS.
    var isLive: Bool = true
    /// Fork-only: the Session is the workspace's Super Agent (the Router).
    var superAgent: Bool = false
    /// Fork-only: the Super Agent this Session works for (a Worker).
    var superAgentRouterID: String? = nil
}

struct WorkspaceActivityMenuSlice: Equatable {
    var jobs: [WorkspaceActivityMenuSession] = []
    var blockers: [WorkspaceActivityMenuSession] = []
    var finished: [WorkspaceActivityMenuSession] = []
    /// Fork-only: pinned sessions and the Super Agent in none of the groups
    /// above, so the AGENTS section always shows them.
    var pinned: [WorkspaceActivityMenuSession] = []
    /// Fork-only: running Workers in none of the groups above. AGENTS lists
    /// them under the Super Agent, and nowhere else.
    var workers: [WorkspaceActivityMenuSession] = []

    init() {}

    /// Build once per accepted bootstrap. Project lookup/path construction is
    /// O(projects), session classification is O(sessions), and neither work is
    /// repeated by menu rendering or the spinner timer.
    init(snapshot: RemoteBootstrapSnapshot) {
        let projects = snapshot.projects.reduce(into: [String: RemoteProjectSummary]()) {
            $0[$1.id] = $1
        }
        var projectPaths: [String: String] = [:]

        func projectPath(_ projectID: String) -> String {
            if let cached = projectPaths[projectID] { return cached }
            guard projects[projectID] != nil else { return "Unknown project" }

            var names: [String] = []
            var seen = Set<String>()
            var cursor: String? = projectID
            // Malformed remote ancestry must never loop the Controller.
            while let id = cursor, let project = projects[id], seen.insert(id).inserted,
                  names.count < 32 {
                names.append(project.name)
                cursor = project.parentProjectID
            }
            let path = names.reversed().joined(separator: " › ")
            projectPaths[projectID] = path
            return path
        }

        var seen = Set<String>()
        // Fork-only: a superseded Run is in none of a Project's listings.
        for summary in snapshot.sessions where ScheduledRunListing.isListed(summary) {
            guard seen.insert(summary.id).inserted else { continue }
            let item = WorkspaceActivityMenuSession(
                sessionID: summary.id,
                projectID: summary.projectID,
                title: Self.title(summary.title, fallback: summary.command),
                command: summary.command,
                projectPath: projectPath(summary.projectID),
                status: Self.statusLabel(summary),
                alertBody: summary.latestAlertBody,
                isLive: summary.status == .running,
                superAgent: summary.superAgent,
                superAgentRouterID: summary.superAgentRouterID
            )
            if summary.status == .running, summary.activity == .blocked {
                blockers.append(item)
            } else if summary.status == .running,
                      summary.activity == .starting || summary.activity == .working {
                jobs.append(item)
            } else if summary.unread {
                finished.append(item)
            } else if summary.pinned || summary.superAgent {
                pinned.append(item)
            } else if summary.status == .running, summary.superAgentRouterID != nil {
                workers.append(item)
            }
        }
    }

    init(
        local activity: ActivityMenuSessions,
        projectName: (String) -> String,
        projectID: (SessionEntry) -> String,
        statusLabel: (SessionEntry) -> String,
        alertBody: (SessionEntry) -> String?
    ) {
        func item(_ session: SessionEntry) -> WorkspaceActivityMenuSession {
            WorkspaceActivityMenuSession(
                sessionID: session.id,
                projectID: projectID(session),
                title: Self.title(session.label, fallback: session.presentationCommand),
                command: session.presentationCommand,
                projectPath: projectName(session.projectID),
                status: statusLabel(session),
                alertBody: alertBody(session),
                isLive: session.isLive,
                superAgent: session.superAgent,
                superAgentRouterID: session.superAgentRouterID
            )
        }
        jobs = activity.jobs.map(item)
        blockers = activity.blockers.map(item)
        finished = activity.finished.map(item)
        pinned = activity.pinned.map(item)
        workers = activity.workers.map(item)
    }

    /// Fork-only: Session id → the id of the first node that lists it,
    /// walking the sidebar tree in render order (worktrees and groups
    /// included).
    static func sessionProjectIDs(in nodes: [ProjectNode]) -> [String: String] {
        var result: [String: String] = [:]
        func collect(_ nodes: [ProjectNode]) {
            for node in nodes {
                for session in node.sessions where result[session.id] == nil {
                    result[session.id] = node.id
                }
                collect(node.worktrees)
            }
        }
        collect(nodes)
        return result
    }

    /// Fork-only: the sessions the AGENTS section lists whatever their
    /// activity — pinned ones and the Super Agent — in sidebar order.
    static func alwaysListedSessions(
        in nodes: [ProjectNode],
        isPinned: (_ sessionID: String, _ projectID: String) -> Bool
    ) -> [SessionEntry] {
        sessions(in: nodes) { session, projectID in
            session.superAgent || isPinned(session.id, projectID)
        }
    }

    /// Fork-only: the running Workers, in sidebar order — candidates for
    /// `workers`.
    static func runningWorkers(in nodes: [ProjectNode]) -> [SessionEntry] {
        sessions(in: nodes) { session, _ in
            session.isLive && !session.superAgent && session.superAgentRouterID != nil
        }
    }

    /// Fork-only: every session `included` accepts (with the id of the node
    /// listing it), walking the sidebar tree in render order.
    private static func sessions(
        in nodes: [ProjectNode],
        where included: (_ session: SessionEntry, _ projectID: String) -> Bool
    ) -> [SessionEntry] {
        nodes.flatMap { node in
            node.sessions.filter { included($0, node.id) }
                + sessions(in: node.worktrees, where: included)
        }
    }

    private static func title(_ raw: String, fallback: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Untitled session" : fallback
    }

    private static func statusLabel(_ session: RemoteSessionSummary) -> String {
        guard session.status == .running else { return "Exited" }
        switch session.activity {
        case .starting: return "Starting"
        case .working: return "Working"
        case .blocked: return "Blocked"
        case .done: return "Done"
        case .idle, .unknown: return "Idle"
        }
    }
}

struct GlobalActivityMenuItem: Identifiable, Equatable {
    let workspaceKey: String
    let workspaceName: String
    let workspaceTint: AppTint
    let session: WorkspaceActivityMenuSession

    var id: String { workspaceKey + "\u{1f}" + session.sessionID }
}

struct GlobalActivityMenuSessions: Equatable {
    var jobs: [GlobalActivityMenuItem] = []
    var blockers: [GlobalActivityMenuItem] = []
    var finished: [GlobalActivityMenuItem] = []
    /// Fork-only: shown by the AGENTS section only, so the counts below —
    /// which size the dropdowns — leave it out.
    var pinned: [GlobalActivityMenuItem] = []
    /// Fork-only: idle Workers, listed under the Super Agent in AGENTS only;
    /// left out of the counts too.
    var workers: [GlobalActivityMenuItem] = []

    static let empty = GlobalActivityMenuSessions()

    init() {}

    /// The selected workspace uses the sidebar's current projection, including
    /// restart and attention overlays. Other workspaces use their Host cache.
    /// Even an empty foreground slice overrides an older cached Busy row.
    init(
        workspaces: [WorkspaceListRowModel],
        foregroundKey: String?,
        foreground: WorkspaceActivityMenuSlice,
        cachedSlice: (String) -> WorkspaceActivityMenuSlice?
    ) {
        for workspace in workspaces {
            let slice = workspace.id == foregroundKey ? foreground : cachedSlice(workspace.id)
            guard let slice else { continue }
            func wrap(_ sessions: [WorkspaceActivityMenuSession]) -> [GlobalActivityMenuItem] {
                sessions.map {
                    GlobalActivityMenuItem(
                        workspaceKey: workspace.id,
                        workspaceName: workspace.name,
                        workspaceTint: workspace.tint,
                        session: $0
                    )
                }
            }
            blockers.append(contentsOf: wrap(slice.blockers))
            jobs.append(contentsOf: wrap(slice.jobs))
            finished.append(contentsOf: wrap(slice.finished))
            pinned.append(contentsOf: wrap(slice.pinned))
            workers.append(contentsOf: wrap(slice.workers))
        }
    }

    /// Fork-only: the AGENTS section's projection — the foreground slice
    /// alone, so every row is in the scope the store's session verbs act
    /// on. It never depends on the workspace list: a scope missing from it
    /// still lists its rows.
    init(
        currentWorkspace slice: WorkspaceActivityMenuSlice,
        key: String,
        row: WorkspaceListRowModel?
    ) {
        func wrap(_ sessions: [WorkspaceActivityMenuSession]) -> [GlobalActivityMenuItem] {
            sessions.map {
                GlobalActivityMenuItem(
                    workspaceKey: key,
                    workspaceName: row?.name ?? "",
                    workspaceTint: row?.tint ?? AppTint.none,
                    session: $0
                )
            }
        }
        blockers = wrap(slice.blockers)
        jobs = wrap(slice.jobs)
        finished = wrap(slice.finished)
        pinned = wrap(slice.pinned)
        workers = wrap(slice.workers)
    }

    var sectionCount: Int {
        [blockers, jobs, finished].reduce(into: 0) { count, sessions in
            if !sessions.isEmpty { count += 1 }
        }
    }

    var rowCount: Int { jobs.count + blockers.count + finished.count }
}

/// One shared cache feeds both the titlebar and macOS menu-bar surfaces.
/// Rebuilds are coalesced to one per main-runloop turn, so a scope transition
/// that publishes several related properties still performs one merge.
@MainActor
final class GlobalActivityMenuModel: ObservableObject {
    @Published private(set) var activity = GlobalActivityMenuSessions.empty
    /// Fork-only: the AGENTS section lists the current workspace only; the
    /// bell and the menu bar keep `activity`, across every workspace.
    @Published private(set) var currentWorkspaceActivity = GlobalActivityMenuSessions.empty

    private weak var store: UnpeelStore?
    private let pool: WorkspacePool
    private var rows: [WorkspaceListRowModel]
    private var cancellables = Set<AnyCancellable>()
    private var rebuildScheduled = false
    private var rowsNeedRefresh = false

    init(store: UnpeelStore, pool: WorkspacePool) {
        self.store = store
        self.pool = pool
        rows = WorkspaceSwitching.orderedRows(store: store)

        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)
        pool.$snapshots
            .dropFirst()
            .sink { [weak self] snapshots in
                guard let self else { return }
                let known = Set(self.rows.map(\.id))
                if !Set(snapshots.keys).isSubset(of: known) {
                    self.rowsNeedRefresh = true
                }
                self.scheduleRebuild()
            }
            .store(in: &cancellables)
        store.remoteHostStore.objectWillChange
            .sink { [weak self] _ in
                self?.rowsNeedRefresh = true
                self?.scheduleRebuild()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .unpeelWorkspaceTintChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rowsNeedRefresh = true
                self?.scheduleRebuild()
            }
            .store(in: &cancellables)

        rebuild()
    }

    func refreshWorkspaceMetadata() {
        guard let store else { return }
        rows = WorkspaceSwitching.orderedRows(store: store)
        rowsNeedRefresh = false
        rebuild()
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    private func rebuild() {
        guard let store else { return }
        if rowsNeedRefresh {
            rows = WorkspaceSwitching.orderedRows(store: store)
            rowsNeedRefresh = false
        }

        let currentLocalRow = rows.first { row in
            if case let .local(_, _, isCurrentInstance, _) = row.kind {
                return isCurrentInstance
            }
            return false
        }
        let displayNodes = store.displayNodes
        let foregroundActivity = ActivityMenuSessions(
            nodes: displayNodes,
            allSessions: Array(store.displaySessionsByID.values),
            jobs: store.activeJobSessions,
            finished: store.unreadJobSessions,
            pinned: store.pinnedActivitySessions,
            workers: WorkspaceActivityMenuSlice.runningWorkers(in: displayNodes)
        )
        let sidebarProjectIDs = WorkspaceActivityMenuSlice.sessionProjectIDs(
            in: displayNodes
        )
        let foregroundSlice = WorkspaceActivityMenuSlice(
            local: foregroundActivity,
            projectName: { store.activityProjectName($0) },
            projectID: { sidebarProjectIDs[$0.id] ?? $0.projectID },
            statusLabel: { store.activityStatusLabel(for: $0) },
            alertBody: { store.activityAlertBody(for: $0) }
        )
        // Before the first Local Host snapshot the sidebar uses its disk
        // seed. Once connected, its display projection is Host-owned. Neither
        // may be assigned to another workspace after a scope switch.
        let foregroundKey = store.workspacePoolForegroundKey()
            ?? (store.selectedHostScope == .local ? currentLocalRow?.id : nil)
        let result = GlobalActivityMenuSessions(
            workspaces: rows,
            foregroundKey: foregroundKey,
            foreground: foregroundSlice,
            cachedSlice: { pool.activitySlice(forKey: $0) }
        )

        if result != activity { activity = result }

        // Same key `revealGlobalActivitySession` treats as this window's
        // scope, so a row click selects instead of rescoping.
        let currentKey = store.currentScopeWorkspaceKey
        let current = GlobalActivityMenuSessions(
            currentWorkspace: foregroundSlice,
            key: currentKey,
            row: rows.first { $0.id == currentKey }
        )
        if current != currentWorkspaceActivity { currentWorkspaceActivity = current }
    }
}
