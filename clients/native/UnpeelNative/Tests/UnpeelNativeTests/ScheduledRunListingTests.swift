import Foundation
import Testing
import UnpeelShared
@testable import UnpeelNative

/// Fork-only: Scheduled Tasks (Q32). Every listing of a Project's Sessions
/// hides a superseded Run from the Host's one field, `superseded`, while the
/// row stays openable by id; the latest Run keeps its clock badge mark.
@MainActor
struct ScheduledRunListingTests {
    /// Three Runs of one task (the latest live, an older one stopped and
    /// unread, an older one still live and blocked on the user) beside the
    /// user's own Session.
    private let snapshot = RemoteBootstrapSnapshot(
        folders: [],
        projects: [RemoteProjectSummary(id: "p", name: "Project", path: "/project")],
        presets: [],
        sessions: [
            row("run-3", status: .running, activity: .working, scheduleID: "sch_a"),
            row("run-2", status: .exited, activity: .done, unread: true,
                scheduleID: "sch_a", superseded: true),
            row("run-1", status: .running, activity: .blocked,
                scheduleID: "sch_a", superseded: true),
            row("user", status: .exited, activity: .idle),
        ],
        capturedAtUnixMs: 1
    )

    @Test func projectsListOnlyTheLatestRunAndKeepTheOthersOpenable() {
        let entries = snapshot.sessions.map(UnpeelStore.sessionEntry(fromRemote:))
        let byProject = ScheduledRunListing.sessionsByProject(entries, knownProjectIDs: ["p"])

        #expect(byProject["p"]?.map(\.id) == ["run-3", "user"])
        // Every row stays projected by id, which is how SCHEDULED opens one.
        #expect(Set(entries.map(\.id)) == ["run-3", "run-2", "run-1", "user"])
        #expect(snapshot.sessions.filter(ScheduledRunListing.isListed).map(\.id) == ["run-3", "user"])
    }

    @Test func aRunSessionCarriesItsMarkForTheClockBadge() {
        let entries = Dictionary(uniqueKeysWithValues: snapshot.sessions.map {
            ($0.id, UnpeelStore.sessionEntry(fromRemote: $0))
        })

        #expect(entries["run-3"]?.scheduledRun == ScheduledRunMark(scheduleID: "sch_a", superseded: false))
        #expect(entries["run-2"]?.scheduledRun == ScheduledRunMark(scheduleID: "sch_a", superseded: true))
        #expect(entries["user"]?.scheduledRun == nil)
    }

    /// AGENTS for another workspace, the titlebar bell and the menu bar.
    @Test func theActivityMenusHideSupersededRuns() {
        let slice = WorkspaceActivityMenuSlice(snapshot: snapshot)

        #expect(slice.jobs.map(\.sessionID) == ["run-3"], "a running Run is an agent like any other")
        #expect(slice.blockers.isEmpty)
        #expect(slice.finished.isEmpty)
    }

    /// The foreground workspace's AGENTS rows come from the listed tree, plus
    /// "orphan" blockers scanned from every projected Session.
    @Test func aSupersededRunIsNoOrphanBlocker() {
        let entries = snapshot.sessions.map(UnpeelStore.sessionEntry(fromRemote:))
        let listed = ScheduledRunListing.sessionsByProject(entries, knownProjectIDs: ["p"])
        let node = ProjectNode(
            project: project,
            sessions: listed["p"] ?? [],
            worktrees: []
        )

        let activity = ActivityMenuSessions(
            nodes: [node], allSessions: entries, jobs: [], finished: []
        )

        #expect(activity.blockers.isEmpty)
    }

    /// Run Sessions take no slot in a Project's stopped window, as on the
    /// Host: their keep limit is per task.
    @Test func aRunSessionTakesNoStoppedSlot() {
        let entries = Dictionary(uniqueKeysWithValues: snapshot.sessions.map {
            ($0.id, UnpeelStore.sessionEntry(fromRemote: $0))
        })

        #expect(entries["run-2"].map(ScheduledRunListing.takesStoppedSlot) == false)
        #expect(entries["user"].map(ScheduledRunListing.takesStoppedSlot) == true)
    }

    /// Before the Host's first bootstrap the sidebar shows a disk scan, which
    /// knows a Run only by `spawned_by`. It hides exactly the Runs the Host
    /// last called superseded (the startup cache), with no rule of its own: a
    /// Run the Host has not answered for yet stays listed.
    @Test func theDiskSeedHidesWhatTheHostLastSuperseded() {
        let scanned = [
            local("run-4", spawnedBy: "schedule:sch_a"),
            local("run-3", spawnedBy: "schedule:sch_a"),
            local("run-2", spawnedBy: "schedule:sch_a"),
            local("b-1", spawnedBy: "schedule:sch_b"),
            local("child", spawnedBy: "4f1c-agent-session"),
            local("user", spawnedBy: nil),
        ]

        let seeded = ScheduledRunListing.seeding(scanned, supersededRunIDs: ["run-2", "user"])

        #expect(seeded.filter(ScheduledRunListing.isListed).map(\.id)
            == ["run-4", "run-3", "b-1", "child", "user"])
        #expect(seeded.map { $0.scheduledRun?.scheduleID } == ["sch_a", "sch_a", "sch_a", "sch_b", nil, nil])
    }

    /// The startup cache remembers that verdict; one written before it
    /// decodes with none.
    @Test func theStartupCacheRemembersTheSupersededRuns() throws {
        let saved = StartupPresentation(
            home: "/h", hostID: "host", nodes: [], pins: [:], unreadIDs: [],
            supersededRunIDs: ["run-2"]
        )
        let decoded = try JSONDecoder().decode(
            StartupPresentation.self, from: try JSONEncoder().encode(saved)
        )
        #expect(decoded.supersededRunIDs == ["run-2"])

        let older = #"{"version":1,"home":"/h","hostID":"host","nodes":[],"pins":{},"unreadIDs":[]}"#
        let decodedOlder = try JSONDecoder().decode(StartupPresentation.self, from: Data(older.utf8))
        #expect(decodedOlder.supersededRunIDs == nil)
    }

    private func local(_ id: String, spawnedBy: String?) -> SessionEntry {
        var entry = SessionEntry(
            id: id, projectID: "p", label: id, command: "true", createdAt: 1, status: .exited
        )
        entry.spawnedBy = spawnedBy
        return entry
    }
}

private let project = Project(
    id: "p", name: "Project", path: "/project", parentProjectID: nil, sortOrder: 0,
    isFolder: nil, worktreeBranch: nil, workspacesEnabled: nil, mcpBlocked: nil
)

private func row(
    _ id: String,
    status: RemoteSessionStatus,
    activity: RemoteActivityState,
    unread: Bool = false,
    scheduleID: String? = nil,
    superseded: Bool = false
) -> RemoteSessionSummary {
    RemoteSessionSummary(
        id: id, projectID: "p", title: id, command: "claude",
        createdAtUnixMs: 1, status: status, activity: activity, unread: unread,
        scheduleID: scheduleID, superseded: superseded
    )
}
