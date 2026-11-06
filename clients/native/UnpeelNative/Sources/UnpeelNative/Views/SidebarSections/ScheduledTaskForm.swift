//
//  ScheduledTaskForm.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. The edit sheet's model as plain values: the
//  fields (`ScheduledTaskDraft`), which ones show (Instructions only for a
//  preset the Host calls an Agent Preset; the app never classifies a
//  command), the one-line approval-bypass warning, a cron Trigger kept
//  read-only (it is changed from the CLI), what a save sends, and the
//  Host's refusals as sentences. No model or permission-mode pickers: the
//  preset's command carries them.
//

import Foundation
import UnpeelShared

/// The Trigger kinds the sheet edits. Cron, and any kind this build does
/// not know, open read-only.
enum ScheduledTriggerKind: String, CaseIterable, Identifiable, Sendable {
    case hourly, daily, weekdays, weekly, once

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .once: return "Once"
        }
    }
}

/// What the sheet edits. Clock times are a `Date` whose time of day counts
/// (what a `DatePicker` binds to); the Trigger is built from the fields of
/// the chosen kind only.
struct ScheduledTaskDraft: Equatable, Sendable {
    var name: String
    var projectID: String
    var presetID: String
    var instructions: String
    var triggerKind: ScheduledTriggerKind
    /// Hourly: minutes past the hour, 0–59.
    var minute: Int
    /// Daily, Weekdays and Weekly: the time of day.
    var time: Date
    /// Weekly: the day's lowercase English name.
    var weekday: String
    /// Once: the date and time.
    var onceAt: Date
    var enabled: Bool
    var notifyWhenDone: Bool
    /// A Trigger the sheet cannot edit, kept as the Host sent it.
    var fixedTrigger: RemoteScheduleTrigger?

    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// A new task: daily at 09:00, enabled, notifying when done; a Once
    /// starts at the next whole hour.
    static func blank(projectID: String, presetID: String, now: Date, calendar: Calendar) -> Self {
        let nextHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        return Self(
            name: "", projectID: projectID, presetID: presetID, instructions: "",
            triggerKind: .daily, minute: 0,
            time: clockTime(hour: 9, minute: 0, calendar: calendar) ?? now,
            weekday: weekdayName(of: now, calendar: calendar), onceAt: nextHour,
            enabled: true, notifyWhenDone: true, fixedTrigger: nil
        )
    }

    /// An existing task, as the Host lists it.
    init(task: RemoteScheduledTask, calendar: Calendar) {
        let now = Date()
        let blank = Self.blank(projectID: task.projectID, presetID: task.presetID, now: now, calendar: calendar)
        self = blank
        name = task.name
        instructions = task.instructions ?? ""
        enabled = task.enabled
        notifyWhenDone = task.notifyWhenDone
        let trigger = task.trigger
        guard let kind = ScheduledTriggerKind(rawValue: trigger.kind) else {
            fixedTrigger = trigger
            return
        }
        triggerKind = kind
        minute = trigger.minute ?? blank.minute
        time = trigger.time.flatMap { Self.clockTime($0, calendar: calendar) } ?? blank.time
        weekday = trigger.weekday ?? blank.weekday
        onceAt = trigger.at.flatMap { ScheduledTimeText.localDateTime($0, calendar: calendar) } ?? blank.onceAt
    }

    private init(
        name: String, projectID: String, presetID: String, instructions: String,
        triggerKind: ScheduledTriggerKind, minute: Int, time: Date, weekday: String, onceAt: Date,
        enabled: Bool, notifyWhenDone: Bool, fixedTrigger: RemoteScheduleTrigger?
    ) {
        self.name = name
        self.projectID = projectID
        self.presetID = presetID
        self.instructions = instructions
        self.triggerKind = triggerKind
        self.minute = minute
        self.time = time
        self.weekday = weekday
        self.onceAt = onceAt
        self.enabled = enabled
        self.notifyWhenDone = notifyWhenDone
        self.fixedTrigger = fixedTrigger
    }

    /// The Trigger in the stored shape: `HH:MM`, a weekday's full name,
    /// `YYYY-MM-DDTHH:MM`.
    func trigger(calendar: Calendar) -> RemoteScheduleTrigger {
        if let fixedTrigger { return fixedTrigger }
        let clock = Self.format(time, "HH:mm", calendar: calendar)
        switch triggerKind {
        case .hourly: return RemoteScheduleTrigger(kind: "hourly", minute: min(max(minute, 0), 59))
        case .daily: return RemoteScheduleTrigger(kind: "daily", time: clock)
        case .weekdays: return RemoteScheduleTrigger(kind: "weekdays", time: clock)
        case .weekly: return RemoteScheduleTrigger(kind: "weekly", time: clock, weekday: weekday)
        case .once:
            return RemoteScheduleTrigger(kind: "once", at: Self.format(onceAt, "yyyy-MM-dd'T'HH:mm", calendar: calendar))
        }
    }

    private static func clockTime(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return clockTime(hour: parts[0], minute: parts[1], calendar: calendar)
    }

    private static func clockTime(hour: Int, minute: Int, calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute))
    }

    private static func weekdayName(of date: Date, calendar: Calendar) -> String {
        // Calendar weekdays run Sunday = 1 … Saturday = 7.
        let index = (calendar.component(.weekday, from: date) + 5) % 7
        return weekdays[index]
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// A Project a Run can start in.
struct ScheduledProjectChoice: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

enum ScheduledTaskForm {
    // MARK: Pickers

    /// Projects with a folder (groups have none), worktrees named by
    /// branch.
    static func projectChoices(_ projects: [RemoteProjectSummary]) -> [ScheduledProjectChoice] {
        projects
            .filter { $0.isGroup != true && !$0.path.isEmpty }
            .map { project in
                let branch = project.worktreeBranch.map { " (\($0))" } ?? ""
                return ScheduledProjectChoice(id: project.id, title: project.name + branch)
            }
    }

    /// The enabled presets a Run in `projectID` resolves against: the
    /// Project's own, and the global ones it does not override (the Host's
    /// precedence).
    static func presets(for projectID: String, in presets: [RemotePresetSummary]) -> [RemotePresetSummary] {
        let enabled = presets.filter(\.enabled)
        let own = enabled.filter { $0.projectID == projectID }
        let globals = enabled.filter { $0.projectID == nil }
        let globalIDs = Set(globals.map(\.id))
        // The global list's order, each overridden one replaced by the
        // Project's own, then the Project's own new ones.
        return globals.map { global in own.first { $0.id == global.id } ?? global }
            + own.filter { !globalIDs.contains($0.id) }
    }

    static func preset(id: String, projectID: String, in presets: [RemotePresetSummary]) -> RemotePresetSummary? {
        Self.presets(for: projectID, in: presets).first { $0.id == id }
    }

    // MARK: Fields

    /// The Instructions field shows only where the Host would take them.
    static func showsInstructions(_ preset: RemotePresetSummary?) -> Bool {
        preset?.agentPreset == true
    }

    static func isTriggerEditable(_ trigger: RemoteScheduleTrigger) -> Bool {
        ScheduledTriggerKind(rawValue: trigger.kind) != nil
    }

    static func readOnlyTriggerText(_ trigger: RemoteScheduleTrigger) -> String {
        let what = trigger.kind == "cron"
            ? "cron \(trigger.expr ?? "")"
            : "a \(trigger.kind) Trigger this version of Unpeel can't edit"
        return "Runs on \(what). Change it with unpeel schedules edit."
    }

    // MARK: Approval-bypass warning

    /// Flags that turn off an agent's approval prompts, as whole argv
    /// tokens; a generic flag counts only for the agent that reads it so.
    private static let bypassFlags: [(flag: String, onlyFor: Set<String>?)] = [
        ("--dangerously-skip-permissions", nil),
        ("--dangerously-bypass-approvals-and-sandbox", nil),
        ("--yolo", nil),
        ("--always-approve", nil),
        ("--allow-all-tools", nil),
        ("--force", ["cursor-agent"]),
        ("-y", ["gemini"]),
    ]
    /// `--option value` / `--option=value` pairs that do the same.
    private static let bypassOptions: [(option: String, value: String)] = [
        ("--permission-mode", "bypassPermissions"),
        ("--approval-mode", "yolo"),
    ]

    /// The approval-bypass flag `command` passes, as written.
    static func bypassFlag(in command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let head = tokens.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        let arguments = tokens.dropFirst()
        if let match = bypassFlags.first(where: { entry in
            arguments.contains(entry.flag) && (entry.onlyFor?.contains(head) ?? true)
        }) {
            return match.flag
        }
        for (index, token) in zip(arguments.indices, arguments) {
            for (option, value) in bypassOptions {
                if token == "\(option)=\(value)" { return token }
                if token == option, arguments.indices.contains(index + 1), arguments[index + 1] == value {
                    return "\(option) \(value)"
                }
            }
        }
        return nil
    }

    static func bypassWarning(for command: String?) -> String? {
        guard let command, let flag = bypassFlag(in: command) else { return nil }
        return "This preset runs with \(flag): each Run acts on its own, with your permissions, and asks no one first."
    }

    // MARK: Saving

    /// Why the sheet cannot save yet, if anything.
    static func problem(_ draft: ScheduledTaskDraft) -> String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the task a name." }
        if draft.projectID.isEmpty { return "Pick a Project." }
        if draft.presetID.isEmpty { return "Pick a preset." }
        return nil
    }

    static func createRequest(
        _ draft: ScheduledTaskDraft,
        showsInstructions: Bool,
        calendar: Calendar
    ) -> RemoteScheduleCreate {
        let instructions = trimmed(draft.instructions)
        return RemoteScheduleCreate(
            name: trimmed(draft.name),
            projectID: draft.projectID,
            presetID: draft.presetID,
            trigger: draft.trigger(calendar: calendar),
            instructions: showsInstructions && !instructions.isEmpty ? instructions : nil,
            enabled: draft.enabled,
            notifyWhenDone: draft.notifyWhenDone
        )
    }

    /// What changed since the sheet opened (`initial`), and only that: a
    /// Trigger the user did not touch is never resent, so the Host keeps
    /// its clock. A preset that takes no instructions drops the task's.
    static func editRequest(
        original: RemoteScheduledTask,
        initial: ScheduledTaskDraft,
        draft: ScheduledTaskDraft,
        showsInstructions: Bool,
        calendar: Calendar
    ) -> RemoteScheduleEdit {
        let trigger = draft.trigger(calendar: calendar)
        let instructions = showsInstructions ? trimmed(draft.instructions) : ""
        let name = trimmed(draft.name)
        return RemoteScheduleEdit(
            scheduleID: original.id,
            name: name != original.name ? name : nil,
            projectID: draft.projectID != original.projectID ? draft.projectID : nil,
            presetID: draft.presetID != original.presetID ? draft.presetID : nil,
            trigger: trigger != initial.trigger(calendar: calendar) ? trigger : nil,
            instructions: instructions != (original.instructions ?? "") ? instructions : nil,
            enabled: draft.enabled != original.enabled ? draft.enabled : nil,
            notifyWhenDone: draft.notifyWhenDone != original.notifyWhenDone ? draft.notifyWhenDone : nil
        )
    }

    /// Duplicate: the same task under a new name, every setting kept.
    static func duplicateRequest(of task: RemoteScheduledTask) -> RemoteScheduleCreate {
        let name = trimmed(task.name)
        return RemoteScheduleCreate(
            name: "\(name.isEmpty ? "Untitled task" : name) copy",
            projectID: task.projectID,
            presetID: task.presetID,
            trigger: task.trigger,
            instructions: task.instructions,
            enabled: task.enabled,
            notifyWhenDone: task.notifyWhenDone
        )
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The Host's refusals as a person reads them. The bridge words a refused
/// write as "… returned <status>: <Host text>"; anything else keeps its
/// own words (it is already the app's, e.g. "Update Unpeel on the Host").
enum ScheduledTaskErrorText {
    static func message(for error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard let (status, text) = hostAnswer(in: raw) else { return raw }
        switch status {
        case 409: return "A Run of this task is still in progress. Try again once it finishes."
        case 404: return "This Scheduled Task no longer exists on the Host."
        case 403: return "Only you can change Scheduled Tasks on this Host."
        default: break
        }
        if text.contains("in the past") { return "That time has already passed. Pick a time in the future." }
        if text.contains("not an Agent Preset") {
            return "This preset doesn't start an agent Unpeel can tell is ready, so it can't take instructions. "
                + "Clear them or pick an agent preset."
        }
        if let detail = text.removingPrefix("invalid Trigger: ") {
            return "That schedule isn't valid: \(sentence(detail, capitalized: false))"
        }
        return sentence(text, capitalized: true)
    }

    /// `(status, Host text)` from a bridge message, if it carries one.
    private static func hostAnswer(in message: String) -> (Int, String)? {
        guard let marker = message.range(of: "returned ", options: .backwards) else { return nil }
        let rest = message[marker.upperBound...]
        let digits = rest.prefix(3)
        guard digits.count == 3, let status = Int(digits), rest.dropFirst(3).hasPrefix(": ") else { return nil }
        let text = rest.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (status, text)
    }

    private static func sentence(_ text: String, capitalized: Bool) -> String {
        var words = text
        if capitalized, let first = words.first { words = first.uppercased() + words.dropFirst() }
        return words.hasSuffix(".") ? words : words + "."
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
