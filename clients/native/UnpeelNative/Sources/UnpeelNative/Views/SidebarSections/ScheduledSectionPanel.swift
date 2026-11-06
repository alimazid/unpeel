//
//  ScheduledSectionPanel.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. SCHEDULED: the selected Host's Scheduled
//  Tasks below AGENTS. A row shows the task's name, its next run and the
//  last Run's dot; clicking it expands its recent Runs, and clicking a Run
//  opens its Session while the Host keeps it. Read-only here: tasks come
//  from `unpeel schedules`. Local and remote Hosts render the same way;
//  only `store.remoteHostRuntime` knows which one it is.
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
        case .ready: return "No Scheduled Tasks. Add one with unpeel schedules add."
        case .unsupported: return "This Host can't show Scheduled Tasks. Update Unpeel on the Host."
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private func itemView(_ item: ScheduledSectionItem) -> some View {
        switch item {
        case .task(let row):
            ScheduledTaskRowView(row: row) { model.toggleExpanded(row.id) }
        case .run(let row):
            ScheduledRunRowView(row: row) { sessionID in
                store.revealSessionInCurrentScope(sessionID)
            }
        case .loadingRuns:
            ScheduledRunNotice(text: "Loading Runs…")
        case .noRuns:
            ScheduledRunNotice(text: "No Runs yet")
        }
    }
}

// MARK: - Rows

private struct ScheduledTaskRowView: View {
    let row: ScheduledTaskRow
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                ChevronGlyph(glyph: "›", size: 17)
                    .foregroundStyle(Theme.mutedForeground)
                    .opacity(0.6)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: row.isExpanded)
                    .frame(width: 11, height: 18)
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
            .padding(.horizontal, 8)
            .frame(height: Theme.sessionRowHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Theme.hoverRow : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .help(row.isExpanded ? "Hide recent Runs" : "Show recent Runs")
    }

    private var accessibilityLabel: String {
        var parts = ["Scheduled Task \(row.title)", "next run \(row.nextRunText)"]
        if let lastRunText = row.lastRunText { parts.append("last Run \(lastRunText)") }
        parts.append(row.isExpanded ? "expanded" : "collapsed")
        return parts.joined(separator: ", ")
    }
}

private struct ScheduledRunRowView: View {
    let row: ScheduledRunRow
    let onOpen: (String) -> Void
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
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
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
private struct ScheduledRunDot: View {
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

private struct ScheduledSectionNotice: View {
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

private struct ScheduledRunNotice: View {
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
