//
//  SuperAgentNesting.swift
//  UnpeelNative
//
//  Fork-only: the AGENTS section lists the Super Agent's running Workers
//  indented under it, wherever their Project is. A Worker leaves the group
//  it would be in and keeps that group's look (blocked, working, finished,
//  pinned or idle). A stopped Worker, or one whose Super Agent is not
//  listed, is not nested. One level deep: a Super Agent is never a Worker.
//

struct SuperAgentNesting {
    struct Row: Equatable {
        let item: GlobalActivityMenuItem
        let style: ActivityMenuRowStyle
    }

    /// Nests nothing: the dropdowns.
    static let none = SuperAgentNesting()

    /// Super Agent → its Workers' rows, in display order, at depth 1.
    private let workersByRouter: [RouterKey: [Row]]
    private let nestedIDs: Set<String>

    private init() {
        workersByRouter = [:]
        nestedIDs = []
    }

    /// `groups` in display order. A group may hold only Workers (the idle
    /// ones): those not nested are not listed at all.
    init(_ groups: [(items: [GlobalActivityMenuItem], style: ActivityMenuRowStyle)]) {
        let routers = Set(groups.flatMap { $0.items }
            .filter { $0.session.superAgent }
            .map { RouterKey($0) })
        var workersByRouter: [RouterKey: [Row]] = [:]
        var nestedIDs = Set<String>()
        for group in groups {
            for item in group.items {
                guard let router = Self.router(of: item), routers.contains(router),
                      nestedIDs.insert(item.id).inserted
                else { continue }
                workersByRouter[router, default: []]
                    .append(Row(item: item, style: group.style.nested()))
            }
        }
        self.workersByRouter = workersByRouter
        self.nestedIDs = nestedIDs
    }

    /// `items` without the Workers listed under their Super Agent.
    func topLevel(_ items: [GlobalActivityMenuItem]) -> [GlobalActivityMenuItem] {
        nestedIDs.isEmpty ? items : items.filter { !nestedIDs.contains($0.id) }
    }

    /// The rows listed right after `item`: its Workers when it is the
    /// Super Agent.
    func workers(under item: GlobalActivityMenuItem) -> [Row] {
        guard item.session.superAgent else { return [] }
        return workersByRouter[RouterKey(item)] ?? []
    }

    /// A Super Agent row. The workspace is part of it, so a Worker never
    /// nests under another workspace's Super Agent.
    private struct RouterKey: Hashable {
        let workspaceKey: String
        let sessionID: String

        init(workspaceKey: String, sessionID: String) {
            self.workspaceKey = workspaceKey
            self.sessionID = sessionID
        }

        init(_ item: GlobalActivityMenuItem) {
            self.init(workspaceKey: item.workspaceKey, sessionID: item.session.sessionID)
        }
    }

    /// The Super Agent a running Worker works for.
    private static func router(of item: GlobalActivityMenuItem) -> RouterKey? {
        let session = item.session
        guard !session.superAgent, session.isLive,
              let routerID = session.superAgentRouterID
        else { return nil }
        return RouterKey(workspaceKey: item.workspaceKey, sessionID: routerID)
    }
}
