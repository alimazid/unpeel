//
//  ScheduledTaskSheet.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. The New / Edit Scheduled Task sheet: Name,
//  Project, Preset, Instructions (Agent Presets only), Trigger, Enabled and
//  Notify when done. Projects and presets come from the selected Host's
//  bootstrap, so a remote Host's sheet is the same sheet; the Host checks
//  every save and its refusal shows here. The rules live in
//  `ScheduledTaskForm`.
//

import SwiftUI
import UnpeelShared

struct ScheduledTaskSheet: View {
    let editing: ScheduledTaskEditing
    @ObservedObject var runtime: RemoteHostRuntime
    let onClose: () -> Void

    @State private var draft: ScheduledTaskDraft
    private let initial: ScheduledTaskDraft
    @State private var working = false
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?
    private let calendar = Calendar.autoupdatingCurrent

    init(
        editing: ScheduledTaskEditing,
        runtime: RemoteHostRuntime,
        defaultProjectID: String?,
        onClose: @escaping () -> Void
    ) {
        self.editing = editing
        self.runtime = runtime
        self.onClose = onClose
        let calendar = Calendar.autoupdatingCurrent
        let start: ScheduledTaskDraft
        if let task = editing.task {
            start = ScheduledTaskDraft(task: task, calendar: calendar)
        } else {
            let snapshot = runtime.snapshot
            let projects = ScheduledTaskForm.projectChoices(snapshot?.projects ?? [])
            let projectID = projects.first { $0.id == defaultProjectID }?.id ?? projects.first?.id ?? ""
            let presetID = ScheduledTaskForm.presets(for: projectID, in: snapshot?.presets ?? []).first?.id ?? ""
            start = .blank(projectID: projectID, presetID: presetID, now: Date(), calendar: calendar)
        }
        initial = start
        _draft = State(initialValue: start)
    }

    private var projects: [ScheduledProjectChoice] {
        ScheduledTaskForm.projectChoices(runtime.snapshot?.projects ?? [])
    }

    private var presets: [RemotePresetSummary] {
        ScheduledTaskForm.presets(for: draft.projectID, in: runtime.snapshot?.presets ?? [])
    }

    private var preset: RemotePresetSummary? {
        presets.first { $0.id == draft.presetID }
    }

    private var showsInstructions: Bool { ScheduledTaskForm.showsInstructions(preset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            nameField
            projectAndPreset
            if showsInstructions { instructionsField }
            triggerFields
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Enabled", isOn: $draft.enabled)
                Toggle("Notify when done", isOn: $draft.notifyWhenDone)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(errorMessage)")
            }
            footer
        }
        .padding(24)
        .frame(width: 500)
        .onChange(of: draft.projectID) { _ in
            if !presets.contains(where: { $0.id == draft.presetID }) {
                draft.presetID = presets.first?.id ?? ""
            }
        }
        .onChange(of: draft) { _ in errorMessage = nil }
        .onDisappear {
            operation?.cancel()
            operation = nil
        }
    }

    // MARK: Fields

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editing.task == nil ? "New Scheduled Task" : "Edit Scheduled Task")
                .font(.system(size: 20, weight: .semibold))
            Text("Starts a Session from a preset in a Project each time its schedule comes due, on the Host's clock.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameField: some View {
        labeled("Name") {
            TextField("Morning briefing", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Name")
        }
    }

    private var projectAndPreset: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Project") {
                Picker("Project", selection: $draft.projectID) {
                    if !projects.contains(where: { $0.id == draft.projectID }) {
                        Text(draft.projectID.isEmpty ? "Choose a Project" : "Missing Project").tag(draft.projectID)
                    }
                    ForEach(projects) { project in
                        Text(project.title).tag(project.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Project")
            }
            labeled("Preset") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Preset", selection: $draft.presetID) {
                        if preset == nil {
                            Text(draft.presetID.isEmpty ? "Choose a preset" : "Missing preset").tag(draft.presetID)
                        }
                        ForEach(presets) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Preset")
                    if let command = preset?.command {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let warning = ScheduledTaskForm.bypassWarning(for: preset) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.attention)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(warning)
                            .accessibilityLabel("Warning: \(warning)")
                    }
                }
            }
        }
    }

    private var instructionsField: some View {
        labeled("Instructions") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $draft.instructions)
                    .font(.system(size: 12))
                    .frame(height: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.mutedForeground.opacity(0.3))
                    )
                    .accessibilityLabel("Instructions")
                Text("Typed into the agent once it is ready, on every Run.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
    }

    @ViewBuilder
    private var triggerFields: some View {
        labeled("Schedule") {
            if let fixed = draft.fixedTrigger {
                Text(ScheduledTaskForm.readOnlyTriggerText(fixed))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Schedule, read-only: \(ScheduledTaskForm.readOnlyTriggerText(fixed))")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Schedule", selection: $draft.triggerKind) {
                        ForEach(ScheduledTriggerKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Schedule")
                    triggerDetail
                }
            }
        }
    }

    @ViewBuilder
    private var triggerDetail: some View {
        switch draft.triggerKind {
        case .hourly:
            HStack(spacing: 6) {
                Text("Every hour at")
                Picker("Minute", selection: $draft.minute) {
                    ForEach(0..<60, id: \.self) { minute in
                        Text(String(format: ":%02d", minute)).tag(minute)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Minute past the hour")
            }
        case .daily, .weekdays:
            HStack(spacing: 6) {
                Text(draft.triggerKind == .daily ? "Every day at" : "Monday to Friday at")
                timePicker
            }
        case .weekly:
            HStack(spacing: 6) {
                Text("Every")
                Picker("Day", selection: $draft.weekday) {
                    ForEach(ScheduledTaskDraft.weekdays, id: \.self) { day in
                        Text(day.capitalized).tag(day)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Day of the week")
                Text("at")
                timePicker
            }
        case .once:
            DatePicker("Once at", selection: $draft.onceAt, displayedComponents: [.date, .hourAndMinute])
                .accessibilityLabel("Date and time")
        }
    }

    private var timePicker: some View {
        DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .accessibilityLabel("Time")
    }

    private var footer: some View {
        HStack {
            if let problem = ScheduledTaskForm.problem(draft) {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedForeground)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
            Button(editing.task == nil ? "Create" : "Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(working || ScheduledTaskForm.problem(draft) != nil)
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    // MARK: Saving

    private func close() {
        operation?.cancel()
        operation = nil
        onClose()
    }

    private func save() {
        guard !working, ScheduledTaskForm.problem(draft) == nil else { return }
        let showsInstructions = self.showsInstructions
        let draft = self.draft
        working = true
        errorMessage = nil
        operation = Task { @MainActor in
            defer { working = false }
            do {
                if let task = editing.task {
                    let edit = ScheduledTaskForm.editRequest(
                        original: task, initial: initial, draft: draft,
                        showsInstructions: showsInstructions, calendar: calendar
                    )
                    if edit.changesSomething { _ = try await runtime.editSchedule(edit) }
                } else {
                    _ = try await runtime.createSchedule(ScheduledTaskForm.createRequest(
                        draft, showsInstructions: showsInstructions, calendar: calendar
                    ))
                }
                guard !Task.isCancelled else { return }
                onClose()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                errorMessage = ScheduledTaskErrorText.message(for: error)
            }
        }
    }
}

/// Presents the sheet the SCHEDULED model asks for, from a view that stays
/// mounted while the section is collapsed (the header's "+" works then too).
struct ScheduledTaskSheetPresenter: View {
    @ObservedObject var model: ScheduledSectionModel
    let store: UnpeelStore

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(item: Binding(
                get: { model.editing },
                set: { if $0 == nil { model.closeEditor() } }
            )) { editing in
                ScheduledTaskSheet(
                    editing: editing,
                    runtime: store.remoteHostRuntime,
                    defaultProjectID: store.selectedSessionID.flatMap { store.displaySessionsByID[$0]?.projectID },
                    onClose: model.closeEditor
                )
            }
    }
}

/// SCHEDULED's header action: "+" opens a blank sheet, on a Host that
/// takes new tasks.
struct ScheduledSectionActions: View {
    @ObservedObject var runtime: RemoteHostRuntime
    let model: ScheduledSectionModel

    var body: some View {
        if ScheduledTaskWrites(protocol: runtime.snapshot?.hostProtocol).create {
            Button {
                model.openNewTask()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mutedForeground)
            .help("New Scheduled Task")
            .accessibilityLabel("New Scheduled Task")
        }
    }
}
