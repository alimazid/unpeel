// Fork-only file (ADR 0009, #45): the live PROJECTS list's row views, built
// with every display input resolved from the store when the list body
// builds the row.

import SwiftUI

extension SidebarLiveTreeList {
    func headerRowView(
        _ node: ProjectNode,
        row: SidebarTreeRow,
        isExpanded: Bool,
        inputs: SidebarLiveRowInputs
    ) -> ProjectRowView {
        let isTopLevel = node.project.parentProjectID == nil
        // Local machine, not just Local scope: a scoped workspace's project
        // paths are real paths on this Mac, so git worktree verbs are valid
        // there too (the store routes their session/record halves per scope).
        let isGitProject = inputs.isLocalMachine
            && node.project.isFolder != true
            && UnpeelStore.isGitRepo(path: node.project.path)
        let canCreateWorktree = inputs.worktreesEnabled
            && isGitProject && node.project.worktreeBranch == nil
        let rollup = SidebarFolderRollup(
            node: node,
            isExpanded: isExpanded,
            isUnread: { store.sessionIsUnread($0) }
        )
        return ProjectRowView(
            node: node,
            depth: row.depth,
            isExpanded: isExpanded,
            showsAttentionDot: rollup.showsAttentionDot,
            showsUnreadDot: rollup.showsUnreadDot,
            showsBusyShimmer: rollup.showsBusyShimmer,
            quickGroups: inputs.quickGroups,
            menuPresets: inputs.menuPresets,
            folderColor: inputs.isLocalMachine ? store.projectFolderColor(for: node.id) : nil,
            // Worktree menu toggle gate (ProjectItem.svelte:843-848): real
            // project (not a plain folder), not a worktree child, and the
            // path is a git repo.
            showsWorktreeCreate: canCreateWorktree,
            showsLocalProjectVerbs: inputs.isLocalScope,
            showsOrganizationVerbs: inputs.isLocalMachine,
            showsFilesystemVerbs: inputs.isLocalMachine,
            isConfirmingRemove: store.confirmingRemoveProjectID == node.id,
            shortcutHint: store.projectShortcutHintIndex(forProject: node.id),
            hasLiveSessions: node.sessions.contains(where: \.isLive),
            // Host-probed live URLs are family-wide, so only the top-level
            // project row wears the globe. Fork-only (#77): a scoped local
            // workspace's Sessions run on this Mac too, so its sites open.
            localSiteURLs: inputs.isLocalMachine && isTopLevel
                ? store.localSiteURLs(forProjectFamilyOf: node.id)
                : [],
            // Plain git projects (worktree children already carry their
            // branch in the model) show the checked-out branch while they
            // hold the selected session.
            activeBranchStore: node.project.worktreeBranch == nil ? store : nil,
            onToggle: { toggleExpansion(node.id) },
            onLaunchPreset: { preset in
                // startSessionOrToast via launchPresetForProject
                // (App.svelte:1168-1175).
                store.launchSession(
                    projectID: node.id,
                    command: preset.command,
                    sourcePresetID: preset.command.isEmpty ? nil : preset.id
                )
            },
            onCreateWorktree: { store.promptCreateWorktree(projectID: node.id) },
            onCreateGroup: { store.promptCreateGroup(projectID: node.id) },
            onRemoveGroup: { store.removeGroupProject(node.id) },
            onStopAll: { store.stopAllSessions(projectID: node.id) },
            onRevealInFinder: { store.revealInFinder(path: node.project.path) },
            onOpenIn: { target in
                store.openWorkspace(path: node.project.path, in: target)
            },
            onRequestRemove: { store.requestRemoveProject(node.id) },
            onConfirmRemove: { store.removeProject(node.id) },
            onCancelRemove: { store.cancelRemoveProjectConfirm() },
            onRenameWorktree: { store.promptRenameWorktreeProject(node.id) },
            onRemoveWorktree: { store.removeWorktreeProject(node.id) },
            onSetFolderColor: { color in
                store.setProjectFolderColor(color, for: node.id)
            },
            isPinned: store.isGroupPinned(node.id),
            canPin: store.groupCanPin(node.id),
            onSetPinned: { pinned in
                store.setGroupPinned(node.id, pinned: pinned)
            },
            isDateSorted: store.isDateSorted(projectID: node.id),
            onSetSessionDateSorted: { dateSorted in
                store.setSessionDateSorted(dateSorted, for: node.id)
            },
            onManagePresets: { store.openSettings(tab: .agents) },
            onManagePlugins: { store.openSettings(tab: .plugins) },
            workspaceMoveTargets: isTopLevel ? inputs.workspaceMoveTargets : [],
            onMoveToWorkspace: { dest in
                store.moveProjectToLocalWorkspace(projectID: node.id, dest: dest)
            }
        )
    }

    func placeholderRowView(
        _ owner: ProjectNode,
        depth: Int,
        inputs: SidebarLiveRowInputs
    ) -> EmptySessionsPlaceholderRow {
        EmptySessionsPlaceholderRow(
            label: EmptySessionsPlaceholderRow.label(for: owner),
            depth: depth,
            indentBase: 28,
            menuPresets: inputs.menuPresets,
            onLaunch: { preset in
                store.launchSession(
                    projectID: owner.id,
                    command: preset.command,
                    sourcePresetID: preset.command.isEmpty ? nil : preset.id
                )
            },
            onManagePresets: { store.openSettings(tab: .agents) },
            onManagePlugins: { store.openSettings(tab: .plugins) },
            showsManagePresets: inputs.isLocalScope
        )
    }

    func sessionRowView(_ session: SessionEntry, ownerID: String, depth: Int) -> SessionRowView {
        let superAgentMenu = store.superAgentMenu(forSession: session.id)
        return SessionRowView(
            session: session,
            depth: depth,
            // Depth alone supplies the standard 14pt nesting step beneath a
            // child folder; no extra child-folder offset is needed.
            indentBase: 9,
            isSelected: false,
            selectionState: store.sessionSelection.rowState(for: session.id),
            // ⌘N hints while ⌘ is held and this is the shortcut project.
            shortcutHint: store.sessionShortcutHintIndices(forProject: ownerID)[session.id],
            isUnread: store.sessionIsUnread(session.id),
            isPinned: store.isPinned(sessionID: session.id, projectID: ownerID),
            canPin: store.sessionCanPin(session.id),
            canMarkUnread: store.sessionCanMarkUnread(session.id),
            // A confirmation armed from the AGENTS row stays there.
            isConfirmingRemove: store.confirmingRemoveSessionID == session.id
                && store.confirmingSessionSurface == .sidebar,
            isConfirmingStop: store.confirmingStopSessionID == session.id
                && store.confirmingSessionSurface == .sidebar,
            isRemoving: store.removingSessionIDs.contains(session.id),
            isRestarting: store.restartingSessionIDs.contains(session.id),
            isResumingAgent: store.resumingAgentSessionIDs.contains(session.id),
            isEditing: store.editingSessionID == session.id
                && store.editingSessionSurface == .sidebar,
            notifyWhenDone: store.notifyWhenDoneSessionIDs.contains(session.id),
            canRestart: store.sessionCanRestart(session.id),
            canResumeAgent: store.sessionCanResumeAgent(session.id),
            canStop: store.sessionCanStop(session.id),
            canNotifyWhenDone: store.sessionCanNotifyWhenDone(session.id),
            canClearAttention: store.sessionCanClearAttention(session.id),
            paneItems: store.paneSidebarItems(forRepresentative: session.id),
            ageTimestampMs: store.isDateSorted(projectID: ownerID)
                ? max(session.createdAt, session.lifecycleAtMs ?? 0)
                : nil,
            onSelect: {
                store.selectedSessionID = session.id
            },
            onFocusPane: { paneSessionID in
                store.requestTerminalPaneFocus(
                    representativeSessionID: session.id,
                    sessionID: paneSessionID
                )
            },
            onHoverIntent: { store.prewarmSession(session.id) },
            onSetNotifyWhenDone: {
                store.setNotifyWhenDone(session.id, enabled: $0)
            },
            onResume: { store.resumeAgentOrSession(session.id) },
            onRestartApp: store.sessionCanRestartApp(session.id)
                ? { store.restartApp(session.id) }
                : nil,
            onClearAttention: { store.clearAttention(session.id) },
            onSetPinned: { pinned in
                if pinned {
                    store.pinSession(projectID: ownerID, sessionID: session.id)
                } else {
                    store.unpinSession(projectID: ownerID, sessionID: session.id)
                }
                store.followSessionRowInSidebar(session.id)
            },
            onSetUnread: { store.setSessionUnread(session.id, unread: $0) },
            onRequestRemove: { store.requestRemoveSession(session.id) },
            onConfirmRemove: { store.confirmRemoveSession(session.id) },
            onCancelRemove: { store.cancelRemoveConfirm() },
            onStop: { store.requestStopSession(session.id) },
            onConfirmStop: { store.confirmStopSession(session.id) },
            onCancelStop: { store.cancelStopConfirm() },
            onCopyTranscript: {
                store.copyTranscriptMarkdown($0, entries: $1)
            },
            agentAccessRole: store.canSetAgentAccess(session.id)
                ? store.agentAccessRole(for: session.id)
                : nil,
            onSetAgentAccessRole: { store.setAgentAccessRole($0, for: session.id) },
            onBeginEdit: {
                store.beginEditingSessionTitle(session.id, on: .sidebar)
            },
            onCommitRename: { store.renameSession(session.id, to: $0) },
            onEndEdit: {
                if store.editingSessionID == session.id {
                    store.editingSessionID = nil
                }
            },
            moveTargets: store.isExperimentalEnabled(.worktrees)
                ? store.moveDestinations(forSession: session.id)
                    .map { SessionMoveTarget(id: $0.id, name: $0.name) }
                : [],
            onMoveTo: { store.moveSession(session.id, toProjectID: $0) },
            onMoveToProjectSidebar: store.canMoveSessionToProjectSidebar(session.id)
                ? { store.moveSessionToProjectSidebar(session.id) }
                : nil,
            onMoveToMainArea: store.sessionIsInProjectSidebar(session.id)
                ? { store.moveSessionToMainArea(session.id) }
                : nil,
            onMakeSuperAgent: superAgentMenu.canMake
                ? { store.makeSuperAgent(session.id) }
                : nil,
            onStopBeingSuperAgent: superAgentMenu.canStopBeing
                ? { store.stopBeingSuperAgent(session.id) }
                : nil,
            onHandToSuperAgent: superAgentMenu.canHandOver
                ? { store.handToSuperAgent(session.id) }
                : nil
        )
    }
}
