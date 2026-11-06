//
//  SessionContextMenuItems.swift
//  UnpeelNative
//
//  The session right-click menu. `SessionRowView` (PROJECTS) shows it, and
//  the fork's AGENTS section rows show the same one, so the two lists can
//  never drift. Callers own the gating values and wire the actions.
//

import AppKit
import SwiftUI

struct SessionContextMenuItems: View {
    let session: SessionEntry
    let isPinned: Bool
    let canPin: Bool
    let isUnread: Bool
    /// Fork-only: offer Mark as Unread / Mark as Read (a Host verb).
    let canMarkUnread: Bool
    let resumePresentation: SessionRowResumePresentation
    let canClearAttention: Bool
    let canNotifyWhenDone: Bool
    let notifyWhenDone: Bool
    /// See `sessionRowShowsCopyTranscript`: a collapsed pane group leaves
    /// the action to each pane's own menu.
    let showsCopyTranscript: Bool
    let canStop: Bool
    /// Nil hides the Agent access submenu.
    let agentAccessRole: McpRole?
    /// Empty hides the Move to submenu.
    let moveTargets: [SessionMoveTarget]
    let onBeginEdit: () -> Void
    let onSetPinned: (Bool) -> Void
    let onSetUnread: (Bool) -> Void
    /// Nil hides the item.
    let onMoveToProjectSidebar: (() -> Void)?
    /// Nil hides the item.
    let onMoveToMainArea: (() -> Void)?
    let onMoveTo: (String) -> Void
    let onClearAttention: () -> Void
    let onResume: () -> Void
    /// Nil hides Restart App.
    let onRestartApp: (() -> Void)?
    let onSetNotifyWhenDone: (Bool) -> Void
    let onSetAgentAccessRole: (McpRole) -> Void
    /// Fork-only: the Super Agent items (Host verbs). Nil hides each one.
    let onMakeSuperAgent: (() -> Void)?
    let onStopBeingSuperAgent: (() -> Void)?
    let onHandToSuperAgent: (() -> Void)?
    let onCopyTranscript: (String, Int) -> Void
    let onStop: () -> Void
    let onRequestRemove: () -> Void

    var body: some View {
        // Same first item as the Svelte session context menu
        // (session-menu-rename, ProjectItem.svelte:1038-1043).
        Button("Rename") {
            onBeginEdit()
        }
        if canPin {
            Button(isPinned ? "Unpin" : "Pin") {
                onSetPinned(!isPinned)
            }
        }
        // Fork-only: the blue dot on demand, so the agent comes back to the
        // AGENTS section's recently-finished group until it is read.
        if canMarkUnread {
            Button(isUnread ? "Mark as Read" : "Mark as Unread") {
                onSetUnread(!isUnread)
            }
        }
        // Files the session into the project's pinned "Sidebar" group — the
        // desktop shows those members as a right-side terminal stack, and the
        // TUI/phone find them in that top group like any other group. The
        // counterpart un-files a sidebar member back to its own project.
        if let onMoveToProjectSidebar {
            Button("Pin to global project sidebar") {
                onMoveToProjectSidebar()
            }
        }
        if let onMoveToMainArea {
            Button("Unpin from global project sidebar") {
                onMoveToMainArea()
            }
        }
        // File the session under a plain group (or back to the root project)
        // using a shared project-override marker, so the TUI and phone see
        // the same placement. Worktrees require restart/resume.
        if !moveTargets.isEmpty {
            Menu("Move to") {
                ForEach(moveTargets) { target in
                    Button(target.name) { onMoveTo(target.id) }
                }
            }
        }
        // Escape hatch for a stuck or false attention badge (a missed
        // hook, or menu detection tripping on look-alike screen text) —
        // otherwise nothing short of answering/restarting clears it.
        if session.status == .attention, canClearAttention {
            Button("Clear attention") {
                onClearAttention()
            }
        }
        // Verb items are capability-gated per CLI (ProviderCapabilities —
        // the same answers the phone's session sheet gets): no Resume for
        // commands whose conversation a relaunch would silently lose and no
        // notify toggle without hook Stop events.
        if session.status != .starting {
            // An ended managed launch can resume from the still-live shell in
            // the existing terminal. A stopped Session uses the legacy
            // replacement operation and presents that honestly as Resume.
            if resumePresentation == .resumeAgent {
                Button("Resume Agent") {
                    onResume()
                }
            } else if resumePresentation == .resumeSession {
                Button("Resume") {
                    onResume()
                }
            }
            if let onRestartApp {
                Button("Restart App") {
                    onRestartApp()
                }
            }
        }
        // "Notify when done" — push a phone notification when this session
        // next finishes a turn (paired iPhone with notifications on).
        if canNotifyWhenDone {
            Toggle("Notify when done", isOn: Binding(
                get: { notifyWhenDone },
                set: { onSetNotifyWhenDone($0) }
            ))
        }
        Divider()
        // Fork-only: the Super Agent runs other agent Sessions for the
        // user. Only a Claude Code Session can become it; any agent can be
        // handed to it.
        if let onMakeSuperAgent {
            Button("Make Super Agent") {
                onMakeSuperAgent()
            }
        }
        if let onStopBeingSuperAgent {
            Button("Stop Being Super Agent") {
                onStopBeingSuperAgent()
            }
        }
        if let onHandToSuperAgent {
            Button("Hand to Super Agent") {
                onHandToSuperAgent()
            }
        }
        if let agentAccessRole {
            agentAccessMenu(current: agentAccessRole)
        }
        if showsCopyTranscript {
            copyTranscriptMenu(sessionID: session.id)
        }
        // Every Unpeel Session has an id. It is useful beyond agent/MCP
        // features, so keep it as a direct session-level action.
        Button("Copy session ID") {
            copyToPasteboard("Unpeel Session ID: \(session.id)")
        }
        Divider()
        // Stop is the non-destructive "clear it out": kill the hosted
        // terminal and keep the row in the stopped section, from where
        // Resume continues the conversation. Working sessions get an inline
        // confirm first. Only live resumable launches offer it; for the
        // rest, Remove below is the sole clear-it-out verb.
        if canStop {
            Button("Stop") {
                onStop()
            }
        }
        // Remove stays the explicit destructive verb: it deletes Unpeel's
        // session directory (terminal output and artifacts). Provider
        // transcripts stay in the agent's own storage.
        Button(session.isLive ? "Remove session" : "Remove from list", role: .destructive) {
            onRequestRemove()
        }
    }

    /// What this agent may do to other sessions through Unpeel's tools.
    /// Applies live: the MCP host re-reads the role on every call.
    private func agentAccessMenu(current: McpRole) -> some View {
        Menu("Agent access") {
            Picker("Agent access", selection: Binding(
                get: { current },
                set: { onSetAgentAccessRole($0) }
            )) {
                ForEach(McpRole.allCases) { role in
                    Text(role.label).tag(role)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Text(current.detail)
        }
        .help("What this agent may do to other sessions through Unpeel's tools")
    }

    @ViewBuilder
    private func copyTranscriptMenu(sessionID: String) -> some View {
        // Content toggles still come from Settings ▸ Transcripts; 0 means
        // the complete provider conversation.
        Menu("Copy transcript") {
            Button("Last 20 entries") {
                onCopyTranscript(sessionID, 20)
            }
            Button("Last 50 entries") {
                onCopyTranscript(sessionID, 50)
            }
            Button("Whole conversation") {
                onCopyTranscript(sessionID, 0)
            }
        }
        .help("Copy the conversation as Markdown, using your Settings ▸ Transcripts content options")
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
