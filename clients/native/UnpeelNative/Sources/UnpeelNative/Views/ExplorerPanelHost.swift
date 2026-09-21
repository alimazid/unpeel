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
    /// Canonical (realpath-resolved) explorer browsing root. Every path the
    /// panel hands back derives from the view model's own canonical root
    /// (`CanonicalPath.resolve` in `ExplorerViewModel.open`), so comparing an
    /// action's `path` against a non-canonical root would silently disagree
    /// with the panel under a symlink (`/tmp`, `/var`, a symlinked checkout).
    var root: String?
    /// Canonical project root, passed to `conciseDropReference` exactly like
    /// the terminal's own Finder-drop handler does.
    var projectRoot: String?

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
    /// here), after `conciseDropReference` shortens the path exactly like a
    /// real drop would. A path outside the canonical root is refused rather
    /// than pasted as-is: see `root`'s doc comment.
    func sendPathToAgent(path: String) {
        guard isWithinRoot(path), let pane = selectedPane else { return }
        let reference = GhosttyTerminalPane.conciseDropReference(path, projectRoot: projectRoot)
        pane.insertAttachablePath(reference)
    }

    private func isWithinRoot(_ path: String) -> Bool {
        guard let root else { return false }
        guard let resolved = CanonicalPath.resolve(path) else { return false }
        return resolved == root || resolved.hasPrefix(root + "/")
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

    /// Same target session a user-facing action resolves
    /// (`ExplorerHostActions.targetSessionID`): in a split, `selection`
    /// alone names the pane group's representative, not the exact pane the
    /// user is looking at, so the tree would otherwise show one session's
    /// files while an action pastes into another. `activeTerminalPane` and
    /// `focusedSoloSessionID` both reach `store.objectWillChange` (the
    /// former is forwarded from `paneLayoutController`, the latter is
    /// `@Published` directly), so observing `store` here is enough to catch
    /// every pane-focus change.
    private var targetSessionID: String? {
        ExplorerContextResolver.targetSessionID(
            activePane: store.activeTerminalPane?.sessionID,
            focusedSolo: store.focusedSoloSessionID,
            selected: selection.sessionID
        )
    }

    private var resolvedContext: ExplorerContext {
        let session = targetSessionID.flatMap { store.displaySessionsByID[$0] }
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
        if case .local(let root, let projectRoot) = context {
            actions.root = CanonicalPath.resolve(root) ?? root
            actions.projectRoot = CanonicalPath.resolve(projectRoot) ?? projectRoot
        } else {
            actions.root = nil
            actions.projectRoot = nil
        }
        viewModel.setContext(context)
    }
}
