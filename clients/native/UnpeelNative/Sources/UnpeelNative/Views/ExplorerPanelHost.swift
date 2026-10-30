//
//  ExplorerPanelHost.swift
//  UnpeelNative
//
//  The only place the file explorer library meets app state: it derives the
//  explorer context from the selected session and performs the three actions
//  the library cannot (open through the open-with rules, open in the user's
//  editor, paste into the terminal).
//

import AppKit
import os
import SwiftUI
import UnpeelExplorer
import UnpeelGit

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
    /// The session whose root the tree shows (`selection.sessionID`, set by
    /// `ExplorerPanelHost.sync`). Opens attach plugin panes to THIS session,
    /// never to the focused pane of a split — that pane may live in another
    /// worktree, see the `root` comment above.
    var rootSessionID: String?
    private static let logger = Logger(subsystem: "com.unpeel.explorer", category: "host")

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

    /// Markdown opens as a rendered preview pane beside the tree's session
    /// (Fork-only: markdown preview pane); everything else goes through the
    /// open-with rules, exactly the routine behind a terminal ⌘-click.
    func openFile(path: String) {
        if MarkdownFileTypes.isMarkdown(path), let store, let sessionID = rootSessionID {
            store.openMarkdownPreview(path: path, besideSession: sessionID)
            return
        }
        // Fork-only: markdown preview pane (M3) — every non-markdown file
        // still goes through the generic open-with rules below.
        openWithRules(path: path)
    }

    /// For markdown files this is the Markdown plugin, the registry default
    /// — the context-menu item shown on markdown files routes here directly
    /// (`openWithRules` would land on the same plugin for a `.md` path
    /// anyway, since it is the registry's default handler for the type).
    func openMarkdownEditor(path: String) {
        openWithRules(path: path)
    }

    /// The open-with rules: registry match by extension (`.md` → Markdown
    /// plugin), Settings ▸ Open With override, else the editor; the plugin
    /// pane attaches to the TREE's session (`rootSessionID`). `openClickedFile`
    /// returns `false` when the file no longer resolves locally (the watcher
    /// removes the row moments later) or, in remote scope — where this panel
    /// shows no tree anyway — when no plugin claims the type; either way
    /// there is nothing more to do than note it. Shared by `openFile`'s
    /// non-markdown fallthrough and `openMarkdownEditor` (Fork-only:
    /// markdown preview pane, M3 — the two used to be one method wrongly
    /// named after only one of its callers).
    private func openWithRules(path: String) {
        guard let store else {
            openInEditor(path: path)
            return
        }
        switch ExplorerContextResolver.openRoute(sessionID: rootSessionID) {
        case .editor:
            openInEditor(path: path)
        case let .rules(sessionID):
            let match = ClickablePath.Match(path: path, line: nil, column: nil)
            if !store.openClickedFile(match, path: path, fromSessionID: sessionID) {
                Self.logger.info("open declined for \(path, privacy: .private)")
            }
        }
    }

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

/// Fork-only: sidebar sections. The explorer's view model and host actions
/// outlive the EXPLORER section's content, so the section header can show
/// the panel menu while the tree itself is unmounted (collapsed or hidden).
/// Publishes nothing: owning it never re-renders the sidebar.
@MainActor
final class ExplorerSectionModel: ObservableObject {
    let viewModel: ExplorerViewModel
    let actions = ExplorerHostActions()

    /// The identity of the most recently mounted `ExplorerPanelHost`. Not
    /// `@Published` — the model must keep publishing nothing.
    ///
    /// SwiftUI can deliver a new host's `onAppear` before an old host's
    /// `onDisappear` when the view's identity changes (observed: `appear`
    /// for the new instance, then `disappear` for the old one). Both hosts
    /// share this one model, so an unconditional `setContext(.none)` in
    /// `onDisappear` would blank the tree and stop its watcher out from
    /// under the new host that is already on screen. `claim`/`release` make
    /// that ordering safe: only the host that is still the active claim may
    /// tear down.
    private var activeHost = SectionMountClaim()
    /// Fork-only: git support. A reveal asked for while the tree was not
    /// mounted (EXPLORER collapsed or hidden): applied when it next opens,
    /// so a changed file opened from Git History still ends up selected
    /// without the EXPLORER expanding over Git History.
    private var pendingReveal: String?

    /// Fork-only: nested repositories. `repositoryRoots` is shared with
    /// Git History, so both follow the same repository.
    init(defaults: UserDefaults = AppDefaults.shared, repositoryRoots: GitRepositoryRoots = .app) {
        viewModel = ExplorerViewModel(
            services: .live(repositoryRoots: repositoryRoots),
            stateStore: ExplorerStateStore(defaults: defaults)
        )
    }

    /// Fork-only: git support. Reveals `path` in the tree now when it is
    /// showing, otherwise the next time it opens.
    @discardableResult
    func reveal(_ path: String) -> Task<Void, Never> {
        guard activeHost.isClaimed else {
            pendingReveal = path
            return Task {}
        }
        pendingReveal = nil
        return viewModel.reveal(path)
    }

    /// Shows `context` in the tree, then applies a reveal saved while the
    /// tree was not mounted.
    @discardableResult
    func open(_ context: ExplorerContext) -> Task<Void, Never> {
        let opening = viewModel.setContext(context)
        guard let path = pendingReveal, activeHost.isClaimed else { return opening }
        pendingReveal = nil
        return Task {
            await opening.value
            await self.viewModel.reveal(path).value
        }
    }

    /// Marks `token` as the active host. Call from `onAppear`, before
    /// syncing the tree's context.
    func claim(_ token: UUID) {
        activeHost.claim(token)
    }

    /// Releases `token`. Returns whether it was still the active host —
    /// callers must only tear down shared state (persist + stop the
    /// watcher) when this returns `true`; a superseded host's own teardown
    /// (its claim already replaced by a newer host's `onAppear`) is a no-op.
    func release(_ token: UUID) -> Bool {
        activeHost.release(token)
    }
}

/// Fork-only: git support (extracted from `ExplorerSectionModel`). Which
/// mounted host of a section's shared model is the current one: SwiftUI can
/// deliver a new host's `onAppear` before the old host's `onDisappear`, so
/// only the most recent claim may tear the shared model down.
struct SectionMountClaim {
    private var active: UUID?

    /// Whether a host is mounted.
    var isClaimed: Bool { active != nil }

    mutating func claim(_ token: UUID) {
        active = token
    }

    /// Whether `token` was still the active claim (and is now released).
    mutating func release(_ token: UUID) -> Bool {
        guard active == token else { return false }
        active = nil
        return true
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
    @ObservedObject private var viewModel: ExplorerViewModel
    private let actions: ExplorerHostActions
    private let section: ExplorerSectionModel
    /// This host instance's identity, claimed on `onAppear` and released on
    /// `onDisappear` — see `ExplorerSectionModel.activeHost`.
    @State private var mountToken = UUID()
    let cache: SurfaceCache

    init(store: UnpeelStore, cache: SurfaceCache, section: ExplorerSectionModel) {
        self.store = store
        self.selection = store.sessionSelection
        self.viewModel = section.viewModel
        self.actions = section.actions
        self.section = section
        self.cache = cache
    }

    /// The tree root follows the SELECTED session, never the focused pane
    /// within a split (`ExplorerHostActions.targetSessionID` is for the
    /// paste action; opens use `rootSessionID`, the tree's own session):
    /// `setContext` on a changed root tears down the
    /// watcher, blanks the panel, and rescans, so keying the tree to pane
    /// focus would blank/rebuild it on every click between panes in
    /// different worktrees. `focusedSoloSessionID` also covers the
    /// right-hand project panel's panes (`UnpeelStore.focusedSoloSessionID`),
    /// which would yank the tree to a worktree the main area is not even
    /// showing. Static so the section header resolves the same root.
    static func context(store: UnpeelStore, sessionID: String?) -> ExplorerContext {
        let session = sessionID.flatMap { store.displaySessionsByID[$0] }
        return ExplorerContextResolver.resolve(
            isLocalScope: store.selectedHostScope == .local,
            hasSession: session != nil,
            worktreePath: session?.worktreePath,
            projectPath: session.flatMap { store.displayProjectsByID[$0.projectID]?.path },
            fallbackDirectory: session.flatMap { store.paneWorkingDirectory(for: $0) }
        )
    }

    private var resolvedContext: ExplorerContext {
        Self.context(store: store, sessionID: selection.sessionID)
    }

    static var palette: ExplorerPalette {
        ExplorerPalette(
            text: NSColor(Theme.foreground),
            secondaryText: NSColor(Theme.mutedForeground),
            rowFont: Theme.rowLabelNSFont
        )
    }

    var body: some View {
        ExplorerPanelView(viewModel: viewModel, palette: Self.palette, actionHandler: actions, showsHeader: false)
            .onAppear {
                section.claim(mountToken)
                sync(resolvedContext)
            }
            .onChange(of: resolvedContext) { sync($0) }
            // Two sessions in the same worktree resolve to an EQUAL context,
            // so the `onChange` above never fires when switching between
            // them; the open target must still follow the selection or a
            // plugin pane would attach to the previously selected session.
            .onChange(of: selection.sessionID) { actions.rootSessionID = $0 }
            // Collapsed or hidden: persist the tree's state and stop the
            // FSEvents watcher (`setContext` does both); re-expanding
            // re-opens the root and restores the saved expansions. Only the
            // still-active host may do this — see `ExplorerSectionModel`.
            .onDisappear {
                guard section.release(mountToken) else { return }
                viewModel.setContext(.none)
            }
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
        actions.rootSessionID = selection.sessionID
        actions.cache = cache
        if case .local(let root, _) = context {
            actions.root = CanonicalPath.resolve(root) ?? root
        } else {
            actions.root = nil
        }
        section.open(context)
    }
}
