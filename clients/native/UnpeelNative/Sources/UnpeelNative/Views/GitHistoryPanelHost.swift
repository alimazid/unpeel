//
//  GitHistoryPanelHost.swift
//  UnpeelNative
//
//  Fork-only: git support. Where Git History meets app state: it follows
//  the same Explorer Root as the EXPLORER (`ExplorerPanelHost.context`, so
//  the worktree-over-project rule and the remote / no-Session cases are
//  shared) and keeps its view model alive while the section is collapsed.
//

import AppKit
import SwiftUI
import UnpeelExplorer
import UnpeelGit

/// Git History's view model outlives the section's content, like
/// `ExplorerSectionModel`. Publishes nothing: owning it never re-renders
/// the sidebar.
@MainActor
final class GitHistorySectionModel: ObservableObject {
    let viewModel: GitHistoryViewModel
    private var activeHost = SectionMountClaim()

    init(viewModel: GitHistoryViewModel = GitHistoryViewModel()) {
        self.viewModel = viewModel
    }

    func claim(_ token: UUID) {
        activeHost.claim(token)
    }

    func release(_ token: UUID) -> Bool {
        activeHost.release(token)
    }
}

struct GitHistoryPanelHost: View {
    @ObservedObject var store: UnpeelStore
    /// Selection publishes separately from the store (see
    /// `ExplorerPanelHost.selection`).
    @ObservedObject private var selection: SessionSelectionState
    private let section: GitHistorySectionModel
    @State private var mountToken = UUID()

    init(store: UnpeelStore, section: GitHistorySectionModel) {
        self.store = store
        self.selection = store.sessionSelection
        self.section = section
    }

    private var resolvedContext: ExplorerContext {
        ExplorerPanelHost.context(store: store, sessionID: selection.sessionID)
    }

    static var palette: GitHistoryPalette {
        GitHistoryPalette(
            text: NSColor(Theme.foreground),
            secondaryText: NSColor(Theme.mutedForeground),
            rowFont: Theme.rowLabelNSFont
        )
    }

    var body: some View {
        GitHistoryPanelView(viewModel: section.viewModel, palette: Self.palette)
            .onAppear {
                section.claim(mountToken)
                section.viewModel.setContext(resolvedContext)
            }
            .onChange(of: resolvedContext) { section.viewModel.setContext($0) }
            // Collapsed or hidden: no git reads and no repository watching
            // behind a section nobody can see. Re-expanding reloads.
            .onDisappear {
                guard section.release(mountToken) else { return }
                section.viewModel.setContext(.none)
            }
    }
}
