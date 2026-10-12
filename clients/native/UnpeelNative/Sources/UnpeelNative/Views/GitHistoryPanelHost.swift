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

/// A changed file clicked in an expanded commit: revealed in the EXPLORER
/// (when its tree is showing) and opened through the EXPLORER's own
/// open-with path — Markdown in the preview pane, other types by the
/// Settings ▸ Open With rules — attached to the Explorer Root's Session.
@MainActor
final class GitHistoryHostActions: GitHistoryActionHandler {
    let opener = ExplorerHostActions()
    /// Reveals a path in the EXPLORER; a no-op while its tree is unmounted.
    var reveal: (String) -> Void = { _ in }

    func openChangedFile(path: String) {
        reveal(path)
        opener.openFile(path: path)
    }
}

/// Git History's view model outlives the section's content, like
/// `ExplorerSectionModel`. Publishes nothing: owning it never re-renders
/// the sidebar.
@MainActor
final class GitHistorySectionModel: ObservableObject {
    let viewModel: GitHistoryViewModel
    let actions = GitHistoryHostActions()
    private var activeHost = SectionMountClaim()

    /// Reads with the shared runner and refreshes on its own: the
    /// repository monitor watches HEAD, the index and refs.
    init(viewModel: GitHistoryViewModel = GitHistoryViewModel(
        services: .reading(GitReader(), makeMonitor: GitRepositoryMonitor.make)
    )) {
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
    private let explorer: ExplorerSectionModel
    @State private var mountToken = UUID()

    init(store: UnpeelStore, section: GitHistorySectionModel, explorer: ExplorerSectionModel) {
        self.store = store
        self.selection = store.sessionSelection
        self.section = section
        self.explorer = explorer
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
        GitHistoryPanelView(viewModel: section.viewModel, palette: Self.palette, actionHandler: section.actions)
            .onAppear {
                section.claim(mountToken)
                sync(resolvedContext)
            }
            .onChange(of: resolvedContext) { sync($0) }
            // Two Sessions in one worktree share a context; opens must still
            // attach to the selected one (see `ExplorerPanelHost`).
            .onChange(of: selection.sessionID) { section.actions.opener.rootSessionID = $0 }
            // Collapsed or hidden: no git reads and no repository watching
            // behind a section nobody can see. Re-expanding reloads.
            .onDisappear {
                guard section.release(mountToken) else { return }
                section.viewModel.setContext(.none)
            }
    }

    private func sync(_ context: ExplorerContext) {
        let actions = section.actions
        actions.opener.store = store
        actions.opener.rootSessionID = selection.sessionID
        if case .local(let root, _) = context {
            actions.opener.root = CanonicalPath.resolve(root) ?? root
        } else {
            actions.opener.root = nil
        }
        actions.reveal = { [weak explorer] path in explorer?.viewModel.reveal(path) }
        section.viewModel.setContext(context)
    }
}
