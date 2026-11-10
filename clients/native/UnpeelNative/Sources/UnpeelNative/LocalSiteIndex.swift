import UnpeelShared

/// Fork-only (#63): the loopback sites Sessions on this Mac serve, and the
/// project chains that group them into top-level project families. The
/// store's `localSites` is filled from Local's own source only: the disk scan
/// until the Local Host answers, then every Local Host snapshot. Never from
/// the selected scope's maps, because the Local pooled page can read it while
/// another workspace is selected (#57). A scoped local workspace keeps its
/// own (`scopedLocalSites`), and the Local pooled page builds one from the
/// snapshot it renders (#73).
struct LocalSiteIndex: Equatable {
    struct Server: Equatable {
        let sessionID: String
        let projectID: String
        let createdAt: Int64
        let urls: [String]
    }

    /// Sorted by creation time, then id, so equal content compares equal.
    let servers: [Server]
    let parentByProjectID: [String: String]

    static let empty = LocalSiteIndex(servers: [], parentByProjectID: [:])

    /// With no server, the project chains are dropped too, so a project
    /// edit alone never republishes an index that serves nothing.
    init(servers: [Server], parentByProjectID: [String: String]) {
        self.servers = servers
            .filter { !$0.urls.isEmpty }
            .sorted { ($0.createdAt, $0.sessionID) < ($1.createdAt, $1.sessionID) }
        self.parentByProjectID = self.servers.isEmpty ? [:] : parentByProjectID
    }

    /// The Local Host's word: each running Session's host-probed URLs.
    static func fromHost(
        sessions: [RemoteSessionSummary],
        projects: [RemoteProjectSummary]
    ) -> LocalSiteIndex {
        LocalSiteIndex(
            servers: sessions.map {
                Server(
                    sessionID: $0.id, projectID: $0.projectID,
                    createdAt: $0.createdAtUnixMs, urls: $0.detectedLocalURLs
                )
            },
            parentByProjectID: Dictionary(
                projects.compactMap { project in project.parentProjectID.map { (project.id, $0) } },
                uniquingKeysWith: { _, last in last }
            )
        )
    }

    /// The disk scan's word, before the Local Host answers: the URLs each
    /// live Session's manifest lists, placed by the scan's own maps.
    static func fromScan(
        urlsBySession: [String: [String]],
        sessions: [String: SessionEntry],
        projects: [String: Project]
    ) -> LocalSiteIndex {
        LocalSiteIndex(
            servers: urlsBySession.compactMap { sessionID, urls in
                sessions[sessionID].map {
                    Server(sessionID: sessionID, projectID: $0.projectID, createdAt: $0.createdAt, urls: urls)
                }
            },
            parentByProjectID: projects.compactMapValues(\.parentProjectID)
        )
    }

    var isEmpty: Bool { servers.isEmpty }

    /// Union of the URLs every Session in `projectID`'s family serves (the
    /// top-level project plus its groups and worktrees): the dev server
    /// usually runs in one Session while the user watches another. One row
    /// per server: each origin keeps the URL closest to its root, so a deep
    /// link survives only while no parent URL exists for the same origin.
    /// Origins keep their first server's creation order. Callers still hold
    /// each survivor to the current-rules probe.
    func candidates(forProjectFamilyOf projectID: String) -> [String] {
        let familyRoot = rootID(projectID)
        var byOrigin: [(origin: String, url: String)] = []
        for server in servers where rootID(server.projectID) == familyRoot {
            for url in server.urls {
                guard let origin = Self.urlOrigin(url) else { continue }
                if let index = byOrigin.firstIndex(where: { $0.origin == origin }) {
                    if Self.urlPathLength(url) < Self.urlPathLength(byOrigin[index].url) {
                        byOrigin[index].url = url
                    }
                } else {
                    byOrigin.append((origin, url))
                }
            }
        }
        return byOrigin.map(\.url)
    }

    private func rootID(_ id: String) -> String {
        var current = id
        var hops = 0
        while let parent = parentByProjectID[current], hops < 8 {
            current = parent
            hops += 1
        }
        return current
    }

    /// "http://localhost:5173/whatever" → "http://localhost:5173/".
    private static func urlOrigin(_ url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        let authority = rest.prefix(while: { $0 != "/" })
        return url[..<schemeEnd.upperBound] + authority + "/"
    }

    /// Path length after the authority; bare origin and "/" both count 0.
    private static func urlPathLength(_ url: String) -> Int {
        guard let schemeEnd = url.range(of: "://") else { return .max }
        let rest = url[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return 0 }
        return rest.distance(from: slash, to: rest.endIndex) - 1
    }
}
