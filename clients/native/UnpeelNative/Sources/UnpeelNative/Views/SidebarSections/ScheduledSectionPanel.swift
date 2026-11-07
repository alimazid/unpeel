//
//  ScheduledSectionPanel.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. SCHEDULED: the selected Host's Scheduled
//  Tasks below AGENTS. A row shows the task's name, its next run and the
//  last Run's dot; its chevron expands its recent Runs, a click on the row
//  opens the edit sheet, and its context menu has Run now, Pause/Resume,
//  Duplicate and Delete (confirmed inline). Clicking a Run opens its
//  Session while the Host keeps it. Local and remote Hosts render the same
//  way; only `store.remoteHostRuntime` knows which one it is.
//

import SwiftUI
import UnpeelShared

struct ScheduledSectionPanel: View {
    /// Observed for the kept Sessions (which Runs can open) and the scope.
    @ObservedObject var store: UnpeelStore
    @ObservedObject var model: ScheduledSectionModel

    var body: some View {
        let items = ScheduledSectionRows.resolve(
            tasks: model.tasks,
            runs: model.runsByTask,
            expanded: model.expanded,
            keptSessionIDs: Set(store.displaySessionsByID.keys),
            now: Date(),
            calendar: .autoupdatingCurrent
        )
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if items.isEmpty {
                    ScheduledSectionNotice(text: emptyText)
                } else {
                    ForEach(items) { item in
                        itemView(item)
                    }
                    if case .failed(let message) = model.availability {
                        ScheduledSectionNotice(text: message)
                    }
                }
                if let actionError = model.actionError {
                    ScheduledSectionNotice(text: actionError)
                        .accessibilityLabel("Scheduled Task error: \(actionError)")
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
        .onReceive(store.remoteHostRuntime.$snapshot) { snapshot in
            model.update(
                snapshot: snapshot,
                scopeID: store.selectedHostScope.paneScopeID,
                source: store.remoteHostRuntime
            )
        }
        .onChange(of: store.selectedHostScope.paneScopeID) { scopeID in
            model.update(
                snapshot: store.remoteHostRuntime.snapshot,
                scopeID: scopeID,
                source: store.remoteHostRuntime
            )
        }
    }

    private var emptyText: String {
        switch model.availability {
        case .loading: return "Loading Scheduled Tasks…"
        case .ready:
            return model.writes.create
                ? "No Scheduled Tasks. Add one with +."
                : "No Scheduled Tasks. Add one with unpeel schedules add."
        case .unsupported: return "This Host can't show Scheduled Tasks. Update Unpeel on the Host."
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private func itemView(_ item: ScheduledSectionItem) -> some View {
        switch item {
        case .task(let row):
            taskRow(row)
        case .run(let row):
            ScheduledRunRowView(
                row: row,
                onOpen: { store.revealSessionInCurrentScope($0) },
                onHoverIntent: { store.prefetchKeptOutput($0) }
            )
        case .loadingRuns:
            ScheduledRunNotice(text: "Loading Runs…")
        case .noRuns:
            ScheduledRunNotice(text: "No Runs yet")
        }
    }

    @ViewBuilder
    private func taskRow(_ row: ScheduledTaskRow) -> some View {
        let task = model.tasks.first { $0.id == row.id }
        if model.confirmingDeleteTaskID == row.id {
            ScheduledDeleteConfirmRow(title: row.title) {
                model.confirmDelete(row.id, writer: store.remoteHostRuntime)
            } onCancel: {
                model.cancelDelete()
            }
        } else {
            ScheduledTaskRowView(
                row: row,
                canEdit: model.writes.edit && task != nil,
                onToggle: { model.toggleExpanded(row.id) },
                onOpen: { if let task { model.openEditor(for: task) } }
            )
            .contextMenu {
                if let task { ScheduledTaskMenu(task: task, writes: model.writes, model: model, writer: store.remoteHostRuntime) }
            }
        }
    }
}

// MARK: - Rows

private struct ScheduledRunRowView: View {
    let row: ScheduledRunRow
    let onOpen: (String) -> Void
    /// A stopped Run's kept output is read ahead on hover (ADR 0006).
    let onHoverIntent: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            if let sessionID = row.openableSessionID { onOpen(sessionID) }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                ScheduledRunDot(indicator: row.indicator)
                    .frame(height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.statusText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.foreground)
                        if row.isLate {
                            Text("late")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.attention)
                                .padding(.horizontal, 4)
                                .background(Capsule().fill(Theme.attention.opacity(0.15)))
                        }
                        Spacer(minLength: 4)
                    }
                    Text(timesText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.mutedForeground.opacity(0.85))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.leading, 25)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && canOpen ? Theme.hoverRow : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .onHover { inside in
            hovering = inside
            if inside, let sessionID = row.openableSessionID { onHoverIntent(sessionID) }
        }
        .accessibilityLabel(accessibilityLabel)
        .help(canOpen ? "Open this Run's Session" : "This Run's Session is no longer kept")
    }

    private var canOpen: Bool { row.openableSessionID != nil }

    private var timesText: String {
        [row.scheduledText, row.startedText].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = ["Run \(row.statusText)", timesText]
        if row.isLate { parts.append("late") }
        if let detail = row.detail { parts.append(detail) }
        if !canOpen { parts.append("Session no longer kept") }
        return parts.joined(separator: ", ")
    }
}

/// The last Run's status at a glance; a spinner while it runs. A task that
/// has never run keeps the slot empty so names stay aligned.
struct ScheduledRunDot: View {
    let indicator: ScheduledRunIndicator?

    var body: some View {
        ZStack {
            switch indicator {
            case .running:
                BrailleSpinner(color: Theme.unread)
            case .needsYou:
                AttentionDot(color: Theme.attention)
            case .done:
                dot(Theme.accent)
            case .failed:
                dot(Theme.danger)
            case .skipped:
                dot(Theme.mutedForeground.opacity(0.55))
            case .unknown:
                Circle()
                    .strokeBorder(Theme.mutedForeground.opacity(0.7), lineWidth: 1)
                    .frame(width: 7, height: 7)
            case nil:
                EmptyView()
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

struct ScheduledSectionNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.mutedForeground.opacity(0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ScheduledRunNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.mutedForeground.opacity(0.72))
            .padding(.leading, 33)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
