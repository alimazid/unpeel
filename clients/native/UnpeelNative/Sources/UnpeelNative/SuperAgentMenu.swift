//
//  SuperAgentMenu.swift
//  UnpeelNative
//
//  Fork-only: which Super Agent items one Session's right-click menu
//  offers — Make Super Agent, Stop Being Super Agent, Hand to Super Agent.
//  The Host decides again on every verb (`supervision/controller.rs`); these
//  are the same rules, so the menu never offers what the Host refuses.
//

import UnpeelShared

struct SuperAgentMenu: Equatable {
    var canMake = false
    var canStopBeing = false
    var canHandOver = false

    static let none = SuperAgentMenu()

    init(canMake: Bool = false, canStopBeing: Bool = false, canHandOver: Bool = false) {
        self.canMake = canMake
        self.canStopBeing = canStopBeing
        self.canHandOver = canHandOver
    }

    /// `routerID` is the workspace's Super Agent, if any; `supports` answers
    /// whether the Host advertises one operation id.
    init(session: SessionEntry, routerID: String?, supports: (String) -> Bool) {
        typealias Operation = RemoteHostRuntime.HostOperation
        let isRouter = session.superAgent || session.id == routerID
        // Clearing does not need the Session running: the mark outlives it.
        canStopBeing = isRouter && supports(Operation.superAgentClear)
        // Both other verbs need a running agent that is not the Router.
        guard !isRouter, session.isLive,
              let runtime = Self.runtime(of: session), runtime.kind == .agent
        else { return }
        // The runtime package says whether it may be the Super Agent.
        canMake = runtime.capabilities.contains(.superAgent)
            && supports(Operation.superAgentSet)
        canHandOver = routerID != nil
            && session.superAgentRouterID != routerID
            && supports(Operation.superAgentHandOver)
    }

    /// The Host's rule: an observed foreground runtime always wins (a
    /// `claude` launch now running something else is that something else);
    /// only when nothing is observed does the launch command decide.
    static func runtime(of session: SessionEntry) -> UnpeelRuntimeMetadata? {
        let observed = session.activeRuntimeID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !observed.isEmpty else {
            return UnpeelRuntimeCatalog.runtime(command: session.command)
        }
        return UnpeelRuntimeCatalog.runtime(id: observed)
            ?? UnpeelRuntimeCatalog.runtime(command: observed)
    }

    /// The Session the Host marked as this workspace's Super Agent. The Host
    /// keeps at most one; the smallest id keeps a malformed snapshot stable.
    static func routerID<S: Sequence>(in summaries: S) -> String?
    where S.Element == RemoteSessionSummary {
        summaries.filter(\.superAgent).map(\.id).min()
    }
}
