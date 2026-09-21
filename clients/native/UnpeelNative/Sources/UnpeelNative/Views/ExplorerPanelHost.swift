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
    /// Canonical (realpath-resolved) explorer browsing root — the base
    /// `ExplorerContextResolver.dropReference` shortens a dropped path
    /// against. This is the browsing root (worktree-aware), not the outer
    /// project root: the terminal's own drop handler shortens against the
    /// pane's own working directory (`GhosttyTerminalPane.projectRootDirectory`,
    /// private), which for a worktree session is the worktree itself, so
    /// using the outer project root here would paste a path (e.g.
    /// `.worktrees/fix/src/a.swift`) that resolves nowhere from that
    /// directory, unlike a real drag onto the same pane.
    var root: String?

    private var targetSessionID: String? {
        ExplorerContextResolver.targetSessionID(
            activePane: store?.activeTerminalPane?.sessionID,
            focusedSolo: store?.focusedSoloSessionID,
            selected: store?.selectedSessionID
        )
    }

    private var selectedPane: GhosttyTerminalPane? {
        guard let sessionID = targetSessionID else { return nil }
        return cache?.existingPane(for: sessionID)
    }

    var canSendToAgent: Bool { selectedPane != nil }

    func openInEditor(path: String) {
        store?.openInEditor(path: path)
    }

    /// The same path a Finder drop onto the terminal takes:
    /// `GhosttyTerminalPane.insertAttachablePath` focuses the pane and PASTES
    /// (bracketed paste — agent TUIs only recognize an attachable reference,
    /// including an image, when it arrives as a paste; `sendText` is that
    /// method's own no-clipboard fallback, not something to reimplement
    /// here), after `dropReference` shortens the path exactly like a real
    /// drop would. `path` always comes from the panel's own outline, whose
    /// rows are the library's root-constrained scan — there is no untrusted
    /// input here to validate.
    func sendPathToAgent(path: String) {
        guard let pane = selectedPane else { return }
        let reference = ExplorerContextResolver.dropReference(for: path, dropRoot: root)
        pane.insertAttachablePath(reference)
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

    /// The tree root follows the SELECTED session, never the focused pane
    /// within a split (`ExplorerHostActions.targetSessionID` is for the
    /// paste action only): `setContext` on a changed root tears down the
    /// watcher, blanks the panel, and rescans, so keying the tree to pane
    /// focus would blank/rebuild it on every click between panes in
    /// different worktrees. `focusedSoloSessionID` also covers the
    /// right-hand project panel's panes (`UnpeelStore.focusedSoloSessionID`),
    /// which would yank the tree to a worktree the main area is not even
    /// showing.
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
            actions.root = CanonicalPath.resolve(root) ?? root
        } else {
            actions.root = nil
        }
        viewModel.setContext(context)
    }
}
