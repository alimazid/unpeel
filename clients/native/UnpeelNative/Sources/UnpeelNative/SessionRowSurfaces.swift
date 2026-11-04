//
//  SessionRowSurfaces.swift
//  UnpeelNative
//
//  Fork-only: a Session has a row in PROJECTS and, while it is active,
//  finished or pinned, another in the AGENTS section. Both offer the same
//  context menu, so an inline rename or Stop/Remove confirmation records
//  the surface that started it and mounts on that row alone. Two live
//  confirmations would each run a dismiss monitor, and the first click on
//  one row's pill would cancel the other row's — under the pointer.
//

/// The session-row lists that own inline confirmations.
enum SessionRowSurface: Equatable {
    case sidebar
    case agentsSection
}

/// What one surface's row shows in place of its plain content.
enum SessionRowInlineMode: Equatable {
    case none
    case renaming
    case confirmingStop
    case confirmingRemove

    /// Confirmations outrank the rename editor, as on the PROJECTS row.
    static func resolve(
        sessionID: String,
        on surface: SessionRowSurface,
        editing: (sessionID: String, surface: UnpeelStore.SessionTitleEditorSurface)?,
        confirmingStop: String?,
        confirmingRemove: String?,
        confirmSurface: SessionRowSurface
    ) -> SessionRowInlineMode {
        if confirmSurface == surface {
            if confirmingRemove == sessionID { return .confirmingRemove }
            if confirmingStop == sessionID { return .confirmingStop }
        }
        if let editing, editing.sessionID == sessionID,
           editing.surface.rowSurface == surface {
            return .renaming
        }
        return .none
    }
}

extension UnpeelStore.SessionTitleEditorSurface {
    /// The row list whose title editor this is; the pane header has none.
    var rowSurface: SessionRowSurface? {
        switch self {
        case .sidebar: return .sidebar
        case .agentsSection: return .agentsSection
        case .paneHeader: return nil
        }
    }
}

/// Which AGENTS-owned inline states to end because their row left the
/// section (read, unpinned, workspace switch, section collapsed). PROJECTS
/// rows never disappear under an open editor, but AGENTS rows do, and a
/// state nothing renders would keep blocking the deferred projection flush.
struct AgentsSectionInlineCleanup: Equatable {
    let endsEditing: Bool
    let endsStopConfirm: Bool
    let endsRemoveConfirm: Bool

    static let none = AgentsSectionInlineCleanup(
        endsEditing: false, endsStopConfirm: false, endsRemoveConfirm: false
    )

    static func resolve(
        visibleSessionIDs: Set<String>,
        editing: (sessionID: String, surface: UnpeelStore.SessionTitleEditorSurface)?,
        confirmingStop: String?,
        confirmingRemove: String?,
        confirmSurface: SessionRowSurface
    ) -> AgentsSectionInlineCleanup {
        func gone(_ id: String?) -> Bool {
            id.map { !visibleSessionIDs.contains($0) } ?? false
        }
        let ownsConfirm = confirmSurface == .agentsSection
        return AgentsSectionInlineCleanup(
            endsEditing: editing?.surface == .agentsSection && gone(editing?.sessionID),
            endsStopConfirm: ownsConfirm && gone(confirmingStop),
            endsRemoveConfirm: ownsConfirm && gone(confirmingRemove)
        )
    }
}
