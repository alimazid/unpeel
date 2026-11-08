// Fork-only file (ADR 0009, #45): the live PROJECTS list. One lazy list
// whose children are rows (`UnpeelStore.sidebarTreeRows`), each composed by
// the row container for its kind. No lazy stack nests inside another, the
// shape every sidebar hang in #39 shares.

import SwiftUI

extension SelectedHostScope {
    /// The live PROJECTS list's identity. A scope switch swaps in a fresh
    /// list, so nothing glides, staggers or fades across it, and the scope
    /// cue lands it at the top.
    var sidebarListIdentity: String {
        switch self {
        case .local: "local"
        case let .remote(hostID): "remote:\(hostID)"
        case let .localWorkspace(home, _): "workspace:\(home)"
        }
    }
}

extension SidebarTreeRow {
    /// The blocks whose drop shells this row extends, outermost first: the
    /// top-level project's block (a top-level group has none), then every
    /// enclosing group or worktree, a header's own included.
    var shellOwners: [SidebarSessionDragController.ShellOwner] {
        let projectBlock: [SidebarSessionDragController.ShellOwner] =
            folderChain.first == topLevelProjectID ? [] : [.project(topLevelProjectID)]
        return projectBlock + folderChain.map { .group($0) }
    }

    /// The node whose list holds a Session or a placeholder row: its
    /// innermost group, or the top-level project. Every child folder is a
    /// wash-bearing group or worktree, so it is always in the chain.
    var listOwnerID: String {
        folderChain.last ?? topLevelProjectID
    }
}

/// Which rows an expansion just revealed. They take the expand transition
/// (`sessionRowExpand`: fade, offset and scale plus the stagger); a row
/// inserted any other way, a new Session for one, keeps the plain stagger.
/// Read while the list body runs and never observed: it compares the
/// expanded set with the previous body's in the same Host scope (a scope
/// switch swaps in a fresh list and is never an expansion), and forgets a
/// change one main-queue turn later.
@MainActor
final class SidebarTreeExpansionTracker {
    struct Motion {
        static let none = Motion(revealedFolderIDs: [], isExpansionChange: false)

        let revealedFolderIDs: Set<String>
        let isExpansionChange: Bool

        func reveals(_ row: SidebarTreeRow) -> Bool {
            guard !revealedFolderIDs.isEmpty else { return false }
            return revealedFolderIDs.contains(row.topLevelProjectID)
                || row.folderChain.contains(where: revealedFolderIDs.contains)
        }

        /// A Session or folder header's insertion: the expand transition
        /// when an expansion revealed it, the plain stagger otherwise.
        func transition(for row: SidebarTreeRow) -> AnyTransition {
            reveals(row)
                ? .sessionRowExpand(index: row.staggerIndex)
                : .sessionRowStagger(index: row.staggerIndex)
        }

        /// The placeholder: no stagger of its own outside an expansion,
        /// and the same 140 ms fade out as every row.
        func placeholderTransition(for row: SidebarTreeRow) -> AnyTransition {
            if reveals(row) { return .sessionRowExpand(index: row.staggerIndex) }
            return .asymmetric(
                insertion: .opacity,
                removal: .opacity.animation(.easeOut(duration: 0.14))
            )
        }

        /// The list-wide glide. An expansion change moves the rows below
        /// with its accordion curve, the way a toggle or a spring-open
        /// animates it, even mid-drag (a spring-open under Reduce Motion
        /// does not animate). Anything else glides, except while a
        /// just-landed drag suppresses it: the drop applies its reorder in
        /// an animation-disabled transaction, and a value-keyed animation
        /// would override that and replay the swap as a bounce.
        func glide(suppressed: Bool) -> Animation? {
            if isExpansionChange, !(suppressed && SidebarMotion.reduceMotion) {
                return revealedFolderIDs.isEmpty
                    ? SidebarMotion.accordionClose
                    : SidebarMotion.accordionOpen
            }
            return suppressed ? nil : SidebarMotion.accordionOpen
        }
    }

    private var last: (scope: String, expanded: Set<String>)?
    private var current = Motion.none
    private var generation = 0

    func motion(expanded: Set<String>, scope: String) -> Motion {
        defer { last = (scope, expanded) }
        guard let last, last.scope == scope else {
            current = .none
            return current
        }
        guard last.expanded != expanded else { return current }
        current = Motion(
            revealedFolderIDs: expanded.subtracting(last.expanded),
            isExpansionChange: true
        )
        generation &+= 1
        let settled = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == settled else { return }
            self.current = .none
        }
        return current
    }
}

/// The live PROJECTS list: the store's cached row list in one
/// `LazyVStack(spacing: 0)`. This view is the list's only store observer.
/// It resolves every display input when it builds a row (unread, rollups,
/// confirm and edit state, menus, shortcut hints, pane items), so rows stay
/// `.equatable()` values and no row observes the store itself.
struct SidebarLiveTreeList: View {
    @ObservedObject var store: UnpeelStore
    /// Plain reference, never observed: each row's drag visuals live in its
    /// own small observing leaf (`SidebarTreeRowDragEffects`).
    let dragState: SidebarDragState

    @State private var washStates = SidebarGroupWashStates()
    @State private var expansion = SidebarTreeExpansionTracker()

    var body: some View {
        let rows = store.sidebarTreeRows
        let scope = store.selectedHostScope.sidebarListIdentity
        let motion = expansion.motion(expanded: store.expandedProjectIDs, scope: scope)
        let inputs = SidebarLiveRowInputs(store: store)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                rowContainer(row, inputs: inputs, motion: motion)
            }
        }
        // A Session keeps its row id across live → stopped and pinned ↔
        // regular, so a change anywhere glides every row below it.
        .animation(motion.glide(suppressed: dragState.listGlideSuppressed), value: rows.map(\.id))
        // Pane-group hiding: closing a group fades its members back into
        // their own spots. The animation lives HERE, not on the store
        // mutation, so the Metal terminal does not inherit a fade.
        .animation(.easeOut(duration: 0.28), value: store.activePaneMemberSessionIDs)
        .id(scope)
        .onAppear { washStates.bind(to: store) }
        .onChange(of: rows) { _ in washStates.refreshSelection() }
    }

    @ViewBuilder
    private func rowContainer(
        _ row: SidebarTreeRow,
        inputs: SidebarLiveRowInputs,
        motion: SidebarTreeExpansionTracker.Motion
    ) -> some View {
        switch row.content {
        case let .projectHeader(node, isExpanded):
            SidebarLiveProjectHeaderRow(
                row: row,
                rowView: headerRowView(node, row: row, isExpanded: isExpanded, inputs: inputs),
                store: store,
                dragState: dragState,
                washStates: washStates
            )
        case let .folderHeader(node, isExpanded):
            SidebarLiveFolderHeaderRow(
                row: row,
                node: node,
                rowView: headerRowView(node, row: row, isExpanded: isExpanded, inputs: inputs),
                isPinnedGroup: store.isGroupPinned(node.id),
                transition: motion.transition(for: row),
                store: store,
                dragState: dragState,
                washStates: washStates
            )
        case let .session(entry):
            SidebarLiveSessionRow(
                row: row,
                sessionID: entry.id,
                rowView: sessionRowView(entry, ownerID: row.listOwnerID, depth: row.depth),
                // A date-sorted group has no manual order to write, but a
                // LOCAL Session there still lifts, so it can be dragged out
                // (a committed reorder flips the group to custom order).
                isDraggable: !store.isDateSorted(projectID: row.listOwnerID)
                    || store.canLiftSessionFromDateSortedList(entry.id),
                transition: motion.transition(for: row),
                store: store,
                dragState: dragState,
                washStates: washStates
            )
        case let .emptyPlaceholder(owner):
            SidebarLivePlaceholderRow(
                row: row,
                ownerID: owner.id,
                rowView: placeholderRowView(owner, depth: row.depth, inputs: inputs),
                transition: motion.placeholderTransition(for: row),
                dragState: dragState,
                washStates: washStates
            )
        }
    }

    /// Whole-row click toggles expansion (ProjectItem.svelte:654-659);
    /// open 340ms cubic-bezier(0.16,1,0.3,1), close 240ms cubicInOut.
    func toggleExpansion(_ nodeID: String) {
        let opening = !store.expandedProjectIDs.contains(nodeID)
        withAnimation(opening ? SidebarMotion.accordionOpen : SidebarMotion.accordionClose) {
            store.toggleProjectExpanded(nodeID)
        }
    }
}

/// The per-build inputs every row of one list body shares, resolved once
/// per body instead of once per row.
struct SidebarLiveRowInputs {
    /// Reads the workspace registry's modification stamp; only top-level
    /// project menus consume it.
    let workspaceMoveTargets: [WorkspaceMoveTarget]
    let quickGroups: [QuickPresetGroup]
    let menuPresets: [Preset]
    /// The pure-`.local` gate: native preset management (Settings ▸ Agents
    /// edits THIS instance's home).
    let isLocalScope: Bool
    /// The verbs valid against a scoped local workspace on this Mac too:
    /// organization (folder color, sort, groups, rename), filesystem
    /// (Reveal/Open in editor) and Remove/Add. A true remote Host scope
    /// hides all of them.
    let isLocalMachine: Bool
    let worktreesEnabled: Bool

    @MainActor
    init(store: UnpeelStore) {
        isLocalScope = store.selectedHostScope == .local
        isLocalMachine = store.selectedHostScope.isLocalMachine
        worktreesEnabled = store.isExperimentalEnabled(.worktrees)
        workspaceMoveTargets = isLocalMachine ? store.localWorkspaceMoveTargets() : []
        quickGroups = store.displayQuickPresetGroups
        menuPresets = store.displayAvailablePresets
    }
}

// MARK: - Row containers

extension View {
    /// The row's drag visuals and wash, and its hover for the group wash.
    fileprivate func sidebarLiveRowChrome(
        _ row: SidebarTreeRow,
        item: SidebarTreeRowDragItem?,
        dragState: SidebarDragState,
        washStates: SidebarGroupWashStates
    ) -> some View {
        modifier(SidebarTreeRowDragEffects(
            dragState: dragState,
            row: row,
            item: item,
            washStates: washStates
        ))
        .sidebarGroupHover(row, states: washStates)
    }

    /// Finder folder drops on a row still mean "add project"; project and
    /// Session reorders never arrive as system drops (the detached drag
    /// controller handles them).
    fileprivate func sidebarFinderFolderDrop(
        store: UnpeelStore,
        dragState: SidebarDragState
    ) -> some View {
        onDrop(of: [.fileURL], delegate: SidebarReorderDropDelegate(
            isReorderActive: { false },
            moveOver: { false },
            finishReorder: {},
            setFolderHover: { [weak dragState] hovering in
                hovering ? dragState?.folderHoverEnter() : dragState?.folderHoverExit()
            },
            addFolders: { [weak store, weak dragState] providers in
                dragState?.folderHoverReset()
                return store?.addProjectFolders(from: providers) ?? false
            }
        ))
    }
}

/// A top-level project (or top-level group) header: the only project-drag
/// source, reordering among projects.
struct SidebarLiveProjectHeaderRow: View {
    let row: SidebarTreeRow
    let rowView: ProjectRowView
    let store: UnpeelStore
    let dragState: SidebarDragState
    let washStates: SidebarGroupWashStates

    var body: some View {
        rowView.equatable()
            .sidebarLiveRowChrome(row, item: nil, dragState: dragState, washStates: washStates)
            // Group/root move target for the detached Session drag: the
            // controller hit-tests this frame and gates the highlight and
            // the drop through `UnpeelStore.canMoveSession`.
            .sidebarDragRowFrame(id: row.topLevelProjectID, kind: .project, owners: row.shellOwners)
            .sidebarFinderFolderDrop(store: store, dragState: dragState)
            // The 1 pt between projects, outside the registered frame, the
            // hover area and the wash: the pointer hits nothing there, and
            // the retained project drop target bridges it.
            .padding(.top, row.hasBlockGapAbove ? SidebarListPageMetrics.blockSpacing : 0)
    }
}

/// A child group or worktree header. It interleaves with Sessions through
/// the same detached drag.
struct SidebarLiveFolderHeaderRow: View {
    let row: SidebarTreeRow
    let node: ProjectNode
    let rowView: ProjectRowView
    let isPinnedGroup: Bool
    let transition: AnyTransition
    let store: UnpeelStore
    let dragState: SidebarDragState
    let washStates: SidebarGroupWashStates

    private var parentID: String {
        node.project.parentProjectID ?? row.topLevelProjectID
    }

    var body: some View {
        rowView.equatable()
            .sidebarLiveRowChrome(
                row,
                item: SidebarTreeRowDragItem(id: node.id, listOwnerID: parentID),
                dragState: dragState,
                washStates: washStates
            )
            .sidebarDragRowFrame(
                id: node.id,
                kind: .folderItem(parentID: parentID, pinned: isPinnedGroup, depth: row.depth),
                owners: row.shellOwners
            )
            .sidebarFinderFolderDrop(store: store, dragState: dragState)
            .transition(transition)
    }
}

/// A Session row. Rename and inline remove-confirm must NOT drop it from the
/// drag-frame registry: swapping the reporter off and back remounts the row
/// (the title editor blinks, focus loss can commit at once), and
/// `onGeometryChange` can skip a re-report when the replacement lands on the
/// same frame. The controller refuses to arm a press while those modes own
/// the pointer instead.
struct SidebarLiveSessionRow: View {
    let row: SidebarTreeRow
    let sessionID: String
    let rowView: SessionRowView
    let isDraggable: Bool
    let transition: AnyTransition
    let store: UnpeelStore
    let dragState: SidebarDragState
    let washStates: SidebarGroupWashStates

    var body: some View {
        let framed = rowView.equatable()
            .background {
                // The scroll target is the row grown by `margin` on both
                // ends, so a minimal scroll stops with the row clear of the
                // fades. The id sits on the un-padded Color.clear.
                Color.clear
                    .id(SessionScrollTarget.id(sessionID))
                    .padding(.vertical, -SessionScrollTarget.margin)
            }
            .sidebarLiveRowChrome(
                row,
                // A row that may not lift (date-sorted or remote) still
                // draws its wash and rides its folder's shift, but has no
                // drag slot of its own.
                item: isDraggable
                    ? SidebarTreeRowDragItem(id: sessionID, listOwnerID: row.listOwnerID)
                    : nil,
                dragState: dragState,
                washStates: washStates
            )
            // The registry the detached drag hit-tests. A row that cannot
            // lift still reports its geometry, so selection on mouse-down
            // feels the same in date-sorted and remote lists.
            .sidebarDragRowFrame(
                id: sessionID,
                kind: .session(projectID: row.listOwnerID, pinned: row.isPinned, depth: row.depth),
                owners: row.shellOwners,
                isDraggable: isDraggable
            )
        Group {
            if isDraggable {
                framed.sidebarFinderFolderDrop(store: store, dragState: dragState)
            } else {
                framed
            }
        }
        .transition(transition)
    }
}

/// "No sessions yet." / "No active sessions." under an expanded group or
/// project with nothing to list. Shell-only: a drop on it files into its
/// owner, never onto the row itself.
struct SidebarLivePlaceholderRow: View {
    let row: SidebarTreeRow
    let ownerID: String
    let rowView: EmptySessionsPlaceholderRow
    let transition: AnyTransition
    let dragState: SidebarDragState
    let washStates: SidebarGroupWashStates

    var body: some View {
        rowView
            .sidebarLiveRowChrome(row, item: nil, dragState: dragState, washStates: washStates)
            .sidebarDragShellFrame(id: "empty:\(ownerID)", owners: row.shellOwners)
            .transition(transition)
    }
}
