import Foundation

struct HostSession {
    let id: String
    let label: String
    let projectID: String
}

/// What the Host persisted: each Session's project, from its manifest.
func hostSessions() -> [HostSession] {
    guard let listScript else { return [] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: listScript)
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    return list.compactMap { session in
        guard let id = session["id"] as? String, let cwd = session["cwd"] as? String,
              let project = session["project_id"] as? String else { return nil }
        return HostSession(id: id, label: "~/w/Big/" + (cwd as NSString).lastPathComponent, projectID: project)
    }
}

func hostProjects() -> [String: String] {
    Dictionary(uniqueKeysWithValues: hostSessions().map { ($0.label, $0.projectID) })
}

func homeJSON(_ name: String) -> Any? {
    guard let fixtureHome,
          let data = FileManager.default.contents(atPath: (fixtureHome as NSString).appendingPathComponent(name))
    else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

/// The order the Host persisted for one list, as row labels.
func hostOrder(of projectID: String) -> [String] {
    guard let orders = homeJSON("session-order.json") as? [String: [String]] else { return [] }
    let labels = Dictionary(uniqueKeysWithValues: hostSessions().map { ($0.id, $0.label) })
    return (orders[projectID] ?? []).compactMap { labels[$0] }
}

/// The order the Host persisted for one list as it is on disk, folder ids and all.
func hostRawOrder(of projectID: String) -> [String] {
    (homeJSON("session-order.json") as? [String: [String]])?[projectID] ?? []
}

func hostProjectID(named name: String) -> String? {
    guard let state = homeJSON("app-state.json") as? [String: Any],
          let projects = state["projects"] as? [[String: Any]] else { return nil }
    return projects.first { ($0["name"] as? String) == name }?["id"] as? String
}

/// The project order the Host persisted, as project names. Empty until a first
/// project reorder writes it.
func hostProjectOrder() -> [String] {
    guard let ids = homeJSON("project-order.json") as? [String],
          let state = homeJSON("app-state.json") as? [String: Any],
          let projects = state["projects"] as? [[String: Any]] else { return [] }
    let names = projects.reduce(into: [String: String]()) { names, project in
        if let id = project["id"] as? String, let name = project["name"] as? String { names[id] = name }
    }
    return ids.compactMap { names[$0] }
}
