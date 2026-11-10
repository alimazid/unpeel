//
//  ScheduledSectionRows.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. What the SCHEDULED section shows, as plain
//  values built from the Host's DTOs: a row per task (name, next run, the
//  last Run's dot) and, under an expanded task, its recent Runs. Times are
//  worded against `now` each time the rows are built; nothing here keeps
//  time on its own.
//

import Foundation
import UnpeelShared

/// The dot a Run's status shows as. Statuses a newer Host adds are
/// `.unknown`, drawn generically.
enum ScheduledRunIndicator: Equatable, Sendable {
    case running
    case done
    case needsYou
    case failed
    case skipped
    case unknown

    init(_ status: RemoteScheduleRunStatus) {
        switch status {
        case .running: self = .running
        case .done: self = .done
        case .needsYou: self = .needsYou
        case .failed, .failedToStart: self = .failed
        case .skipped: self = .skipped
        case .other: self = .unknown
        }
    }

    /// The status in words; an unknown one as the Host wrote it.
    static func statusText(_ status: RemoteScheduleRunStatus) -> String {
        switch status {
        case .running: return "Running"
        case .done: return "Done"
        case .needsYou: return "Needs you"
        case .failed: return "Failed"
        case .failedToStart: return "Failed to start"
        case .skipped: return "Skipped"
        case .other(let word): return word
        }
    }
}

struct ScheduledTaskRow: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let nextRunText: String
    /// The last Run's dot; nil before the first Run.
    let indicator: ScheduledRunIndicator?
    let lastRunText: String?
    let isExpanded: Bool
}

struct ScheduledRunRow: Equatable, Identifiable, Sendable {
    let id: String
    let taskID: String
    let indicator: ScheduledRunIndicator
    let statusText: String
    let scheduledText: String
    let startedText: String?
    let isLate: Bool
    /// The reply snippet, or why the Run failed or was skipped.
    let detail: String?
    /// The Run's Session, only while the Host still keeps it.
    let openableSessionID: String?
}

enum ScheduledSectionItem: Equatable, Identifiable, Sendable {
    case task(ScheduledTaskRow)
    case run(ScheduledRunRow)
    /// An expanded task whose Runs have not arrived yet.
    case loadingRuns(taskID: String)
    /// An expanded task that has never run.
    case noRuns(taskID: String)

    var id: String {
        switch self {
        case .task(let row): return "task:\(row.id)"
        case .run(let row): return "run:\(row.id)"
        case .loadingRuns(let taskID): return "loading:\(taskID)"
        case .noRuns(let taskID): return "empty:\(taskID)"
        }
    }

    var taskRow: ScheduledTaskRow? {
        if case .task(let row) = self { return row }
        return nil
    }

    var runRow: ScheduledRunRow? {
        if case .run(let row) = self { return row }
        return nil
    }
}

enum ScheduledSectionRows {
    /// Tasks in `displayOrder`, each expanded one followed by its Runs
    /// (newest first, as the Host sends them).
    static func resolve(
        tasks: [RemoteScheduledTask],
        runs: [String: [RemoteScheduleRun]],
        expanded: Set<String>,
        keptSessionIDs: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> [ScheduledSectionItem] {
        displayOrder(tasks, calendar: calendar).flatMap { task -> [ScheduledSectionItem] in
            let isExpanded = expanded.contains(task.id)
            let row = ScheduledSectionItem.task(taskRow(task, isExpanded: isExpanded, now: now, calendar: calendar))
            guard isExpanded else { return [row] }
            guard let taskRuns = runs[task.id] else { return [row, .loadingRuns(taskID: task.id)] }
            guard !taskRuns.isEmpty else { return [row, .noRuns(taskID: task.id)] }
            return [row] + taskRuns.map { run in
                .run(runRow(run, taskID: task.id, keptSessionIDs: keptSessionIDs, now: now, calendar: calendar))
            }
        }
    }

    /// Display only; the Host's list keeps its own order. Enabled tasks
    /// with a next run come first, soonest first (one whose time can't be
    /// read last among them), then enabled ones with none ("Not
    /// scheduled"), then paused ones ("Off"). Ties go by the shown name,
    /// then id, so rows sharing a time keep their places between refreshes.
    private static func displayOrder(_ tasks: [RemoteScheduledTask], calendar: Calendar) -> [RemoteScheduledTask] {
        tasks
            .map { task in (task: task, key: OrderKey(task, calendar: calendar)) }
            .sorted { $0.key.precedes($1.key) }
            .map(\.task)
    }

    private struct OrderKey {
        enum Group: Int { case due, unreadable, notScheduled, paused }

        let group: Group
        let due: Date?
        let name: String
        let id: String

        init(_ task: RemoteScheduledTask, calendar: Calendar) {
            let due = task.enabled ? task.nextRun.flatMap { nextRunDate($0, calendar: calendar) } : nil
            self.due = due
            self.name = title(task)
            self.id = task.id
            if !task.enabled {
                group = .paused
            } else if task.nextRun == nil {
                group = .notScheduled
            } else {
                group = due == nil ? .unreadable : .due
            }
        }

        func precedes(_ other: OrderKey) -> Bool {
            if group != other.group { return group.rawValue < other.group.rawValue }
            if let due, let otherDue = other.due, due != otherDue { return due < otherDue }
            let order = name.localizedCaseInsensitiveCompare(other.name)
            return order == .orderedSame ? id < other.id : order == .orderedAscending
        }
    }

    private static func taskRow(
        _ task: RemoteScheduledTask,
        isExpanded: Bool,
        now: Date,
        calendar: Calendar
    ) -> ScheduledTaskRow {
        ScheduledTaskRow(
            id: task.id,
            title: title(task),
            nextRunText: nextRunText(task, now: now, calendar: calendar),
            indicator: task.lastRun.map { ScheduledRunIndicator($0.status) },
            lastRunText: task.lastRun.map { ScheduledRunIndicator.statusText($0.status) },
            isExpanded: isExpanded
        )
    }

    private static func title(_ task: RemoteScheduledTask) -> String {
        let name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled task" : name
    }

    /// The next run as the Host published it. The instant is worded in this
    /// Mac's time zone; without one, the Host's local date-time is read as
    /// local here (the same unless the Host is in another zone).
    private static func nextRunText(_ task: RemoteScheduledTask, now: Date, calendar: Calendar) -> String {
        guard task.enabled else { return "Off" }
        guard let next = task.nextRun else { return "Not scheduled" }
        return nextRunDate(next, calendar: calendar)
            .map { ScheduledTimeText.relative($0, now: now, calendar: calendar) } ?? next.at
    }

    private static func nextRunDate(_ next: RemoteScheduledTask.NextRun, calendar: Calendar) -> Date? {
        next.atMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
            ?? ScheduledTimeText.localDateTime(next.at, calendar: calendar)
    }

    private static func runRow(
        _ run: RemoteScheduleRun,
        taskID: String,
        keptSessionIDs: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> ScheduledRunRow {
        let indicator = ScheduledRunIndicator(run.status)
        let scheduled = run.scheduledFor.map { raw in
            ScheduledTimeText.localDateTime(raw, calendar: calendar)
                .map { ScheduledTimeText.relative($0, now: now, calendar: calendar) } ?? raw
        }
        let started = run.startedAtMs.map { ms in
            ScheduledTimeText.relative(
                Date(timeIntervalSince1970: TimeInterval(ms) / 1000), now: now, calendar: calendar
            )
        }
        let explains = [.failed, .skipped, .unknown].contains(indicator)
        let detail = (explains ? [run.reason, run.snippet] : [run.snippet, run.reason])
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return ScheduledRunRow(
            id: run.runID,
            taskID: taskID,
            indicator: indicator,
            statusText: ScheduledRunIndicator.statusText(run.status),
            scheduledText: scheduled.map { "Scheduled \($0)" } ?? "Run now",
            startedText: started.map { "Started \($0)" },
            isLate: run.late,
            detail: detail,
            openableSessionID: run.sessionID.flatMap { keptSessionIDs.contains($0) ? $0 : nil }
        )
    }
}

/// Friendly times: "Today 09:43", "Tomorrow 09:43", "Tue 08:00",
/// "Nov 20 08:00", "Jan 4, 2027 07:00". Clock times are 24-hour, as
/// Triggers are written.
enum ScheduledTimeText {
    static func relative(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = format(date, "HH:mm", calendar: calendar)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch days {
        case 0: return "Today \(time)"
        case 1: return "Tomorrow \(time)"
        case -1: return "Yesterday \(time)"
        case -6...6: return "\(format(date, "EEE", calendar: calendar)) \(time)"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return "\(format(date, sameYear ? "MMM d" : "MMM d, yyyy", calendar: calendar)) \(time)"
        }
    }

    /// A Host local date-time, `YYYY-MM-DDTHH:MM[:SS]`, on `calendar`.
    static func localDateTime(_ text: String, calendar: Calendar) -> Date? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let day = halves[0].split(separator: "-").compactMap { Int($0) }
        let clock = halves[1].split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, (2...3).contains(clock.count) else { return nil }
        return calendar.date(from: DateComponents(
            year: day[0], month: day[1], day: day[2],
            hour: clock[0], minute: clock[1], second: clock.count == 3 ? clock[2] : 0
        ))
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale.current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
