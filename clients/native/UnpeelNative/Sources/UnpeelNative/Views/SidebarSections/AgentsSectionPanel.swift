//
//  AgentsSectionPanel.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. AGENTS: the titlebar activity dropdown —
//  blocked, working, then recently finished agents, and the "All recent"
//  link — as a section below PROJECTS. Pinned sessions follow, so they
//  never drop out of it. Unlike the bell (which stays, across every
//  workspace), it lists the current workspace only, and its rows carry the
//  PROJECTS session menu (`AgentsSessionRow`) and selection chip.
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

    private static func sessionIDs(_ activity: GlobalActivityMenuSessions) -> Set<String> {
        Set((activity.blockers + activity.jobs + activity.finished + activity.pinned)
            .map(\.session.sessionID))
    }

    var body: some View {
        let activity = model.currentWorkspaceActivity
        ActivityMenuList(
            jobs: activity.jobs,
            blockers: activity.blockers,
            finished: activity.finished,
            pinned: activity.pinned,
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
            },
            // The PROJECTS per-id token: a selection change repaints only
            // the old and new chips, never the rows or an open menu.
            selectionState: { [store] item in
                store.sessionSelection.rowState(for: item.session.sessionID)
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
