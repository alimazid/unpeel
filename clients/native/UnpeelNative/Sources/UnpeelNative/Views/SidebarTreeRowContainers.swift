// Fork-only file (ADR 0009, #49): one row container per row kind, used by both
// carousel pages, so a padding or a wash can't drift between them. Each takes
// its row view already built: the live list resolves it from the store, the
// pooled page from a snapshot, and `SidebarRowPixelParityTests` holds those two
// to the same pixels.

import SwiftUI

/// What only the live page adds to a row: the drag visuals, the group hover,
/// the drag registry and the Finder-folder drop. The pooled page passes none,
/// so its rows have no drag, register no frames and observe nothing.
struct SidebarRowInteraction {
    let store: UnpeelStore
    let dragState: SidebarDragState
    let washStates: SidebarGroupWashStates
}

extension View {
    /// A row's clip and group wash. With an interaction layer, the drag
    /// effects leaf draws them, the per-group observers lighting the wash:
    /// they sit between the drag visuals, so a drag publish re-runs one leaf
    /// per row. With none, `highlightedFolderIDs` lights it.
    @ViewBuilder
    fileprivate func sidebarRowChrome(
        _ row: SidebarTreeRow,
        item: SidebarTreeRowDragItem? = nil,
        highlightedFolderIDs: Set<String>,
        interaction: SidebarRowInteraction?
    ) -> some View {
        if let interaction {
            modifier(SidebarTreeRowDragEffects(
                dragState: interaction.dragState,
                row: row,
                item: item,
                washStates: interaction.washStates
            ))
            .sidebarGroupHover(row, states: interaction.washStates)
        } else {
            clipped().sidebarGroupWash(row.washSlices) { _, slice in
                SidebarGroupWashSliceView(
                    slice: slice,
                    isHighlighted: highlightedFolderIDs.contains(slice.folderID)
                )
            }
        }
    }

    /// Applies a part of the live-only layer; with none the row stays as is.
    @ViewBuilder
    fileprivate func sidebarLiveLayer<Layered: View>(
        _ interaction: SidebarRowInteraction?,
        @ViewBuilder _ layer: (Self, SidebarRowInteraction) -> Layered
    ) -> some View {
        if let interaction {
            layer(self, interaction)
        } else {
            self
        }
    }

    /// Finder folder drops on a row still mean "add project"; project and
    /// Session reorders never arrive as system drops (the detached drag
    /// controller handles them).
    fileprivate func sidebarFinderFolderDrop(_ interaction: SidebarRowInteraction) -> some View {
        let store = interaction.store
        let dragState = interaction.dragState
        return onDrop(of: [.fileURL], delegate: SidebarReorderDropDelegate(
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
struct SidebarProjectHeaderRow: View {
    let row: SidebarTreeRow
    let rowView: ProjectRowView
    var highlightedFolderIDs: Set<String> = []
    var interaction: SidebarRowInteraction? = nil

    var body: some View {
        rowView.equatable()
            .sidebarRowChrome(row, highlightedFolderIDs: highlightedFolderIDs, interaction: interaction)
            .sidebarLiveLayer(interaction) { chrome, interaction in
                chrome
                    // Group/root move target for the detached Session drag: the
                    // controller hit-tests this frame and gates the highlight and
                    // the drop through `UnpeelStore.canMoveSession`.
                    .sidebarDragRowFrame(id: row.topLevelProjectID, kind: .project, owners: row.shellOwners)
                    .sidebarFinderFolderDrop(interaction)
            }
            // The 1 pt between projects, outside the registered frame, the
            // hover area and the wash: the pointer hits nothing there, and
            // the retained project drop target bridges it.
            .padding(.top, row.hasBlockGapAbove ? SidebarListPageMetrics.blockSpacing : 0)
    }
}

/// A child group or worktree header. It interleaves with Sessions through
/// the same detached drag.
struct SidebarFolderHeaderRow: View {
    let row: SidebarTreeRow
    let node: ProjectNode
    let rowView: ProjectRowView
    var highlightedFolderIDs: Set<String> = []
    var interaction: SidebarRowInteraction? = nil
    /// Read by the interaction layer only.
    var isPinnedGroup = false

    private var parentID: String {
        node.project.parentProjectID ?? row.topLevelProjectID
    }

    var body: some View {
        rowView.equatable()
            .sidebarRowChrome(
                row,
                item: SidebarTreeRowDragItem(id: node.id, listOwnerID: parentID),
                highlightedFolderIDs: highlightedFolderIDs,
                interaction: interaction
            )
            .sidebarLiveLayer(interaction) { chrome, interaction in
                chrome
                    .sidebarDragRowFrame(
                        id: node.id,
                        kind: .folderItem(parentID: parentID, pinned: isPinnedGroup, depth: row.depth),
                        owners: row.shellOwners
                    )
                    .sidebarFinderFolderDrop(interaction)
            }
    }
}

/// A Session row. Rename and inline remove-confirm must NOT drop it from the
/// drag-frame registry: swapping the reporter off and back remounts the row
/// (the title editor blinks, focus loss can commit at once), and
/// `onGeometryChange` can skip a re-report when the replacement lands on the
/// same frame. The controller refuses to arm a press while those modes own
/// the pointer instead.
struct SidebarSessionRow: View {
    let row: SidebarTreeRow
    let sessionID: String
    let rowView: SessionRowView
    var highlightedFolderIDs: Set<String> = []
    var interaction: SidebarRowInteraction? = nil
    /// Read by the interaction layer only.
    var isDraggable = false

    var body: some View {
        rowView.equatable()
            .sidebarLiveLayer(interaction) { rowView, _ in
                rowView.background {
                    // The scroll target is the row grown by `margin` on both
                    // ends, so a minimal scroll stops with the row clear of the
                    // fades. The id sits on the un-padded Color.clear.
                    Color.clear
                        .id(SessionScrollTarget.id(sessionID))
                        .padding(.vertical, -SessionScrollTarget.margin)
                }
            }
            .sidebarRowChrome(
                row,
                // A row that may not lift (date-sorted or remote) still
                // draws its wash and rides its folder's shift, but has no
                // drag slot of its own.
                item: isDraggable
                    ? SidebarTreeRowDragItem(id: sessionID, listOwnerID: row.listOwnerID)
                    : nil,
                highlightedFolderIDs: highlightedFolderIDs,
                interaction: interaction
            )
            .sidebarLiveLayer(interaction) { chrome, interaction in
                // The registry the detached drag hit-tests. A row that cannot
                // lift still reports its geometry, so selection on mouse-down
                // feels the same in date-sorted and remote lists.
                let framed = chrome.sidebarDragRowFrame(
                    id: sessionID,
                    kind: .session(projectID: row.listOwnerID, pinned: row.isPinned, depth: row.depth),
                    owners: row.shellOwners,
                    isDraggable: isDraggable
                )
                if isDraggable {
                    framed.sidebarFinderFolderDrop(interaction)
                } else {
                    framed
                }
            }
    }
}

/// "No sessions yet." / "No active sessions." under an expanded group or
/// project with nothing to list. Shell-only: a drop on it files into its
/// owner, never onto the row itself.
struct SidebarPlaceholderRow: View {
    let row: SidebarTreeRow
    let ownerID: String
    let rowView: EmptySessionsPlaceholderRow
    var highlightedFolderIDs: Set<String> = []
    var interaction: SidebarRowInteraction? = nil

    var body: some View {
        rowView
            .sidebarRowChrome(row, highlightedFolderIDs: highlightedFolderIDs, interaction: interaction)
            .sidebarLiveLayer(interaction) { chrome, _ in
                chrome.sidebarDragShellFrame(id: "empty:\(ownerID)", owners: row.shellOwners)
            }
    }
}
