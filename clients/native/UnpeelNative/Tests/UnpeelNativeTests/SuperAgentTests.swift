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

    // MARK: - Fixtures

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
