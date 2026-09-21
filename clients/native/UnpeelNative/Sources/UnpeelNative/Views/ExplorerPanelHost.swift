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
    /// Canonical (realpath-resolved) explorer browsing root. Only a
    /// FALLBACK for `dropReference` now — used solely when the target pane's
    /// own directory (`targetPaneDirectory`) cannot be resolved — because the
    /// tree's root and the focused pane's session can differ (a split across
    /// worktrees, or a focused pane in the right-hand project panel), and
    /// shortening against the wrong one is exactly the bug this file was
    /// re-reviewed for: two worktrees of the same repo mirror each other, so
    /// a reference built against tree A but pasted into a shell rooted at B
    /// looks right while silently naming B's copy.
    var root: String?

    private var targetSessionID: String? {
        ExplorerContextResolver.targetSessionID(
            activePane: store?.activeTerminalPane?.sessionID,
            focusedSolo: store?.focusedSoloSessionID,
            selected: store?.selectedSessionID
        )
    }

    /// The exact directory the TARGET pane's own (private)
    /// `projectRootDirectory` was seeded with: `UnpeelStore.paneWorkingDirectory`
    /// is that same seed rule, so this is the one true basis for shortening a
    /// path pasted into that pane — never the explorer tree's root, which
    /// may belong to a different session entirely.
    private var targetPaneDirectory: String? {
        guard let sessionID = targetSessionID,
              let session = store?.displaySessionsByID[sessionID],
              let directory = store?.paneWorkingDirectory(for: session)
        else { return nil }
        return CanonicalPath.resolve(directory) ?? directory
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
    /// drop would — against the TARGET pane's own directory
    /// (`targetPaneDirectory`), falling back to the tree's `root` only when
    /// that cannot be resolved (see `dropRoot`). `path` always comes from
    /// the panel's own outline, whose rows are the library's
    /// root-constrained scan — there is no untrusted input here to validate.
    func sendPathToAgent(path: String) {
        guard let pane = selectedPane else { return }
        let dropRoot = ExplorerContextResolver.dropRoot(
            targetPaneDirectory: targetPaneDirectory,
            explorerRoot: root
        )
        let reference = ExplorerContextResolver.dropReference(for: path, dropRoot: dropRoot)
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
            // Quitting does not dismantle the view hierarchy, so
            // `onDisappear` never fires on termination: without this, the
            // selection and scroll offset since the last expand/collapse or
            // context switch (the only other things that persist) are lost.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                viewModel.persistState()
            }
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
