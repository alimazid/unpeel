//
//  ExplorerPanelHost.swift
//  UnpeelNative
//
//  The only place the file explorer library meets app state: it derives the
//  explorer context from the selected session and performs the two actions
//  the library cannot (open in the user's editor, paste into the terminal).
//

import AppKit
import SwiftUI
import UnpeelExplorer

@MainActor
final class ExplorerHostActions: ExplorerActionHandler {
    weak var store: UnpeelStore?
    weak var cache: SurfaceCache?
    var root: String?

    private var selectedPane: GhosttyTerminalPane? {
        guard let sessionID = store?.selectedSessionID else { return nil }
        return cache?.existingPane(for: sessionID)
    }

    var canSendToAgent: Bool { selectedPane != nil }

    func openInEditor(path: String) {
        store?.openInEditor(path: path)
    }

    /// Same shape as dropping the file on the terminal: a shell-quoted path
    /// and a trailing space, never Enter.
    func sendPathToAgent(path: String) {
        guard let pane = selectedPane else { return }
        let reference = ExplorerContextResolver.agentReference(for: path, root: root ?? "")
        pane.sendText(GhosttyTerminalPane.quoteDropReference(reference) + " ")
    }
}

struct ExplorerPanelHost: View {
    @ObservedObject var store: UnpeelStore
    /// Selection has its own publication boundary (`SessionSelectionState`):
    /// `UnpeelStore.objectWillChange` deliberately does not fire on a plain
    /// session switch, so observing only `store` would leave the explorer
    /// showing the previous session's root (see `WorkspaceTitleStrip`, which
    /// observes selection for the same reason).
    @ObservedObject private var selection: SessionSelectionState
    let cache: SurfaceCache

    @StateObject private var viewModel = ExplorerViewModel(
        stateStore: ExplorerStateStore(defaults: AppDefaults.shared)
    )
    @State private var actions = ExplorerHostActions()

    init(store: UnpeelStore, cache: SurfaceCache) {
        self.store = store
        self.selection = store.sessionSelection
        self.cache = cache
    }

    private var resolvedContext: ExplorerContext {
        let session = selection.sessionID.flatMap { store.displaySessionsByID[$0] }
        return ExplorerContextResolver.resolve(
            isLocalScope: store.selectedHostScope == .local,
            hasSession: session != nil,
            worktreePath: session?.worktreePath,
            projectPath: session.flatMap { store.displayProjectsByID[$0.projectID]?.path },
            fallbackDirectory: session.flatMap { store.paneWorkingDirectory(for: $0) }
        )
    }

    private var palette: ExplorerPalette {
        ExplorerPalette(
            text: NSColor(Theme.foreground),
            secondaryText: NSColor(Theme.mutedForeground),
            rowFont: Theme.rowLabelNSFont
        )
    }

    var body: some View {
        ExplorerPanelView(viewModel: viewModel, palette: palette, actionHandler: actions)
            .onAppear { sync(resolvedContext) }
            .onChange(of: resolvedContext) { sync($0) }
            .onDisappear { viewModel.persistState() }
    }

    private func sync(_ context: ExplorerContext) {
        actions.store = store
        actions.cache = cache
        if case .local(let root, _) = context {
            actions.root = root
        } else {
            actions.root = nil
        }
        viewModel.setContext(context)
    }
}
