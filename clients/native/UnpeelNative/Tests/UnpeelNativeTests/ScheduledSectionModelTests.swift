import Foundation
import Testing
import UnpeelShared
@testable import UnpeelNative

/// Fork-only: Scheduled Tasks. The SCHEDULED section from the Host's DTOs:
/// its rows, their status dots and friendly times, the expand-to-Runs
/// model, and when it reads the Host (only when the revision moves).
@MainActor
struct ScheduledSectionModelTests {
    // MARK: Rows

    @Test
    func rowsShowNameNextRunAndTheLastRunsDot() {
        let items = ScheduledSectionRows.resolve(
            tasks: [
                task("sch_a", "Morning briefing", next: at(7, 9, 43), last: .done),
                task("sch_b", "", next: nil, last: nil),
                task("sch_c", "Backup", enabled: false, next: nil, last: .failedToStart),
            ],
            runs: [:], expanded: [], keptSessionIDs: [], now: at(6, 22, 10), calendar: calendar
        )
        #expect(items.map(\.id) == ["task:sch_a", "task:sch_b", "task:sch_c"])
        let rows = items.compactMap(\.taskRow)
        #expect(rows.map(\.title) == ["Morning briefing", "Untitled task", "Backup"])
        #expect(rows.map(\.nextRunText) == ["Tomorrow 09:43", "Not scheduled", "Off"])
        #expect(rows.map(\.indicator) == [.done, nil, .failed])
        #expect(rows.allSatisfy { !$0.isExpanded })
    }

    @Test
    func everyRunStatusHasADotAndAWord() {
        let statuses: [RemoteScheduleRunStatus] = [
            .running, .done, .needsYou, .failed, .failedToStart, .skipped, .other("paused_forever"),
        ]
        #expect(statuses.map(ScheduledRunIndicator.init) == [
            .running, .done, .needsYou, .failed, .failed, .skipped, .unknown,
        ])
        #expect(statuses.map(ScheduledRunIndicator.statusText) == [
            "Running", "Done", "Needs you", "Failed", "Failed to start", "Skipped", "paused_forever",
        ])
    }

    @Test
    func anExpandedRowListsItsRunsUnderItWithTimesLateAndSnippet() {
        let runs = [
            RemoteScheduleRun(
                runID: "run_new", scheduledFor: nil, startedAtMs: ms(at(6, 21, 5)),
                status: .failed, reason: "the command exited with status 3"
            ),
            RemoteScheduleRun(
                runID: "run_old", scheduledFor: "2026-11-05T09:43", startedAtMs: ms(at(5, 9, 50)),
                status: .done, late: true, sessionID: "kept", snippet: "Briefing ready."
            ),
            RemoteScheduleRun(
                runID: "run_gone", scheduledFor: "2026-11-04T09:43:30", startedAtMs: nil,
                status: .skipped, sessionID: "removed", reason: "still in progress"
            ),
        ]
        let items = ScheduledSectionRows.resolve(
            tasks: [task("sch_a", "Morning", next: at(7, 9, 43), last: .failed), task("sch_b", "Other")],
            runs: ["sch_a": runs], expanded: ["sch_a"], keptSessionIDs: ["kept"],
            now: at(6, 22, 10), calendar: calendar
        )
        #expect(items.map(\.id) == ["task:sch_a", "run:run_new", "run:run_old", "run:run_gone", "task:sch_b"])
        #expect(items.first?.taskRow?.isExpanded == true)
        let rows = items.compactMap(\.runRow)
        #expect(rows.map(\.scheduledText) == ["Run now", "Scheduled Yesterday 09:43", "Scheduled Wed 09:43"])
        #expect(rows.map(\.startedText) == ["Started Today 21:05", "Started Yesterday 09:50", nil])
        #expect(rows.map(\.isLate) == [false, true, false])
        #expect(rows.map(\.detail) == ["the command exited with status 3", "Briefing ready.", "still in progress"])
        // A Run opens its Session only while the Host still keeps it.
        #expect(rows.map(\.openableSessionID) == [nil, "kept", nil])
        #expect(rows.allSatisfy { $0.taskID == "sch_a" })
    }

    @Test
    func anExpandedRowWithoutItsRunsYetSaysSoAndOneWithNoneSaysThat() {
        let items = ScheduledSectionRows.resolve(
            tasks: [task("sch_a", "A"), task("sch_b", "B")],
            runs: ["sch_b": []], expanded: ["sch_a", "sch_b", "sch_gone"], keptSessionIDs: [],
            now: at(6, 9, 0), calendar: calendar
        )
        #expect(items.map(\.id) == ["task:sch_a", "loading:sch_a", "task:sch_b", "empty:sch_b"])
    }

    @Test
    func nextRunTextIsFriendlyRelativeToNow() {
        let now = at(6, 22, 10)
        let text = { (date: Date) in ScheduledTimeText.relative(date, now: now, calendar: calendar) }
        #expect(text(at(6, 23, 0)) == "Today 23:00")
        #expect(text(at(7, 9, 43)) == "Tomorrow 09:43")
        #expect(text(at(5, 9, 43)) == "Yesterday 09:43")
        #expect(text(at(10, 8, 0)) == "Tue 08:00")
        #expect(text(at(20, 8, 0)) == "Nov 20 08:00")
        let nextYear = calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: 7))!
        #expect(text(nextYear) == "Jan 4, 2027 07:00")
        // The Host's local date-time, read on this calendar.
        #expect(ScheduledTimeText.localDateTime("2026-11-07T09:43", calendar: calendar) == at(7, 9, 43))
        #expect(ScheduledTimeText.localDateTime("2026-11-07T09:43:30", calendar: calendar)
            == at(7, 9, 43).addingTimeInterval(30))
        #expect(ScheduledTimeText.localDateTime("tomorrow", calendar: calendar) == nil)
    }

    @Test
    func aNextRunWithoutAnInstantFallsBackToTheHostsLocalTime() {
        let row = ScheduledSectionRows.resolve(
            tasks: [RemoteScheduledTask(
                id: "sch_a", name: "A",
                nextRun: .init(at: "2026-11-07T09:43", atMs: nil)
            )],
            runs: [:], expanded: [], keptSessionIDs: [], now: at(6, 22, 10), calendar: calendar
        ).first?.taskRow
        #expect(row?.nextRunText == "Tomorrow 09:43")
    }

    // MARK: Reading the Host

    /// The runtime republishes its snapshot only when content changes; a
    /// moved revision must count, or the section would never reread.
    @Test
    func aMovedRevisionIsANewSnapshot() {
        #expect(!RemoteHostRuntime.snapshotContentEqual(snapshot(revision: "r1"), snapshot(revision: "r2")))
        #expect(RemoteHostRuntime.snapshotContentEqual(snapshot(revision: "r1"), snapshot(revision: "r1")))
    }

    @Test
    func itReadsTheHostOnlyWhenTheRevisionMoves() async {
        let source = FakeSchedulesSource(list: [task("sch_a", "A")])
        let model = ScheduledSectionModel()
        model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: source)
        await model.settle()
        #expect(model.tasks.map(\.id) == ["sch_a"])
        #expect(model.availability == .ready)
        #expect(source.listCalls == 1)

        model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: source)
        await model.settle()
        #expect(source.listCalls == 1, "the same revision is not read again")

        source.list = [task("sch_a", "A"), task("sch_b", "B")]
        model.update(snapshot: snapshot(revision: "r2"), scopeID: "local", source: source)
        await model.settle()
        #expect(source.listCalls == 2)
        #expect(model.tasks.map(\.id) == ["sch_a", "sch_b"])
    }

    @Test
    func expandingReadsTheTasksRunsAndARevisionRereadsThem() async {
        let source = FakeSchedulesSource(list: [task("sch_a", "A")])
        source.runs = ["sch_a": [RemoteScheduleRun(runID: "run_1", status: .running)]]
        let model = ScheduledSectionModel()
        model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: source)
        await model.settle()
        #expect(source.runCalls.isEmpty, "a collapsed row reads no history")

        model.toggleExpanded("sch_a")
        await model.settle()
        #expect(model.expanded == ["sch_a"])
        #expect(model.runsByTask["sch_a"]?.map(\.runID) == ["run_1"])
        #expect(source.runCalls == ["sch_a"])

        source.runs = ["sch_a": [
            RemoteScheduleRun(runID: "run_1", status: .done),
        ]]
        model.update(snapshot: snapshot(revision: "r2"), scopeID: "local", source: source)
        await model.settle()
        #expect(model.runsByTask["sch_a"]?.map(\.status) == [.done])
        #expect(source.runCalls == ["sch_a", "sch_a"])

        model.toggleExpanded("sch_a")
        #expect(model.expanded.isEmpty)
    }

    @Test
    func anotherHostClearsTheRowsAndALateAnswerFromTheOldOneIsDropped() async {
        let slow = FakeSchedulesSource(list: [task("sch_old", "Old Host")])
        slow.holdList = true
        let model = ScheduledSectionModel()
        let late = model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: slow)
        await slow.waitUntilHeld()

        let other = FakeSchedulesSource(list: [task("sch_new", "New Host")])
        let current = model.update(
            snapshot: snapshot(revision: "r1", macID: "host-2"), scopeID: "remote:host-2", source: other
        )
        await current?.value
        #expect(model.tasks.map(\.id) == ["sch_new"])
        // The first Host answers only now; its answer must not land.
        slow.release()
        await late?.value
        #expect(model.tasks.map(\.id) == ["sch_new"])
        #expect(model.availability == .ready)

        model.update(snapshot: nil, scopeID: "remote:host-2", source: other)
        #expect(model.tasks.isEmpty)
        #expect(model.availability == .loading)
    }

    @Test
    func aHostWithoutTheCapabilityIsUnsupportedAndNeverRead() async {
        let source = FakeSchedulesSource(list: [task("sch_a", "A")])
        let model = ScheduledSectionModel()
        model.update(snapshot: snapshot(revision: nil, capabilities: []), scopeID: "local", source: source)
        await model.settle()
        #expect(model.availability == .unsupported)
        #expect(source.listCalls == 0)
    }

    @Test
    func aFailedReadKeepsTheRowsItHadAndSaysWhy() async {
        let source = FakeSchedulesSource(list: [task("sch_a", "A")])
        let model = ScheduledSectionModel()
        model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: source)
        await model.settle()
        source.failure = "The Host is not connected."
        model.update(snapshot: snapshot(revision: "r2"), scopeID: "local", source: source)
        await model.settle()
        #expect(model.tasks.map(\.id) == ["sch_a"])
        #expect(model.availability == .failed("The Host is not connected."))

        source.failure = nil
        model.update(snapshot: snapshot(revision: "r2"), scopeID: "local", source: source)
        await model.settle()
        #expect(model.availability == .ready, "a failed revision is read again")
    }

    // MARK: Managing tasks

    @Test
    func theWritesOnOfferAreTheOnesTheHostAdvertises() {
        let all = ScheduledTaskWrites(protocol: RemoteHostProtocolDescriptor(capabilities: [
            RemoteControlProtocol.schedulesCreateCapability, RemoteControlProtocol.schedulesEditCapability,
            RemoteControlProtocol.schedulesDeleteCapability, RemoteControlProtocol.schedulesRunCapability,
        ]))
        #expect(all.create && all.edit && all.delete && all.run)
        let readOnly = ScheduledTaskWrites(protocol: RemoteHostProtocolDescriptor(capabilities: [
            RemoteControlProtocol.schedulesCapability,
        ]))
        #expect(!readOnly.create && !readOnly.edit && !readOnly.delete && !readOnly.run)
        #expect(ScheduledTaskWrites(protocol: nil) == readOnly)

        let model = ScheduledSectionModel()
        let source = FakeSchedulesSource(list: [])
        model.update(snapshot: snapshot(revision: "r1", capabilities: [
            RemoteControlProtocol.schedulesCapability, RemoteControlProtocol.schedulesRunCapability,
        ]), scopeID: "local", source: source)
        #expect(model.writes.run && !model.writes.create, "the model follows the selected Host")
        model.update(snapshot: nil, scopeID: "local", source: source)
        #expect(model.writes == readOnly)
    }

    @Test
    func theSheetOpensBlankFromPlusAndFilledFromARow() {
        let model = ScheduledSectionModel()
        model.openNewTask()
        #expect(model.editing == ScheduledTaskEditing(task: nil))
        let row = task("sch_a", "A")
        model.openEditor(for: row)
        #expect(model.editing?.task == row)
        model.closeEditor()
        #expect(model.editing == nil)
    }

    @Test
    func deleteAsksInlineThenDeletesAndLeavesNoConfirmationBehind() async {
        let source = FakeSchedulesSource(list: [task("sch_a", "A"), task("sch_b", "B")])
        let writer = FakeSchedulesWriter()
        let model = ScheduledSectionModel()
        model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: source)
        await model.settle()

        model.requestDelete("sch_a")
        #expect(model.confirmingDeleteTaskID == "sch_a")
        model.cancelDelete()
        #expect(model.confirmingDeleteTaskID == nil)
        #expect(writer.calls.isEmpty, "cancel deletes nothing")

        model.requestDelete("sch_a")
        await model.confirmDelete("sch_a", writer: writer).value
        #expect(writer.calls == ["delete sch_a"])
        #expect(model.confirmingDeleteTaskID == nil)
        #expect(model.actionError == nil)
    }

    @Test
    func aConfirmationEndsWhenItsTaskLeavesTheList() async {
        let source = FakeSchedulesSource(list: [task("sch_a", "A")])
        let model = ScheduledSectionModel()
        model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: source)
        await model.settle()
        model.requestDelete("sch_a")
        source.list = []
        model.update(snapshot: snapshot(revision: "r2"), scopeID: "local", source: source)
        await model.settle()
        #expect(model.confirmingDeleteTaskID == nil)
    }

    @Test
    func rowActionsSendTheirWritesAndAHostRefusalSaysWhy() async {
        let source = FakeSchedulesSource(list: [task("sch_a", "A")])
        let writer = FakeSchedulesWriter()
        let model = ScheduledSectionModel()
        model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: source)
        await model.settle()
        let row = RemoteScheduledTask(
            id: "sch_a", name: "A", projectID: "p", presetID: "ok",
            trigger: RemoteScheduleTrigger(kind: "daily", time: "09:00")
        )

        await model.setPaused(row, true, writer: writer).value
        await model.setPaused(row, false, writer: writer).value
        await model.duplicate(row, writer: writer).value
        await model.runNow("sch_a", writer: writer).value
        #expect(writer.calls == [
            "edit sch_a enabled=false", "edit sch_a enabled=true", "create A copy", "run sch_a",
        ])
        #expect(model.actionError == nil)

        writer.failure = "Host resource was not sent: Host Host resource returned 409: a Run of A is still in progress"
        await model.runNow("sch_a", writer: writer).value
        #expect(model.actionError == "A Run of this task is still in progress. Try again once it finishes.")
        writer.failure = nil
        await model.runNow("sch_a", writer: writer).value
        #expect(model.actionError == nil, "a later success clears it")
    }

    @Test
    func anotherHostEndsTheSheetAndTheConfirmation() async {
        let source = FakeSchedulesSource(list: [task("sch_a", "A")])
        let model = ScheduledSectionModel()
        model.update(snapshot: snapshot(revision: "r1"), scopeID: "local", source: source)
        await model.settle()
        model.requestDelete("sch_a")
        model.openEditor(for: task("sch_a", "A"))
        model.update(snapshot: snapshot(revision: "r1", macID: "host-2"), scopeID: "remote:host-2", source: source)
        #expect(model.confirmingDeleteTaskID == nil)
        #expect(model.editing == nil)
    }

    // MARK: Fixtures

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// 2026-11-<day> <hour>:<minute> in the test calendar's zone.
    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func task(
        _ id: String,
        _ name: String,
        enabled: Bool = true,
        next: Date? = nil,
        last: RemoteScheduleRunStatus? = nil
    ) -> RemoteScheduledTask {
        RemoteScheduledTask(
            id: id, name: name, enabled: enabled,
            nextRun: next.map { .init(at: "unused", atMs: ms($0)) },
            lastRun: last.map { RemoteScheduleRun(runID: "\(id)-last", status: $0) }
        )
    }

    private func snapshot(
        revision: String?,
        macID: String = "host-1",
        capabilities: [String] = [
            RemoteControlProtocol.schedulesCapability, RemoteControlProtocol.scheduleRunsCapability,
        ]
    ) -> RemoteBootstrapSnapshot {
        RemoteBootstrapSnapshot(
            hostProtocol: RemoteHostProtocolDescriptor(capabilities: capabilities),
            macID: macID, folders: [], projects: [], presets: [], sessions: [],
            capturedAtUnixMs: 1, schedulesRevision: revision
        )
    }
}

/// The Host's two read routes, scripted.
@MainActor
private final class FakeSchedulesSource: ScheduledTasksSource {
    var list: [RemoteScheduledTask]
    var runs: [String: [RemoteScheduleRun]] = [:]
    var failure: String?
    var holdList = false
    private(set) var listCalls = 0
    private(set) var runCalls: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    init(list: [RemoteScheduledTask]) { self.list = list }

    func release() {
        holdList = false
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func waitUntilHeld() async {
        while held.isEmpty { await Task.yield() }
    }

    func scheduledTasks() async throws -> RemoteSchedulesList {
        listCalls += 1
        let answer = list
        if holdList { await withCheckedContinuation { held.append($0) } }
        if let failure { throw ScheduledTasksReadError(message: failure) }
        return RemoteSchedulesList(revision: nil, schedules: answer)
    }

    func scheduleRuns(scheduleID: String, limit: Int?) async throws -> RemoteScheduleRunHistory {
        runCalls.append(scheduleID)
        if let failure { throw ScheduledTasksReadError(message: failure) }
        return RemoteScheduleRunHistory(scheduleID: scheduleID, runs: runs[scheduleID] ?? [])
    }
}

/// The Host's write routes, scripted: each call is recorded in words.
@MainActor
private final class FakeSchedulesWriter: ScheduledTasksWriter {
    var failure: String?
    private(set) var calls: [String] = []

    func createSchedule(_ request: RemoteScheduleCreate) async throws -> RemoteScheduledTask {
        calls.append("create \(request.name)")
        try fail()
        return RemoteScheduledTask(id: "sch_new", name: request.name)
    }

    func editSchedule(_ request: RemoteScheduleEdit) async throws -> RemoteScheduledTask {
        calls.append("edit \(request.scheduleID)" + (request.enabled.map { " enabled=\($0)" } ?? ""))
        try fail()
        return RemoteScheduledTask(id: request.scheduleID, name: request.name ?? "")
    }

    func deleteSchedule(id: String) async throws {
        calls.append("delete \(id)")
        try fail()
    }

    func runScheduleNow(id: String) async throws -> String {
        calls.append("run \(id)")
        try fail()
        return "run_new"
    }

    private func fail() throws {
        if let failure { throw ScheduledTasksReadError(message: failure) }
    }
}

private struct ScheduledTasksReadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
