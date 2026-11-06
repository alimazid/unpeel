//
//  AgentsSectionPanel.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. AGENTS: the titlebar activity dropdown —
//  blocked, working, then recently finished agents, and the "All recent"
//  link — as a section below PROJECTS. Pinned sessions and the Super Agent
//  follow, so they never drop out of it; the Super Agent's running Workers
//  are indented under it (`SuperAgentNesting`). Unlike the bell (which
//  stays, across every workspace), it lists the current workspace only, and
//  its rows carry the PROJECTS session menu (`AgentsSessionRow`).
//

import SwiftUI

struct AgentsSectionPanel: View {
    /// For the row and footer actions only. Each row observes the store
    /// itself (`AgentsSessionRowHost`): SwiftUI does not re-run the shared
    /// list's body for a store-only change such as an armed confirmation.
    let store: UnpeelStore
    /// Same rule as the titlebar: the persisted history page is
    /// local-only, so the "All recent" link is too.
    let showsAllRecent: Bool
    @ObservedObject private var model: GlobalActivityMenuModel

    init(store: UnpeelStore, showsAllRecent: Bool) {
        self.store = store
        self.showsAllRecent = showsAllRecent
        self.model = store.globalActivityMenu
    }

    /// The Sessions the section shows a row for, the nested Workers
    /// included — the same entries the list renders.
    static func sessionIDs(_ activity: GlobalActivityMenuSessions) -> Set<String> {
        let entries = ActivityMenuList.entries(
            blockers: activity.blockers, jobs: activity.jobs,
            finished: activity.finished, pinned: activity.pinned,
            workers: activity.workers, nestsWorkers: true
        )
        return Set(entries.compactMap { entry in
            guard case let .row(item, _) = entry else { return nil }
            return item.session.sessionID
        })
    }

    var body: some View {
        let activity = model.currentWorkspaceActivity
        ActivityMenuList(
            jobs: activity.jobs,
            blockers: activity.blockers,
            finished: activity.finished,
            pinned: activity.pinned,
            workers: activity.workers,
            nestsWorkers: true,
            onSelect: { [store] item in
                store.revealGlobalActivitySession(
                    workspaceKey: item.workspaceKey,
                    sessionID: item.session.sessionID
                )
            },
            onShowAll: showsAllRecent ? { [store] in store.openRecentActivity() } : nil,
            fillsHeight: true,
            showsWorkspaceName: false,
            wrapRow: { [store] item, style, row in
                AnyView(AgentsSessionRowHost(store: store, item: item, style: style, row: row))
            }
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        // The bell refreshed workspace names and tints on every open; the
        // section does it each time it mounts (launch, expand).
        .onAppear { model.refreshWorkspaceMetadata() }
        // A rename or confirmation this section owns ends with its row:
        // nothing else would show it.
        .onChange(of: Self.sessionIDs(activity)) { [store] ids in
            store.endAgentsSectionInlineState(keeping: ids)
        }
        .onDisappear { [store] in store.endAgentsSectionInlineState(keeping: []) }
    }
}
