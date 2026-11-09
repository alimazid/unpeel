//
//  SidebarDropShells.swift
//  UnpeelNative
//
//  Fork-only file (ADR 0009, #41).
//
//  Hit-testing over the detached drag's row-frame registry. A project's or
//  group's drop shell is never a registered frame: every row carries its
//  owner chain, and a block's shell is the union of the registered frames of
//  the mounted rows that name it, derived at hit-test time. The rules are
//  pure static functions so they can be tested without a view tree.
//

import CoreGraphics
import Foundation

extension SidebarSessionDragController {
    /// A block whose drop shell a registered row extends.
    enum ShellOwner: Hashable {
        /// A top-level project's block.
        case project(String)
        /// An inline group or worktree cluster (a top-level one included).
        case group(String)

        var shellKind: RowKind {
            switch self {
            case let .project(id): .projectShell(projectID: id)
            case let .group(id): .groupShell(projectID: id)
            }
        }

        var shellID: String {
            switch self {
            case let .project(id): "project-shell-drop:\(id)"
            case let .group(id): "group-shell-drop:\(id)"
            }
        }
    }

    struct RowRecord {
        /// Nil for a shell-only row (the empty-project placeholder): never a
        /// hit target itself, it only extends its owners' shells. Never a
        /// shell kind: shells are derived, not registered.
        let kind: RowKind?
        let frame: CGRect
        /// The blocks this row sits inside, outermost first: the top-level
        /// block, then each enclosing group down to the row's own. A group
        /// or project header names its own block too.
        let owners: [ShellOwner]
        /// Session rows also participate in immediate press selection even
        /// when their current sort/scope does not permit a detached drag.
        /// Other row kinds retain the historical draggable default.
        let isDraggable: Bool
        /// Identity of the reporter instance that registered this frame.
        /// A moved row (cross-group drop) is a NEW view for the same id:
        /// the new reporter registers before the old view's teardown runs,
        /// and an unscoped remove would delete the fresh registration —
        /// leaving the row undraggable until its list rebuilt.
        let token: UUID
    }

    /// What a content-space point resolves to: a registered row, or a
    /// project/group shell derived from the rows its block owns.
    struct RowHit: Equatable {
        let id: String
        let kind: RowKind
        let frame: CGRect
        let isDraggable: Bool
    }

    /// The top-level project block under a point during a project drag, and
    /// which half of it the point is in.
    struct ProjectBlockHit: Equatable {
        let id: String
        let below: Bool
    }

    /// The row under a point. A shell deliberately overlaps every row its
    /// block owns, so semantic rows win first and, among them, the smallest
    /// frame is the most specific target. Only a point no semantic row
    /// covers (blank wash, a placeholder) falls through to the shells, where
    /// the smallest containing one, the innermost group, wins.
    nonisolated static func row(
        at point: CGPoint,
        in rows: [String: RowRecord]
    ) -> RowHit? {
        let semantic = rows.lazy.filter { $0.value.kind != nil }
        if let hit = smallest(semantic, containing: point, frame: \.value.frame),
           let kind = hit.value.kind {
            return RowHit(
                id: hit.key, kind: kind, frame: hit.value.frame,
                isDraggable: hit.value.isDraggable
            )
        }
        let shells = shellFrames(in: rows)
        return smallest(shells, containing: point, frame: \.value)
            .map { owner, frame in
                RowHit(
                    id: owner.shellID, kind: owner.shellKind, frame: frame,
                    isDraggable: false
                )
            }
    }

    /// Top-level project containing this point. The whole block wins over
    /// its overlapping header (its midpoint gives a natural above/below
    /// insertion slot); a top-level group has no project block, so its
    /// header alone answers. This scan is intentionally independent of
    /// `row(at:in:)`: nested Session rows have higher semantic hit priority,
    /// but they must not punch holes in the containing PROJECT's reorder
    /// target geometry.
    nonisolated static func projectBlock(
        at point: CGPoint, in rows: [String: RowRecord]
    ) -> ProjectBlockHit? {
        let blocks = shellFrames(in: rows).lazy.compactMap { owner, frame -> (id: String, frame: CGRect)? in
            guard case let .project(id) = owner else { return nil }
            return (id, frame)
        }
        let headers = rows.lazy.compactMap { id, record -> (id: String, frame: CGRect)? in
            guard case .project? = record.kind else { return nil }
            return (id, record.frame)
        }
        let hit = smallest(blocks, containing: point, frame: \.frame)
            ?? smallest(headers, containing: point, frame: \.frame)
        return hit.map { ProjectBlockHit(id: $0.id, below: point.y > $0.frame.midY) }
    }

    /// Each block's shell: the union of the registered frames of the rows
    /// that name it. Only mounted rows are registered, so a block taller
    /// than the lazy window covers just its mounted part.
    ///
    /// Registered frames are static for the whole drag: every row's
    /// same-section reorder shift, a riding group's included, is an offset
    /// inside its own reporter (#45), so a shell is a plain union.
    nonisolated static func shellFrames(
        in rows: [String: RowRecord]
    ) -> [ShellOwner: CGRect] {
        rows.values.reduce(into: [:]) { frames, record in
            for owner in record.owners {
                frames[owner] = frames[owner]?.union(record.frame) ?? record.frame
            }
        }
    }

    /// The row whose slot the open reorder gap sits over, where an accepted
    /// drop's card lands. Moving up, that's the anchor's own. Moving down, the
    /// anchor rides up one slot with everything in its block, so it's the
    /// block's last mounted row.
    nonisolated static func reorderLandingRowID(
        anchorID: String,
        movingDown: Bool,
        in rows: [String: RowRecord]
    ) -> String {
        guard movingDown else { return anchorID }
        return rows
            .filter { $0.value.owners.contains(.group(anchorID)) }
            .max { $0.value.frame.maxY < $1.value.frame.maxY }?
            .key ?? anchorID
    }

    /// The candidate with the smallest frame containing `point`; the first
    /// one wins a tie.
    private nonisolated static func smallest<Candidates: Sequence>(
        _ candidates: Candidates,
        containing point: CGPoint,
        frame: (Candidates.Element) -> CGRect
    ) -> Candidates.Element? {
        candidates
            .filter { frame($0).contains(point) }
            .min { area(frame($0)) < area(frame($1)) }
    }

    private nonisolated static func area(_ frame: CGRect) -> CGFloat {
        frame.width * frame.height
    }
}

extension SidebarSessionDragController.RowKind {
    /// A project/group shell, which hit-testing derives and nothing registers.
    var isShell: Bool {
        switch self {
        case .projectShell, .groupShell: true
        case .session, .folderItem, .project: false
        }
    }
}
