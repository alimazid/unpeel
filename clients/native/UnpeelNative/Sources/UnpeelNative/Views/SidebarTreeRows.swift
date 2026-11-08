// Fork-only file (ADR 0009, #41).

import Foundation

// PROJECTS as one flat list of rows (ADR 0009, #41). A lazy stack whose
// children hold lazy stacks is the shape every sidebar hang in #39 shares,
// so the tree renders as ONE list of rows instead. Everything that used to
// belong to a project block or a group cluster is rebuilt per row from the
// row's ancestry, which this file computes.

extension ProjectNode {
    /// A group or worktree: the inline child-folder row with a leading
    /// disclosure chevron and the hover/selection wash behind its whole
    /// cluster (header plus rows).
    var isSidebarInlineFolder: Bool {
        project.isFolder == true
            || project.parentProjectID != nil
            || project.worktreeBranch != nil
    }
}

/// One row of the PROJECTS tree. Structure plus model values only: display
/// state (selection, unread, collapsed rollups, menus, edit state) is
/// resolved by the page that renders the row, never stored here.
struct SidebarTreeRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case projectHeader
        case folderHeader
        case session
        case emptyPlaceholder
    }

    enum Content: Equatable {
        /// A top-level project header.
        case projectHeader(ProjectNode, isExpanded: Bool)
        /// A child folder header: a group or a worktree.
        case folderHeader(ProjectNode, isExpanded: Bool)
        case session(SessionEntry)
        /// "No sessions yet." / "No active sessions." under an expanded
        /// `owner` with nothing to list.
        case emptyPlaceholder(owner: ProjectNode)

        /// One id space for both carousel pages. A Session keeps its id
        /// across pinned and regular and across live and stopped, so moves
        /// glide.
        var rowID: String {
            switch self {
            case .projectHeader(let node, _), .folderHeader(let node, _):
                return "folder:\(node.id)"
            case .session(let entry):
                return "session:\(entry.id)"
            case .emptyPlaceholder(let owner):
                return "empty:\(owner.id)"
            }
        }

        var kind: Kind {
            switch self {
            case .projectHeader: return .projectHeader
            case .folderHeader: return .folderHeader
            case .session: return .session
            case .emptyPlaceholder: return .emptyPlaceholder
            }
        }

        /// The node a header row shows; nil for other rows.
        var headerNode: ProjectNode? {
            switch self {
            case .projectHeader(let node, _), .folderHeader(let node, _):
                return node
            case .session, .emptyPlaceholder:
                return nil
            }
        }

        var isExpanded: Bool {
            switch self {
            case .projectHeader(_, let isExpanded), .folderHeader(_, let isExpanded):
                return isExpanded
            case .session, .emptyPlaceholder:
                return false
            }
        }
    }

    let content: Content
    let depth: Int
    let topLevelProjectID: String
    /// The wash-bearing folders (groups and worktrees) whose cluster holds
    /// this row, outermost first. A folder header belongs to its own
    /// cluster, so its own id comes last.
    let folderChain: [String]
    /// The row sits in the pinned partition of the list that holds it.
    let isPinned: Bool
    /// Expand stagger position. Restarts per parent list: a pinned item's
    /// index, then the pinned count plus a regular item's index.
    let staggerIndex: Int
    let isFirstOfBlock: Bool
    let isLastOfBlock: Bool
    /// True on every top-level header but the first: the 1 pt between
    /// projects sits above it.
    let hasBlockGapAbove: Bool
    /// How many of `folderChain`'s innermost clusters end at this row.
    let closedFolderCount: Int

    var id: String { content.rowID }
    var kind: Kind { content.kind }

    /// The group wash this row draws behind itself: one slice per
    /// wash-bearing ancestor, outermost first. A cluster's header rounds the
    /// top of its own slice, and the cluster's last row rounds the bottom.
    var washSlices: [SidebarWashSlice] {
        let ownHeaderID = content.headerNode?.id
        let firstClosed = folderChain.count - closedFolderCount
        return folderChain.enumerated().map { index, folderID in
            SidebarWashSlice(
                folderID: folderID,
                roundsTop: index == folderChain.count - 1 && folderID == ownHeaderID,
                roundsBottom: index >= firstClosed
            )
        }
    }
}

/// One row's share of a group's wash.
struct SidebarWashSlice: Equatable {
    let folderID: String
    let roundsTop: Bool
    let roundsBottom: Bool
}

/// THE function that turns a project tree into its flat row list. Both
/// carousel pages call it, so the pages cannot drift apart.
enum SidebarTreeFlattener {
    /// Rows in the live sessionList's order: for each expanded node, the
    /// pinned partition (`pinnedItems`), then the regular mixed Sessions and
    /// child folders (`regularItems`), recursing into expanded folders, then
    /// the placeholder when both lists are empty. Hidden pane members leave
    /// the list without spending the budget. `budget` caps the row count;
    /// nil lists everything. A list the budget cuts short reads as
    /// continuing past its last row: no block or group cluster ends there.
    static func rows(
        topLevelNodes: [ProjectNode],
        expandedProjectIDs: Set<String>,
        hiddenSessionIDs: Set<String>,
        pinnedItems: (ProjectNode) -> [SidebarMixedItem],
        regularItems: (ProjectNode) -> [SidebarMixedItem],
        budget: Int? = nil
    ) -> [SidebarTreeRow] {
        // The builder stores the item sources for its recursion; they never
        // outlive this call.
        withoutActuallyEscaping(pinnedItems) { pinnedItems in
            withoutActuallyEscaping(regularItems) { regularItems in
                var builder = Builder(
                    expandedProjectIDs: expandedProjectIDs,
                    hiddenSessionIDs: hiddenSessionIDs,
                    pinnedItems: pinnedItems,
                    regularItems: regularItems,
                    budget: budget ?? .max
                )
                for (blockIndex, node) in topLevelNodes.enumerated() {
                    guard !builder.stopsForBudget() else { break }
                    builder.appendBlock(node, isFirstBlock: blockIndex == 0)
                }
                return builder.finishedRows()
            }
        }
    }

    /// The wash-bearing folders whose subtree holds `sessionID`, outermost
    /// first. Pass the pane representative the sidebar selects (the live
    /// group wash reads `sessionSelection`, which holds the representative).
    static func washedFolderIDs(
        containing sessionID: String?,
        in nodes: [ProjectNode]
    ) -> [String] {
        guard let sessionID else { return [] }
        for node in nodes where node.containsSidebarSession(sessionID) {
            let inner = washedFolderIDs(containing: sessionID, in: node.worktrees)
            return node.isSidebarInlineFolder ? [node.id] + inner : inner
        }
        return []
    }

    /// A row before its next neighbor is known.
    private struct Draft {
        let content: SidebarTreeRow.Content
        let depth: Int
        let topLevelProjectID: String
        let folderChain: [String]
        var isPinned = false
        var staggerIndex = 0
        var hasBlockGapAbove = false
    }

    private struct Builder {
        let expandedProjectIDs: Set<String>
        let hiddenSessionIDs: Set<String>
        let pinnedItems: (ProjectNode) -> [SidebarMixedItem]
        let regularItems: (ProjectNode) -> [SidebarMixedItem]
        var budget: Int
        var drafts: [Draft] = []
        var emittedIDs: Set<String> = []
        /// The budget ran out with rows still to list.
        var isTruncated = false

        /// True once the budget is spent; anything still to list is cut.
        mutating func stopsForBudget() -> Bool {
            guard budget <= 0 else { return false }
            isTruncated = true
            return true
        }

        mutating func appendBlock(_ node: ProjectNode, isFirstBlock: Bool) {
            let isExpanded = expandedProjectIDs.contains(node.id)
            let chain = node.isSidebarInlineFolder ? [node.id] : []
            let header = Draft(
                content: .projectHeader(node, isExpanded: isExpanded),
                depth: 0,
                topLevelProjectID: node.id,
                folderChain: chain,
                hasBlockGapAbove: !isFirstBlock
            )
            guard emit(header), isExpanded else { return }
            appendList(of: node, depth: 0, topLevelProjectID: node.id, folderChain: chain)
        }

        /// One expanded node's list.
        private mutating func appendList(
            of node: ProjectNode,
            depth: Int,
            topLevelProjectID: String,
            folderChain: [String]
        ) {
            let pinned = pinnedItems(node)
            let regular = regularItems(node)
            let sections = [
                (items: pinned, isPinned: true, staggerBase: 0),
                (items: regular, isPinned: false, staggerBase: pinned.count),
            ]
            for section in sections {
                for (index, item) in section.items.enumerated() {
                    guard !stopsForBudget() else { return }
                    appendItem(
                        item,
                        depth: depth,
                        topLevelProjectID: topLevelProjectID,
                        folderChain: folderChain,
                        isPinned: section.isPinned,
                        staggerIndex: section.staggerBase + index
                    )
                }
            }
            guard pinned.isEmpty, regular.isEmpty else { return }
            emit(Draft(
                content: .emptyPlaceholder(owner: node),
                depth: depth,
                topLevelProjectID: topLevelProjectID,
                folderChain: folderChain
            ))
        }

        private mutating func appendItem(
            _ item: SidebarMixedItem,
            depth: Int,
            topLevelProjectID: String,
            folderChain: [String],
            isPinned: Bool,
            staggerIndex: Int
        ) {
            switch item {
            case .session(let entry):
                guard !hiddenSessionIDs.contains(entry.id) else { return }
                emit(Draft(
                    content: .session(entry),
                    depth: depth,
                    topLevelProjectID: topLevelProjectID,
                    folderChain: folderChain,
                    isPinned: isPinned,
                    staggerIndex: staggerIndex
                ))
            case .folder(let child):
                let isExpanded = expandedProjectIDs.contains(child.id)
                let childChain = child.isSidebarInlineFolder
                    ? folderChain + [child.id]
                    : folderChain
                let header = Draft(
                    content: .folderHeader(child, isExpanded: isExpanded),
                    depth: depth + 1,
                    topLevelProjectID: topLevelProjectID,
                    folderChain: childChain,
                    isPinned: isPinned,
                    staggerIndex: staggerIndex
                )
                guard emit(header), isExpanded else { return }
                appendList(
                    of: child,
                    depth: depth + 1,
                    topLevelProjectID: topLevelProjectID,
                    folderChain: childChain
                )
            }
        }

        /// Appends a row unless the budget is spent or its id is already
        /// listed (one ForEach must never see a Session twice). False when
        /// the row, and so its subtree, is left out.
        @discardableResult
        private mutating func emit(_ draft: Draft) -> Bool {
            guard !stopsForBudget(),
                  emittedIDs.insert(draft.content.rowID).inserted
            else { return false }
            budget -= 1
            drafts.append(draft)
            return true
        }

        /// Resolves the flags that depend on the next row: the end of a
        /// top-level block and the clusters that close at each row.
        func finishedRows() -> [SidebarTreeRow] {
            drafts.indices.map { index in
                let draft = drafts[index]
                let next = index + 1 < drafts.count ? drafts[index + 1] : nil
                let isCutAfter = next == nil && isTruncated
                let sameBlock = isCutAfter
                    || next?.topLevelProjectID == draft.topLevelProjectID
                let sharedChain: Int
                if isCutAfter {
                    sharedChain = draft.folderChain.count
                } else if sameBlock {
                    sharedChain = zip(draft.folderChain, next?.folderChain ?? [])
                        .prefix { $0 == $1 }
                        .count
                } else {
                    sharedChain = 0
                }
                return SidebarTreeRow(
                    content: draft.content,
                    depth: draft.depth,
                    topLevelProjectID: draft.topLevelProjectID,
                    folderChain: draft.folderChain,
                    isPinned: draft.isPinned,
                    staggerIndex: draft.staggerIndex,
                    isFirstOfBlock: draft.content.kind == .projectHeader,
                    isLastOfBlock: !sameBlock,
                    hasBlockGapAbove: draft.hasBlockGapAbove,
                    closedFolderCount: draft.folderChain.count - sharedChain
                )
            }
        }
    }
}
