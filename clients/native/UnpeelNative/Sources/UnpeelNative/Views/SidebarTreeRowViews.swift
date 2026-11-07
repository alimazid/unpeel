import SwiftUI

/// The group/worktree wash, shared by the live tree's cluster background and
/// the flat list's per-row slices so the two can never disagree on its look.
enum SidebarGroupWash {
    static let cornerRadius: CGFloat = 10
    /// Child-group layout is already inset by its parent list. The wash
    /// reaches this far past the row's trailing edge, back toward the
    /// Session-row bounds.
    static let trailingOverhang: CGFloat = 1
    static let animation: Animation = .easeOut(duration: 0.12)

    static func fill(isHighlighted: Bool) -> Color {
        isHighlighted ? Theme.hoverRow.opacity(0.5) : .clear
    }
}

/// One row's slice of a group wash. A slice that does not round an edge
/// draws its rounded rectangle past that edge and clips it at the row, so
/// stacked slices read as the one continuous rounded shape the live cluster
/// draws, with today's exact corners.
struct SidebarGroupWashSliceView: View {
    let slice: SidebarWashSlice
    let isHighlighted: Bool

    /// Far enough past a straight edge that the clipped-off corner is fully
    /// outside the row, and the rectangle is tall enough for its corners to
    /// keep their full continuous curve.
    private static let straightEdgeOverhang = SidebarGroupWash.cornerRadius * 2

    var body: some View {
        RoundedRectangle(cornerRadius: SidebarGroupWash.cornerRadius, style: .continuous)
            .fill(SidebarGroupWash.fill(isHighlighted: isHighlighted))
            .padding(.top, slice.roundsTop ? 0 : -Self.straightEdgeOverhang)
            .padding(.bottom, slice.roundsBottom ? 0 : -Self.straightEdgeOverhang)
            .padding(.trailing, -SidebarGroupWash.trailingOverhang)
            .clipShape(RowClip())
            .animation(SidebarGroupWash.animation, value: isHighlighted)
    }

    /// The row's own frame, widened by the wash's trailing overhang.
    private struct RowClip: Shape {
        func path(in rect: CGRect) -> Path {
            Path(CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width + SidebarGroupWash.trailingOverhang,
                height: rect.height
            ))
        }
    }
}

extension View {
    /// Draws a row's group wash slices behind it, the outermost group
    /// furthest back, as nested cluster backgrounds stack today.
    func sidebarGroupWash(
        _ slices: [SidebarWashSlice],
        isHighlighted: @escaping (String) -> Bool
    ) -> some View {
        background {
            ZStack {
                ForEach(slices, id: \.folderID) { slice in
                    SidebarGroupWashSliceView(
                        slice: slice,
                        isHighlighted: isHighlighted(slice.folderID)
                    )
                }
            }
        }
    }
}

/// A folder header's collapsed-state marks, rolled up over its subtree:
/// attention outranks unread on the folder mark, both only while collapsed;
/// the busy shimmer covers the folder's own Sessions always and its child
/// folders while collapsed, and attention suppresses it.
struct SidebarFolderRollup: Equatable {
    let showsAttentionDot: Bool
    let showsUnreadDot: Bool
    let showsBusyShimmer: Bool

    init(node: ProjectNode, isExpanded: Bool, isUnread: (String) -> Bool) {
        func attention(_ n: ProjectNode) -> Bool {
            n.sessions.contains { $0.status == .attention }
                || n.worktrees.contains(where: attention)
        }
        func unread(_ n: ProjectNode) -> Bool {
            n.sessions.contains { isUnread($0.id) }
                || n.worktrees.contains(where: unread)
        }
        func busy(_ n: ProjectNode) -> Bool {
            n.sessions.contains { $0.status == .starting || $0.status == .busy }
                || n.worktrees.contains(where: busy)
        }
        let hasAttention = attention(node)
        let busyNow = node.sessions.contains { $0.status == .starting || $0.status == .busy }
            || (!isExpanded && node.worktrees.contains(where: busy))
        showsAttentionDot = !isExpanded && hasAttention
        showsUnreadDot = !isExpanded && unread(node)
        showsBusyShimmer = !hasAttention && busyNow
    }
}

/// The display state a pooled carousel page paints its rows with, resolved
/// from the neighbor's snapshot (or the current instance's Local truth)
/// when the page content is built.
struct SidebarPooledRowInputs: Equatable {
    /// The pane representative of the Session the target workspace will
    /// show after the swipe lands. Painting its glass state keeps the
    /// commit swap from jumping.
    let selectedSessionID: String?
    /// Groups and worktrees whose wash the selection lights.
    let highlightedFolderIDs: Set<String>
    let unreadSessionIDs: Set<String>
    let paneItemsByRepresentative: [String: [UnpeelStore.PaneSidebarItem]]
    /// Projects whose list is date-sorted: their rows show an age.
    let dateSortedProjectIDs: Set<String>
    let folderColors: [String: ProjectFolderColor]
}

/// The pooled page's read-only row container, one composition per row
/// kind: the REAL row component with inert inputs, its group wash slices
/// and the 1 pt gap above a project. No callbacks, no drag, and the
/// carousel never hit-tests the page.
struct SidebarPooledTreeRow: View {
    let row: SidebarTreeRow
    let inputs: SidebarPooledRowInputs

    var body: some View {
        rowView
            .sidebarGroupWash(row.washSlices) { inputs.highlightedFolderIDs.contains($0) }
            // Outside the wash, as the live tree's 1 pt stack spacing is.
            .padding(.top, row.hasBlockGapAbove ? 1 : 0)
    }

    @ViewBuilder
    private var rowView: some View {
        switch row.content {
        case .projectHeader(let node, let isExpanded),
             .folderHeader(let node, let isExpanded):
            folderHeader(node, isExpanded: isExpanded)
        case .session(let entry):
            SessionRowView(
                session: entry,
                depth: row.depth,
                indentBase: 9,
                isSelected: entry.id == inputs.selectedSessionID,
                isUnread: inputs.unreadSessionIDs.contains(entry.id),
                isPinned: row.isPinned,
                canPin: false,
                canClearAttention: false,
                paneItems: inputs.paneItemsByRepresentative[entry.id] ?? [],
                ageTimestampMs: inputs.dateSortedProjectIDs.contains(entry.projectID)
                    ? max(entry.createdAt, entry.lifecycleAtMs ?? 0)
                    : nil,
                onSelect: {}
            ).equatable()
        case .emptyPlaceholder(let owner):
            // The REAL component with inert inputs, so the label's
            // Menu-chrome metrics are identical to the live sidebar and the
            // snap cannot restyle it.
            EmptySessionsPlaceholderRow(
                label: owner.sessions.isEmpty ? "No sessions yet." : "No active sessions.",
                depth: row.depth,
                menuPresets: [],
                onLaunch: { _ in },
                showsManagePresets: false
            )
        }
    }

    private func folderHeader(_ node: ProjectNode, isExpanded: Bool) -> some View {
        let rollup = SidebarFolderRollup(
            node: node,
            isExpanded: isExpanded,
            isUnread: { inputs.unreadSessionIDs.contains($0) }
        )
        return ProjectRowView(
            node: node,
            depth: row.depth,
            isExpanded: isExpanded,
            showsAttentionDot: rollup.showsAttentionDot,
            showsUnreadDot: rollup.showsUnreadDot,
            showsBusyShimmer: rollup.showsBusyShimmer,
            quickGroups: [],
            menuPresets: [],
            folderColor: inputs.folderColors[node.id],
            onToggle: {},
            onLaunchPreset: { _ in },
            isPinned: node.project.acceptsSessionDrop && node.project.pinnedAt != nil
        ).equatable()
    }
}
