// Fork-only file (ADR 0009, #45): what a live PROJECTS row draws from its
// ancestry instead of from a project block or a group cluster: the group
// wash slices with their per-group observers, and the drag visuals.

import Combine
import SwiftUI

// MARK: - Group wash highlight

/// One group's or worktree's wash highlight. Only the slices of that group
/// observe it, so a hover or selection change wakes just the slices whose
/// highlight flips (the per-id pattern of `SessionSelectionRowState`).
@MainActor
final class SidebarGroupWashState: ObservableObject {
    @Published fileprivate(set) var isHighlighted = false
}

/// The per-group wash observers of the live PROJECTS list. A group is lit
/// while the pointer is over any of its rows, or while it contains the
/// selected Session. Never drawn from registered geometry: that would feed
/// geometry back into layout, the class of bug behind #39.
@MainActor
final class SidebarGroupWashStates {
    private final class WeakState {
        weak var value: SidebarGroupWashState?

        init(_ value: SidebarGroupWashState) {
            self.value = value
        }
    }

    /// Prune dead weak entries once the map grows past this.
    private static let compactionThreshold = 1_024

    private var states: [String: WeakState] = [:]
    /// The one row under the pointer and the groups it lights. Rows are
    /// siblings in one list, so at most one is hovered at a time.
    private var hoveredRowID: String?
    private var hoveredFolderIDs: Set<String> = []
    private var selectedFolderIDs: Set<String> = []
    private weak var store: UnpeelStore?
    private var selectionSubscription: AnyCancellable?

    func state(for folderID: String) -> SidebarGroupWashState {
        if let existing = states[folderID]?.value {
            return existing
        }
        let state = SidebarGroupWashState()
        state.isHighlighted = isHighlighted(folderID)
        states[folderID] = WeakState(state)
        if states.count > Self.compactionThreshold {
            states = states.filter { $0.value.value != nil }
        }
        return state
    }

    /// Follows the store's selection. The subscription fires inside the
    /// selection change, so the wash flips in the same commit as the row's
    /// selection chip.
    func bind(to store: UnpeelStore) {
        guard self.store !== store else { return }
        self.store = store
        selectionSubscription = store.sessionSelection.$sessionID
            .sink { [weak self] sessionID in
                self?.selectFolders(containing: sessionID)
            }
    }

    /// Re-resolves the selection's groups after the tree changed under it
    /// (the selected Session moved, or its group was renamed into another).
    func refreshSelection() {
        selectFolders(containing: store?.sessionSelection.sessionID)
    }

    /// A row's hover. Entering lights the row's groups at once; leaving
    /// waits one main-queue turn, so moving between two rows of one group
    /// never dims it, whichever order the exit and the enter arrive in.
    func setHovering(_ hovering: Bool, rowID: String, folderIDs: [String]) {
        if hovering {
            hoveredRowID = rowID
            apply(hovered: Set(folderIDs), selected: selectedFolderIDs)
            return
        }
        guard hoveredRowID == rowID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hoveredRowID == rowID else { return }
            self.hoveredRowID = nil
            self.apply(hovered: [], selected: self.selectedFolderIDs)
        }
    }

    private func selectFolders(containing sessionID: String?) {
        let folders = SidebarTreeFlattener.washedFolderIDs(
            containing: sessionID,
            in: store?.displayNodes ?? []
        )
        apply(hovered: hoveredFolderIDs, selected: Set(folders))
    }

    private func isHighlighted(_ folderID: String) -> Bool {
        hoveredFolderIDs.contains(folderID) || selectedFolderIDs.contains(folderID)
    }

    private func apply(hovered: Set<String>, selected: Set<String>) {
        let touched = hoveredFolderIDs.symmetricDifference(hovered)
            .union(selectedFolderIDs.symmetricDifference(selected))
        hoveredFolderIDs = hovered
        selectedFolderIDs = selected
        for folderID in touched {
            guard let state = states[folderID]?.value else { continue }
            let lit = isHighlighted(folderID)
            if state.isHighlighted != lit { state.isHighlighted = lit }
        }
    }
}

/// One group-wash slice, lit by its group's own observer.
private struct SidebarLiveWashSlice: View {
    @ObservedObject var state: SidebarGroupWashState
    let slice: SidebarWashSlice

    var body: some View {
        SidebarGroupWashSliceView(slice: slice, isHighlighted: state.isHighlighted)
    }
}

extension View {
    /// Reports the pointer over a row that sits inside a group or worktree.
    @ViewBuilder
    func sidebarGroupHover(_ row: SidebarTreeRow, states: SidebarGroupWashStates) -> some View {
        if row.folderChain.isEmpty {
            self
        } else {
            onHover { hovering in
                states.setHovering(hovering, rowID: row.id, folderIDs: row.folderChain)
            }
        }
    }
}

// MARK: - Drag visuals

/// Who a row is to the detached drag: its own draggable item, if any.
struct SidebarTreeRowDragItem: Equatable {
    /// The registry id: a Session's or a child folder's bare id.
    let id: String
    /// The list that holds the item; insertion gaps match on it.
    let listOwnerID: String
}

/// Everything a PROJECTS row renders from drag state, in ONE observing leaf
/// per row, so a drag publish re-runs only these small bodies and never a
/// row body. The registered frame wraps this leaf: every shift is an offset
/// inside it, so hit-test geometry stays static for the whole drag.
///
/// Inner to outer:
/// - the item's own chrome: the lifted slot, the collapsed slot, the "no"
///   shake and the cross-group insertion gaps;
/// - a top-level project header's "files into this project" wash;
/// - the same-section reorder shift of the row itself or of its nearest
///   ancestor folder in the origin section. A riding folder carries its
///   own wash slices and its descendants' along; outer groups stay put;
/// - the wash slices, one drop slice and one group slice per ancestor
///   group, outermost furthest back;
/// - a lifted top-level project, and the 30 pt project-reorder gap.
struct SidebarTreeRowDragEffects: ViewModifier {
    @ObservedObject var dragState: SidebarDragState
    let row: SidebarTreeRow
    let item: SidebarTreeRowDragItem?
    let washStates: SidebarGroupWashStates

    /// A cross-group positional insert opens a row-sized gap, so the drop
    /// target reads as "the card lands here".
    static let insertionGap: CGFloat = 26
    /// The gap a project reorder opens above or below its target block.
    static let projectInsertionGap: CGFloat = 30

    func body(content: Content) -> some View {
        let ride = reorderRide
        let projectGap = projectGapSides
        content
            .modifier(ItemChrome(
                isLifted: item.map { dragState.liftedSessionRowID == $0.id } ?? false,
                isSlotCollapsed: dragState.liftedSlotCollapsed,
                shakeBeats: item.map { dragState.deniedShakeBeats[$0.id] ?? 0 } ?? 0,
                gapAbove: matchesInsertion(below: false),
                gapBelow: matchesInsertion(below: true)
            ))
            .background {
                if row.kind == .projectHeader {
                    SidebarGroupWashSliceView(
                        slice: SidebarWashSlice(folderID: row.topLevelProjectID, roundsTop: true, roundsBottom: true),
                        isHighlighted: isDropTarget(row.topLevelProjectID),
                        style: .dropTarget
                    )
                }
            }
            .offset(y: ride.offset)
            .background { washSlices(ride: ride) }
            .animation(dragState.sessionDrag == nil ? nil : Self.slot, value: ride.offset)
            // Match Session dragging: the detached card owns the visible
            // header, while its original row becomes a true empty slot.
            .opacity(isLiftedProject ? 0 : 1)
            .animation(isLiftedProject ? Self.slot : nil, value: isLiftedProject)
            .padding(.top, projectGap.above ? Self.projectInsertionGap : 0)
            .padding(.bottom, projectGap.below ? Self.projectInsertionGap : 0)
            .animation(Self.slot, value: projectGap)
    }

    /// The drag's slot spring, or none under Reduce Motion.
    fileprivate static var slot: Animation? {
        SidebarMotion.reduceMotion ? nil : SidebarSessionDragController.slotAnimation
    }

    /// The same-section reorder shift a row takes, and the first level of
    /// its `folderChain` (and so of its `washSlices`, one per level) that
    /// rides with it; levels above stay put.
    private struct ReorderRide {
        let offset: CGFloat
        let fromLevel: Int
    }

    /// The frozen map holds one section's items, so at most one of the
    /// row's own id and its ancestor folders is in it.
    private var reorderRide: ReorderRide {
        let chain = row.folderChain
        let still = ReorderRide(offset: 0, fromLevel: chain.count)
        guard let drag = dragState.sessionDrag else { return still }
        if row.kind == .session, let item {
            let shift = dragState.reorderShift(for: item.id, inProject: drag.projectID)
            if shift != 0 { return ReorderRide(offset: shift, fromLevel: chain.count) }
        }
        for level in chain.indices.reversed() {
            let shift = dragState.reorderShift(for: chain[level], inProject: drag.projectID)
            if shift != 0 { return ReorderRide(offset: shift, fromLevel: level) }
        }
        return still
    }

    private func washSlices(ride: ReorderRide) -> some View {
        ZStack {
            ForEach(Array(row.washSlices.enumerated()), id: \.element.folderID) { level, slice in
                ZStack {
                    SidebarGroupWashSliceView(
                        slice: slice,
                        isHighlighted: isDropTarget(slice.folderID),
                        style: .dropTarget
                    )
                    SidebarLiveWashSlice(state: washStates.state(for: slice.folderID), slice: slice)
                }
                .offset(y: level >= ride.fromLevel ? ride.offset : 0)
            }
        }
    }

    private func isDropTarget(_ projectID: String) -> Bool {
        dragState.sessionDropTargetProjectID == projectID
    }

    /// A top-level project drag empties the header's slot; a top-level
    /// group's whole cluster goes with it.
    private var isLiftedProject: Bool {
        guard dragState.liftedProjectRowID == row.topLevelProjectID else { return false }
        return row.kind == .projectHeader || row.folderChain.first == row.topLevelProjectID
    }

    /// Above on the block's header row, below on its last row (a collapsed
    /// header is both). A top-level group has no project block, so no gap.
    private var projectGapSides: ProjectGap {
        guard let insertion = dragState.projectInsertion,
              insertion.projectID == row.topLevelProjectID,
              row.folderChain.first != row.topLevelProjectID
        else { return ProjectGap(above: false, below: false) }
        return ProjectGap(
            above: !insertion.below && row.kind == .projectHeader,
            below: insertion.below && row.isLastOfBlock
        )
    }

    private struct ProjectGap: Equatable {
        let above: Bool
        let below: Bool
    }

    private func matchesInsertion(below: Bool) -> Bool {
        guard let item, let insertion = dragState.sessionInsertion else { return false }
        return insertion.projectID == item.listOwnerID
            && insertion.anchorID == item.id
            && insertion.below == below
    }

    /// The dragged item's own slot: it stays in the list at full height
    /// (it IS the live gap the other rows part around) but dims while its
    /// content rides the floating card, and closes entirely while the card
    /// is outside the sidebar. Values only: the observing leaf above owns
    /// the subscription.
    private struct ItemChrome: ViewModifier {
        let isLifted: Bool
        let isSlotCollapsed: Bool
        let shakeBeats: Int
        let gapAbove: Bool
        let gapBelow: Bool

        func body(content: Content) -> some View {
            let isCollapsed = isLifted && isSlotCollapsed
            content
                .opacity(isLifted ? 0 : 1)
                .frame(height: isCollapsed ? 0 : nil)
                .clipped()
                // Refused-drop "no" shake (pinned Sessions/groups). The
                // beat only ever grows, and only for this row.
                .modifier(SidebarDeniedShakeEffect(progress: CGFloat(shakeBeats)))
                .padding(.top, gapAbove ? SidebarTreeRowDragEffects.insertionGap : 0)
                .padding(.bottom, gapBelow ? SidebarTreeRowDragEffects.insertionGap : 0)
                .animation(SidebarTreeRowDragEffects.slot, value: isCollapsed)
                // Hide animates (the row dissolves under the lifting card);
                // reveal is INSTANT: it fires in the same beat the landed
                // card window closes, with the card exactly over the slot.
                .animation(isLifted ? SidebarTreeRowDragEffects.slot : nil, value: isLifted)
                .animation(SidebarTreeRowDragEffects.slot, value: gapAbove)
                .animation(SidebarTreeRowDragEffects.slot, value: gapBelow)
        }
    }
}
