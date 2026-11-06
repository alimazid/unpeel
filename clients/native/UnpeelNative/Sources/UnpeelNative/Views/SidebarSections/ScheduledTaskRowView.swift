//
//  ScheduledTaskRowView.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. One SCHEDULED task row: its chevron expands
//  the recent Runs, the rest of the row opens the edit sheet. Its context
//  menu (Run now, Pause/Resume, Duplicate, Delete) and the inline Delete
//  confirmation, which keeps the row's height like an AGENTS row so the
//  list never jumps. Plain labelled buttons, so the menu and the row are
//  drivable through accessibility.
//

import SwiftUI
import UnpeelShared

struct ScheduledTaskRowView: View {
    let row: ScheduledTaskRow
    /// The Host takes edits: a click opens the sheet. Otherwise it expands,
    /// as before the Host could edit.
    let canEdit: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                ChevronGlyph(glyph: "›", size: 17)
                    .foregroundStyle(Theme.mutedForeground)
                    .opacity(0.6)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: row.isExpanded)
                    .frame(width: 11, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isExpanded ? "Hide recent Runs of \(row.title)" : "Show recent Runs of \(row.title)")
            .help(row.isExpanded ? "Hide recent Runs" : "Show recent Runs")

            Button(action: canEdit ? onOpen : onToggle) {
                HStack(spacing: 6) {
                    ScheduledRunDot(indicator: row.indicator)
                    Text(row.title)
                        .font(Theme.rowLabelFont)
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(row.nextRunText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .help(canEdit ? "Edit this Scheduled Task" : (row.isExpanded ? "Hide recent Runs" : "Show recent Runs"))
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.sessionRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Theme.hoverRow : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var accessibilityLabel: String {
        var parts = ["Scheduled Task \(row.title)", "next run \(row.nextRunText)"]
        if let lastRunText = row.lastRunText { parts.append("last Run \(lastRunText)") }
        parts.append(row.isExpanded ? "expanded" : "collapsed")
        return parts.joined(separator: ", ")
    }
}

/// The row's context menu: Run now, Pause or Resume, Duplicate, Delete,
/// each offered only where the Host serves it.
struct ScheduledTaskMenu: View {
    let task: RemoteScheduledTask
    let writes: ScheduledTaskWrites
    let model: ScheduledSectionModel
    let writer: any ScheduledTasksWriter

    var body: some View {
        if writes.run {
            Button("Run now") { model.runNow(task.id, writer: writer) }
        }
        if writes.edit {
            Button(task.enabled ? "Pause" : "Resume") { model.setPaused(task, task.enabled, writer: writer) }
        }
        if writes.create {
            Button("Duplicate") { model.duplicate(task, writer: writer) }
        }
        if writes.delete {
            Divider()
            Button("Delete") { model.requestDelete(task.id) }
        }
    }
}

/// Delete's inline confirmation, in the task row's own height so the list
/// never jumps: the question, Cancel and Delete. Esc or a click anywhere
/// else cancels. Its Run Sessions stay (said in the tooltip).
struct ScheduledDeleteConfirmRow: View {
    let title: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Delete “\(title)”?")
                .font(.system(size: 13))
                .foregroundStyle(Theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Deletes the task and its history. Its Run Sessions stay.")
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                ConfirmPillButton(label: "Cancel", destructive: false, action: onCancel)
                ConfirmPillButton(label: "Delete", destructive: true, action: onConfirm)
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.sessionRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.hoverRow)
        )
        .background(RemoveConfirmDismissMonitor(onCancel: onCancel))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Delete Scheduled Task \(title)?")
    }
}
