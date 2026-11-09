// Fork-only file (ADR 0009, #41): PROJECTS as one flat list of rows.

import SwiftUI

/// The group/worktree wash, shared by both carousel pages' per-row slices so
/// the two can never disagree on its look.
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

/// The two washes a group draws as per-row slices: its hover/selection
/// wash, and the "files into this group" wash while an accepted Session
/// drag hovers it (#45): a 9 pt radius, no trailing overhang, the full
/// hover fill.
struct SidebarWashStyle {
    let cornerRadius: CGFloat
    let trailingOverhang: CGFloat
    let litFill: Color
    let animation: Animation

    static let group = SidebarWashStyle(
        cornerRadius: SidebarGroupWash.cornerRadius,
        trailingOverhang: SidebarGroupWash.trailingOverhang,
        litFill: SidebarGroupWash.fill(isHighlighted: true),
        animation: SidebarGroupWash.animation
    )
    static let dropTarget = SidebarWashStyle(
        cornerRadius: 9,
        trailingOverhang: 0,
        litFill: Theme.hoverRow,
        animation: .easeInOut(duration: 0.12)
    )

    func fill(isHighlighted: Bool) -> Color {
        isHighlighted ? litFill : .clear
    }
}

/// One row's slice of a group wash. A slice that does not round an edge
/// draws its rounded rectangle past that edge and clips it at the row, so
/// stacked slices read as one continuous rounded shape with the exact
/// corners of a whole-cluster wash.
struct SidebarGroupWashSliceView: View {
    let slice: SidebarWashSlice
    let isHighlighted: Bool
    var style: SidebarWashStyle = .group

    var body: some View {
        // Far enough past a straight edge that the clipped-off corner is
        // fully outside the row, and the rectangle is tall enough for its
        // corners to keep their full continuous curve.
        let straightEdgeOverhang = style.cornerRadius * 2
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            .fill(style.fill(isHighlighted: isHighlighted))
            .padding(.top, slice.roundsTop ? 0 : -straightEdgeOverhang)
            .padding(.bottom, slice.roundsBottom ? 0 : -straightEdgeOverhang)
            .padding(.trailing, -style.trailingOverhang)
            .clipShape(RowClip(trailingOverhang: style.trailingOverhang))
            .animation(style.animation, value: isHighlighted)
            // A clip limits what's drawn, not what's hit: the overhang would
            // sit over the row above and swallow its clicks. A later row in
            // the stack is on top, so a group's first row covered its header.
            .allowsHitTesting(false)
    }

    /// The row's own frame, widened by the wash's trailing overhang.
    private struct RowClip: Shape {
        let trailingOverhang: CGFloat

        func path(in rect: CGRect) -> Path {
            Path(CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width + trailingOverhang,
                height: rect.height
            ))
        }
    }
}

extension View {
    /// Draws a row's group wash behind it, the outermost group furthest back,
    /// so nested groups' washes stack. Both carousel pages stack it here; each
    /// supplies the slice, with the level in the row's `folderChain`.
    func sidebarGroupWash<Slice: View>(
        _ slices: [SidebarWashSlice],
        @ViewBuilder slice: @escaping (_ level: Int, _ slice: SidebarWashSlice) -> Slice
    ) -> some View {
        background {
            ZStack {
                ForEach(Array(slices.enumerated()), id: \.element.folderID) { level, item in
                    slice(level, item)
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
        func ownBusy(_ n: ProjectNode) -> Bool {
            n.sessions.contains { $0.status == .starting || $0.status == .busy }
        }
        func busy(_ n: ProjectNode) -> Bool {
            ownBusy(n) || n.worktrees.contains(where: busy)
        }
        let hasAttention = attention(node)
        let busyNow = ownBusy(node)
            || (!isExpanded && node.worktrees.contains(where: busy))
        showsAttentionDot = !isExpanded && hasAttention
        showsUnreadDot = !isExpanded && unread(node)
        showsBusyShimmer = !hasAttention && busyNow
    }
}

/// Fork-only (#57): the branch mark the live page wears beside the project that
/// holds the selection.
struct SidebarActiveBranch: Equatable {
    let projectID: String
    let name: String
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
    // Fork-only (#57)
    let activeBranch: SidebarActiveBranch?
}

/// A pooled page's row: the REAL row component with inert inputs, in the row
/// container both pages share, with no interaction layer. No callbacks, no
/// drag, and the carousel never hit-tests the page.
struct SidebarPooledTreeRow: View {
    let row: SidebarTreeRow
    let inputs: SidebarPooledRowInputs

    var body: some View {
        switch row.content {
        case .projectHeader(let node, let isExpanded):
            SidebarProjectHeaderRow(
                row: row,
                rowView: folderHeader(node, isExpanded: isExpanded),
                highlightedFolderIDs: inputs.highlightedFolderIDs
            )
        case .folderHeader(let node, let isExpanded):
            SidebarFolderHeaderRow(
                row: row,
                node: node,
                rowView: folderHeader(node, isExpanded: isExpanded),
                highlightedFolderIDs: inputs.highlightedFolderIDs
            )
        case .session(let entry):
            SidebarSessionRow(
                row: row,
                sessionID: entry.id,
                rowView: SessionRowView(
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
                ),
                highlightedFolderIDs: inputs.highlightedFolderIDs
            )
        case .emptyPlaceholder(let owner):
            SidebarPlaceholderRow(
                row: row,
                ownerID: owner.id,
                // The REAL component with inert inputs, so the label's
                // Menu-chrome metrics are identical to the live sidebar and the
                // snap cannot restyle it.
                rowView: EmptySessionsPlaceholderRow(
                    label: EmptySessionsPlaceholderRow.label(for: owner),
                    depth: row.depth,
                    menuPresets: [],
                    onLaunch: { _ in },
                    showsManagePresets: false
                ),
                highlightedFolderIDs: inputs.highlightedFolderIDs
            )
        }
    }

    private func folderHeader(_ node: ProjectNode, isExpanded: Bool) -> ProjectRowView {
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
            pooledBranch: inputs.activeBranch?.projectID == node.id ? inputs.activeBranch?.name : nil,
            onToggle: {},
            onLaunchPreset: { _ in },
            isPinned: node.project.acceptsSessionDrop && node.project.pinnedAt != nil
        )
    }
}
