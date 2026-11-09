import XCTest
import UnpeelShared
@testable import UnpeelNative

/// Fork-only (#63): the Local site index the project globe and the title
/// strip's site chip read, and the Local Host projection that fills it.
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

    func testAParentCycleEndsTheWalk() {
        let index = LocalSiteIndex(
            servers: [Server(sessionID: "s", projectID: "a", createdAt: 1, urls: ["http://localhost:1/"])],
            parentByProjectID: ["a": "b", "b": "a"]
        )
        _ = index.candidates(forProjectFamilyOf: "a")
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
        XCTAssertEqual(store.knownLocalSiteURLs(forProjectFamilyOf: "site"), [])

        store.projectRemoteScope(snapshot: Self.snapshot(sessions: [
            Self.session("shell", project: "site", createdAt: 1, urls: []),
            Self.session("server", project: "site", createdAt: 2, urls: [url]),
        ]))
        XCTAssertEqual(store.knownLocalSiteURLs(forProjectFamilyOf: "site"), [url])

        // The server stops: the Host drops it from the row.
        store.projectRemoteScope(snapshot: Self.snapshot(sessions: [
            Self.session("shell", project: "site", createdAt: 1, urls: []),
            Self.session("server", project: "site", createdAt: 2, urls: []),
        ]))
        XCTAssertEqual(store.knownLocalSiteURLs(forProjectFamilyOf: "site"), [])
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
