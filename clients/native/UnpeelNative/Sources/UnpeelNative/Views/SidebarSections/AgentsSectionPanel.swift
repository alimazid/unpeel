//
//  AgentsSectionPanel.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. AGENTS: the titlebar activity dropdown —
//  blocked, working, then recently finished agents across every
//  workspace, and the "All recent" link — as a section below PROJECTS.
//  The titlebar bell stays as well.
//

import SwiftUI

struct AgentsSectionPanel: View {
    /// For the row and footer actions only; the parent re-renders this
    /// view on store changes, so nothing here observes the whole store.
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

    var body: some View {
        ActivityMenuList(
            jobs: model.activity.jobs,
            blockers: model.activity.blockers,
            finished: model.activity.finished,
            onSelect: { [store] item in
                store.revealGlobalActivitySession(
                    workspaceKey: item.workspaceKey,
                    sessionID: item.session.sessionID
                )
            },
            onShowAll: showsAllRecent ? { [store] in store.openRecentActivity() } : nil,
            fillsHeight: true
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        // The bell refreshed workspace names and tints on every open; the
        // section does it each time it mounts (launch, expand).
        .onAppear { model.refreshWorkspaceMetadata() }
    }
}
