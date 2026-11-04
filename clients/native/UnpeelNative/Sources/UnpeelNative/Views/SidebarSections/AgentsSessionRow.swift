//
//  AgentsSessionRow.swift
//  UnpeelNative
//
//  Fork-only: an AGENTS section row with the PROJECTS session menu. Every
//  AGENTS row is in the current workspace, so the store's session verbs
//  apply to it as they do to the PROJECTS row. Rename and the Stop/Remove
//  confirmations happen in this row (`SessionRowSurface.agentsSection`),
//  never in the PROJECTS row of the same Session.
//

import SwiftUI

/// The store values the row's menu and inline states read. Equatable, so an
/// unchanged row skips its body and an open menu is not rebuilt under the
/// pointer (the same reason `SessionRowView` is `.equatable()`).
struct AgentsSessionRowState: Equatable {
    let session: SessionEntry
    /// The project the PROJECTS row is listed under, for Pin/Unpin.
    let projectID: String
    let inline: SessionRowInlineMode
    let isPinned: Bool
    let canPin: Bool
    let isUnread: Bool
    let canMarkUnread: Bool
    let resumePresentation: SessionRowResumePresentation
    let canClearAttention: Bool
    let canNotifyWhenDone: Bool
    let notifyWhenDone: Bool
    let showsCopyTranscript: Bool
    let canStop: Bool
    let canRestartApp: Bool
    let agentAccessRole: McpRole?
    let moveTargets: [SessionMoveTarget]
    let canMoveToProjectSidebar: Bool
    let isInProjectSidebar: Bool
    /// Remove, restart or resume in flight: the row dims and takes no
    /// input, as the PROJECTS row does.
    let isBusy: Bool

    /// Mirrors the gating `SidebarView` wires into `SessionRowView`. Nil
    /// while the Session is not in the current projection (the row then
    /// shows no menu).
    @MainActor
    init?(store: UnpeelStore, item: GlobalActivityMenuItem) {
        let id = item.session.sessionID
        guard let session = store.displaySessionsByID[id] else { return nil }
        self.session = session
        projectID = item.session.projectID
        inline = store.sessionRowInlineMode(id, on: .agentsSection)
        isPinned = store.isPinned(sessionID: id, projectID: item.session.projectID)
        canPin = store.sessionCanPin(id)
        isUnread = store.sessionIsUnread(id)
        canMarkUnread = store.sessionCanMarkUnread(id)
        resumePresentation = sessionRowResumePresentation(
            session: session,
            canRestart: store.sessionCanRestart(id),
            canResumeAgent: store.sessionCanResumeAgent(id)
        )
        canClearAttention = store.sessionCanClearAttention(id)
        canNotifyWhenDone = store.sessionCanNotifyWhenDone(id)
        notifyWhenDone = store.notifyWhenDoneSessionIDs.contains(id)
        // One row is one Session, so the transcript is never ambiguous.
        showsCopyTranscript = sessionRowShowsCopyTranscript(session: session, paneItems: [])
        canStop = store.sessionCanStop(id)
        canRestartApp = store.sessionCanRestartApp(id)
        agentAccessRole = store.canSetAgentAccess(id) ? store.agentAccessRole(for: id) : nil
        moveTargets = store.isExperimentalEnabled(.worktrees)
            ? store.moveDestinations(forSession: id)
                .map { SessionMoveTarget(id: $0.id, name: $0.name) }
            : []
        canMoveToProjectSidebar = store.canMoveSessionToProjectSidebar(id)
        isInProjectSidebar = store.sessionIsInProjectSidebar(id)
        isBusy = store.removingSessionIDs.contains(id)
            || store.restartingSessionIDs.contains(id)
            || store.resumingAgentSessionIDs.contains(id)
    }
}

/// The observing leaf: re-reads the row's store state on every store change
/// (cheap) and hands it to the equatable row, whose body — and open context
/// menu — rebuild only when that state changes.
struct AgentsSessionRowHost: View {
    @ObservedObject var store: UnpeelStore
    let item: GlobalActivityMenuItem
    let style: ActivityMenuRowStyle
    let row: AnyView

    var body: some View {
        AgentsSessionRow(
            store: store,
            item: item,
            style: style,
            state: AgentsSessionRowState(store: store, item: item),
            row: row
        )
        .equatable()
    }
}

struct AgentsSessionRow: View {
    /// Actions only; the values the row shows arrive in `state`.
    let store: UnpeelStore
    let item: GlobalActivityMenuItem
    let style: ActivityMenuRowStyle
    let state: AgentsSessionRowState?
    /// The shared activity row, shown whenever nothing is inline.
    let row: AnyView

    private var sessionID: String { item.session.sessionID }

    var body: some View {
        if let state {
            switch state.inline {
            case .confirmingRemove:
                AgentsConfirmRow(
                    command: item.session.command,
                    question: state.session.isLive ? "Remove session?" : "Remove from list?",
                    title: item.session.title,
                    confirmLabel: "Remove",
                    onConfirm: { [store, sessionID] in store.confirmRemoveSession(sessionID) },
                    onCancel: { [store] in store.cancelRemoveConfirm() }
                )
            case .confirmingStop:
                AgentsConfirmRow(
                    command: item.session.command,
                    question: "Stop?",
                    title: item.session.title,
                    confirmLabel: "Stop",
                    onConfirm: { [store, sessionID] in store.confirmStopSession(sessionID) },
                    onCancel: { [store] in store.cancelStopConfirm() }
                )
            case .renaming:
                AgentsRenameRow(
                    command: item.session.command,
                    label: state.session.label,
                    projectPath: item.session.projectPath,
                    onCommit: { [store, sessionID] newValue in
                        if !newValue.isEmpty && newValue != state.session.label {
                            store.renameSession(sessionID, to: newValue)
                        }
                        Self.endEditing(store, sessionID)
                    },
                    onCancel: { [store, sessionID] in Self.endEditing(store, sessionID) }
                )
            case .none:
                if state.isBusy {
                    row
                        .opacity(0.5)
                        .allowsHitTesting(false)
                } else {
                    row.contextMenu { menu(state) }
                }
            }
        } else {
            row
        }
    }

    private static func endEditing(_ store: UnpeelStore, _ sessionID: String) {
        if store.editingSessionID == sessionID {
            store.editingSessionID = nil
        }
    }

    private func menu(_ state: AgentsSessionRowState) -> SessionContextMenuItems {
        let id = sessionID
        return SessionContextMenuItems(
            session: state.session,
            isPinned: state.isPinned,
            canPin: state.canPin,
            isUnread: state.isUnread,
            canMarkUnread: state.canMarkUnread,
            resumePresentation: state.resumePresentation,
            canClearAttention: state.canClearAttention,
            canNotifyWhenDone: state.canNotifyWhenDone,
            notifyWhenDone: state.notifyWhenDone,
            showsCopyTranscript: state.showsCopyTranscript,
            canStop: state.canStop,
            agentAccessRole: state.agentAccessRole,
            moveTargets: state.moveTargets,
            onBeginEdit: { [store] in store.beginEditingSessionTitle(id, on: .agentsSection) },
            // Unlike the PROJECTS row, no follow-scroll: the user is not
            // looking at the PROJECTS list.
            onSetPinned: { [store] pinned in
                if pinned {
                    store.pinSession(projectID: state.projectID, sessionID: id)
                } else {
                    store.unpinSession(projectID: state.projectID, sessionID: id)
                }
            },
            onSetUnread: { [store] in store.setSessionUnread(id, unread: $0) },
            onMoveToProjectSidebar: state.canMoveToProjectSidebar
                ? { [store] in store.moveSessionToProjectSidebar(id) }
                : nil,
            onMoveToMainArea: state.isInProjectSidebar
                ? { [store] in store.moveSessionToMainArea(id) }
                : nil,
            onMoveTo: { [store] in store.moveSession(id, toProjectID: $0) },
            onClearAttention: { [store] in store.clearAttention(id) },
            onResume: { [store] in store.resumeAgentOrSession(id) },
            onRestartApp: state.canRestartApp ? { [store] in store.restartApp(id) } : nil,
            onSetNotifyWhenDone: { [store] in store.setNotifyWhenDone(id, enabled: $0) },
            onSetAgentAccessRole: { [store] in store.setAgentAccessRole($0, for: id) },
            onCopyTranscript: { [store] in store.copyTranscriptMarkdown($0, entries: $1) },
            onStop: { [store] in store.requestStopSession(id, on: .agentsSection) },
            onRequestRemove: { [store] in store.requestRemoveSession(id, on: .agentsSection) }
        )
    }
}

extension AgentsSessionRow: @MainActor Equatable {
    /// `row` is built from `item` and `style`, and closures never change
    /// what the row shows.
    static func == (lhs: AgentsSessionRow, rhs: AgentsSessionRow) -> Bool {
        lhs.item == rhs.item && lhs.style == rhs.style && lhs.state == rhs.state
    }
}

/// The plain activity row's frame: CLI logo, then a title line over a
/// detail line, with the same insets, so going inline never moves the list.
private struct AgentsInlineRowFrame<Title: View, Detail: View, Trailing: View>: View {
    let command: String
    @ViewBuilder let title: Title
    @ViewBuilder let detail: Detail
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ToolIconView(command: command, size: 16)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                title
                detail
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            // The narrow sidebar truncates the title, never the buttons.
            trailing
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.hoverRow)
        )
        .contentShape(Rectangle())
    }
}

/// The PROJECTS inline confirmation in the AGENTS row: the question over
/// the Session's title, Cancel and the destructive verb. Esc or a click
/// anywhere else cancels.
private struct AgentsConfirmRow: View {
    let command: String
    let question: String
    let title: String
    let confirmLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        AgentsInlineRowFrame(command: command) {
            Text(question)
                .font(.system(size: 13))
                .foregroundStyle(Theme.foreground)
                .lineLimit(1)
        } detail: {
            Text(title)
        } trailing: {
            HStack(spacing: 7) {
                ConfirmPillButton(label: "Cancel", destructive: false, action: onCancel)
                ConfirmPillButton(label: confirmLabel, destructive: true, action: onConfirm)
            }
        }
        .background(RemoveConfirmDismissMonitor(onCancel: onCancel))
    }
}

/// Inline rename in the AGENTS row, with the PROJECTS editor: Enter or a
/// click away commits, Esc cancels, empty or unchanged input keeps the title.
private struct AgentsRenameRow: View {
    let command: String
    let label: String
    let projectPath: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        AgentsInlineRowFrame(command: command) {
            SessionRowRenameField(
                initialLabel: label,
                onCommit: onCommit,
                onCancel: onCancel
            )
        } detail: {
            Text(projectPath)
        } trailing: {
            EmptyView()
        }
    }
}
