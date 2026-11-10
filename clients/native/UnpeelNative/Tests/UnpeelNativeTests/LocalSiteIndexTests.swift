import XCTest
import UnpeelShared
@testable import UnpeelNative

/// Fork-only (#63): the Local site index the project globe and the title
/// strip's site chip read, and the Local Host projection that fills it.
/// Fork-only (#73): a scoped local workspace's chip, from that workspace's
/// own snapshots.
final class LocalSiteIndexTests: XCTestCase {
    private typealias Server = LocalSiteIndex.Server

    func testAFamilyCollectsItsGroupsAndWorktreesSitesOnePerOrigin() {
        let index = LocalSiteIndex(
            servers: [
                Server(sessionID: "deep", projectID: "group", createdAt: 1, urls: ["http://localhost:5173/docs/"]),
                Server(sessionID: "root", projectID: "site", createdAt: 2, urls: ["http://localhost:5173/"]),
                Server(sessionID: "api", projectID: "worktree", createdAt: 3, urls: ["http://127.0.0.1:8080/"]),
                Server(sessionID: "other", projectID: "elsewhere", createdAt: 0, urls: ["http://localhost:3000/"]),
            ],
            parentByProjectID: ["group": "site", "worktree": "group"]
        )

        // The parent URL wins its origin; origins keep creation order.
        XCTAssertEqual(
            index.candidates(forProjectFamilyOf: "site"),
            ["http://localhost:5173/", "http://127.0.0.1:8080/"]
        )
        XCTAssertEqual(index.candidates(forProjectFamilyOf: "worktree"), index.candidates(forProjectFamilyOf: "site"))
        XCTAssertEqual(index.candidates(forProjectFamilyOf: "elsewhere"), ["http://localhost:3000/"])
        XCTAssertEqual(index.candidates(forProjectFamilyOf: "unknown"), [])
    }

    func testOrderAndEqualityDoNotDependOnTheOrderServersArrive() {
        let first = Server(sessionID: "a", projectID: "site", createdAt: 5, urls: ["http://localhost:1111/"])
        let second = Server(sessionID: "b", projectID: "site", createdAt: 5, urls: ["http://localhost:2222/"])
        let forward = LocalSiteIndex(servers: [first, second], parentByProjectID: [:])
        let backward = LocalSiteIndex(servers: [second, first], parentByProjectID: [:])

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.candidates(forProjectFamilyOf: "site"), ["http://localhost:1111/", "http://localhost:2222/"])
    }

    func testAnIndexThatServesNothingIsEmpty() {
        let index = LocalSiteIndex(
            servers: [Server(sessionID: "shell", projectID: "group", createdAt: 1, urls: [])],
            parentByProjectID: ["group": "site"]
        )
        XCTAssertEqual(index, .empty)
        XCTAssertTrue(index.isEmpty)
    }

    func testAParentCycleEndsTheWalk() {
        let index = LocalSiteIndex(
            servers: [Server(sessionID: "s", projectID: "a", createdAt: 1, urls: ["http://localhost:1/"])],
            parentByProjectID: ["a": "b", "b": "a"]
        )
        XCTAssertEqual(index.candidates(forProjectFamilyOf: "a"), ["http://localhost:1/"])
    }

    func testTheDiskScanPlacesEachSiteByItsSessionsProject() {
        let session = SessionEntry(
            id: "server", projectID: "group", label: "dev", command: "npm run dev",
            createdAt: 4, status: .idle
        )
        let index = LocalSiteIndex.fromScan(
            urlsBySession: ["server": ["http://localhost:5173/"], "gone": ["http://localhost:9/"]],
            sessions: ["server": session],
            projects: ["site": Self.diskProject("site", parent: nil), "group": Self.diskProject("group", parent: "site")]
        )

        XCTAssertEqual(index.servers, [
            Server(sessionID: "server", projectID: "group", createdAt: 4, urls: ["http://localhost:5173/"]),
        ])
        XCTAssertEqual(index.candidates(forProjectFamilyOf: "site"), ["http://localhost:5173/"])
    }

    func testAHostSnapshotIndexesOnlyTheSessionsThatServeASite() {
        let index = LocalSiteIndex.fromHost(
            sessions: [
                Self.session("server", project: "group", createdAt: 7, urls: ["http://127.0.0.1:18763/"]),
                Self.session("shell", project: "site", createdAt: 3, urls: []),
            ],
            projects: [Self.project("site"), Self.project("group", parent: "site")]
        )

        XCTAssertEqual(index.servers, [
            Server(sessionID: "server", projectID: "group", createdAt: 7, urls: ["http://127.0.0.1:18763/"]),
        ])
        XCTAssertEqual(index.candidates(forProjectFamilyOf: "site"), ["http://127.0.0.1:18763/"])
    }

    /// The bug: a site that starts after launch reaches the store through the
    /// Local Host's snapshot, on a Session the launch scan never saw.
    @MainActor
    func testTheLocalHostProjectionCarriesASiteThatStartedAfterLaunch() {
        let url = "http://127.0.0.1:18763/"
        let store = UnpeelStore.sidebarFixture(
            snapshot: Self.snapshot(sessions: [Self.session("shell", project: "site", createdAt: 1, urls: [])]),
            expandedProjectIDs: ["site"]
        )
        store.noteLocalURLVerdictForTesting(url: url, probePassed: true)
        XCTAssertEqual(store.knownLocalSiteURLs(forProjectFamilyOf: "site", in: store.localSites), [])

        store.projectRemoteScope(snapshot: Self.snapshot(sessions: [
            Self.session("shell", project: "site", createdAt: 1, urls: []),
            Self.session("server", project: "site", createdAt: 2, urls: [url]),
        ]))
        XCTAssertEqual(store.knownLocalSiteURLs(forProjectFamilyOf: "site", in: store.localSites), [url])

        // The server stops: the Host drops it from the row.
        store.projectRemoteScope(snapshot: Self.snapshot(sessions: [
            Self.session("shell", project: "site", createdAt: 1, urls: []),
            Self.session("server", project: "site", createdAt: 2, urls: []),
        ]))
        XCTAssertEqual(store.knownLocalSiteURLs(forProjectFamilyOf: "site", in: store.localSites), [])
    }

    /// A scoped local workspace's Sessions run on this Mac too, so its chip
    /// opens their sites. Local's own index never takes them: the Local
    /// pooled page reads it while this scope is selected.
    @MainActor
    func testAScopedLocalWorkspacesChipKnowsItsOwnSites() {
        let url = "http://127.0.0.1:18764/"
        let store = UnpeelStore.sidebarFixture(snapshot: Self.snapshot(sessions: []), expandedProjectIDs: [])
        store.noteLocalURLVerdictForTesting(url: url, probePassed: true)
        let scoped = Self.snapshot(sessions: [Self.session("server", project: "site", createdAt: 2, urls: [url])])
        store.selectLocalWorkspace(
            home: LaunchConfig.unpeelDir.appendingPathComponent("chip-scope").path, name: "Chip"
        )
        store.remoteHostRuntime.holdSnapshotForTesting(scoped)
        store.projectRemoteScope(snapshot: scoped)

        XCTAssertEqual(store.localSiteURLs(forProjectFamilyOf: "site"), [url])
        XCTAssertTrue(store.localSites.isEmpty, "Local's own index never takes them")

        // The server stops: the workspace's Host drops it from the row.
        let stopped = Self.snapshot(sessions: [Self.session("server", project: "site", createdAt: 2, urls: [])])
        store.remoteHostRuntime.holdSnapshotForTesting(stopped)
        store.projectRemoteScope(snapshot: stopped)
        XCTAssertEqual(store.localSiteURLs(forProjectFamilyOf: "site"), [])
    }

    private static func diskProject(_ id: String, parent: String?) -> Project {
        Project(
            id: id, name: id, path: "/fixture/\(id)", parentProjectID: parent, sortOrder: 0,
            isFolder: nil, worktreeBranch: nil, workspacesEnabled: nil, mcpBlocked: nil
        )
    }

    private static func snapshot(sessions: [RemoteSessionSummary]) -> RemoteBootstrapSnapshot {
        RemoteBootstrapSnapshot(
            folders: [], projects: [project("site")], presets: [], sessions: sessions, capturedAtUnixMs: 1
        )
    }

    private static func project(_ id: String, parent: String? = nil) -> RemoteProjectSummary {
        RemoteProjectSummary(id: id, name: id, path: "/fixture/\(id)", parentProjectID: parent)
    }

    private static func session(
        _ id: String, project: String, createdAt: Int64, urls: [String]
    ) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: id, projectID: project, title: id, command: "zsh", createdAtUnixMs: createdAt,
            status: .running, activity: .idle, detectedLocalURLs: urls
        )
    }
}
