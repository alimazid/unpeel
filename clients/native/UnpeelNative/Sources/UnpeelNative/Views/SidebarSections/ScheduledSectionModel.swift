//
//  ScheduledSectionModel.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. The SCHEDULED section's state: the selected
//  Host's tasks, the Runs of the expanded ones, and the user's edits (the
//  sheet, a row's inline Delete confirmation, row actions and the Host's
//  refusal of one). It has no timer. It reads
//  the Host's `schedules` routes only when the bootstrap's
//  `schedulesRevision` moves, which happens on the bootstrap refresh and
//  state-bus wakes the runtime already has; the same runtime serves Local
//  and remote Hosts, so remote scope needs nothing of its own. Kept out of
//  `UnpeelStore`, like the other section models.
//

import Foundation
import UnpeelShared

/// The Host's two read routes (`RemoteHostRuntime` in the app).
@MainActor
protocol ScheduledTasksSource: AnyObject, Sendable {
    func scheduledTasks() async throws -> RemoteSchedulesList
    func scheduleRuns(scheduleID: String, limit: Int?) async throws -> RemoteScheduleRunHistory
}

/// The Host's write routes (`RemoteHostRuntime` in the app). A refusal is
/// thrown as the bridge words it; `ScheduledTaskErrorText` rewords it.
@MainActor
protocol ScheduledTasksWriter: AnyObject {
    func createSchedule(_ request: RemoteScheduleCreate) async throws -> RemoteScheduledTask
    func editSchedule(_ request: RemoteScheduleEdit) async throws -> RemoteScheduledTask
    func deleteSchedule(id: String) async throws
    func runScheduleNow(id: String) async throws -> String
}

/// Which writes the selected Host serves; a Host that predates them shows
/// its tasks read-only.
struct ScheduledTaskWrites: Equatable, Sendable {
    let create: Bool
    let edit: Bool
    let delete: Bool
    let run: Bool

    init(protocol descriptor: RemoteHostProtocolDescriptor?) {
        let supports = { (id: String) in descriptor?.supports(id) == true }
        create = supports(RemoteControlProtocol.schedulesCreateCapability)
        edit = supports(RemoteControlProtocol.schedulesEditCapability)
        delete = supports(RemoteControlProtocol.schedulesDeleteCapability)
        run = supports(RemoteControlProtocol.schedulesRunCapability)
    }
}

/// The edit sheet's subject: a new task (`task == nil`) or one from the list.
struct ScheduledTaskEditing: Identifiable, Equatable, Sendable {
    let task: RemoteScheduledTask?

    var id: String { task?.id ?? "new" }
}

@MainActor
final class ScheduledSectionModel: ObservableObject {
    enum Availability: Equatable, Sendable {
        /// Connecting, or the first read is in flight.
        case loading
        case ready
        /// The Host does not advertise `schedules`.
        case unsupported
        /// The last read failed; the rows from before it stay.
        case failed(String)
    }

    /// Recent Runs an expanded row lists.
    static let runsLimit = 10

    @Published private(set) var tasks: [RemoteScheduledTask] = []
    @Published private(set) var runsByTask: [String: [RemoteScheduleRun]] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var availability: Availability = .loading
    /// The sheet, while it is open.
    @Published private(set) var editing: ScheduledTaskEditing?
    /// The row asking "Delete …?" inline, like an AGENTS row.
    @Published private(set) var confirmingDeleteTaskID: String?
    /// Why the last row action was refused; cleared by the next success.
    @Published private(set) var actionError: String?
    /// The writes the selected Host serves (its menu, "+" and row click).
    @Published private(set) var writes = ScheduledTaskWrites(protocol: nil)

    /// Which Host the rows came from: the pane scope plus the Host's id.
    private struct Scope: Equatable {
        let id: String
        let hostID: String?
    }

    private var scope: Scope?
    private var source: (any ScheduledTasksSource)?
    private var loadedRevision: String?
    private var requestedRevision: String?
    /// The revision each task's Runs were read at.
    private var runsRevision: [String: String] = [:]
    /// Bumped when the Host changes, so an answer from before is dropped.
    private var generation = 0
    private var loads: [Int: Task<Void, Never>] = [:]
    private var nextLoadID = 0

    /// Follow the selected Host's bootstrap. Returns the read it started,
    /// if the revision moved.
    @discardableResult
    func update(
        snapshot: RemoteBootstrapSnapshot?,
        scopeID: String,
        source: any ScheduledTasksSource
    ) -> Task<Void, Never>? {
        guard let snapshot else {
            reset(to: nil)
            setWrites(ScheduledTaskWrites(protocol: nil))
            return nil
        }
        let next = Scope(id: scopeID, hostID: snapshot.macID)
        if next != scope { reset(to: next) }
        self.source = source
        setWrites(ScheduledTaskWrites(protocol: snapshot.hostProtocol))
        guard snapshot.hostProtocol?.supports(RemoteControlProtocol.schedulesCapability) == true else {
            clearRows()
            availability = .unsupported
            return nil
        }
        let revision = snapshot.schedulesRevision ?? ""
        guard revision != loadedRevision, revision != requestedRevision else { return nil }
        return loadList(revision: revision)
    }

    /// Expand a task into its recent Runs, reading them if the ones held
    /// are from an older revision; or collapse it.
    @discardableResult
    func toggleExpanded(_ taskID: String) -> Task<Void, Never>? {
        if expanded.contains(taskID) {
            expanded.remove(taskID)
            return nil
        }
        expanded.insert(taskID)
        guard let revision = loadedRevision, runsRevision[taskID] != revision else { return nil }
        let generation = self.generation
        return track { [weak self] in
            await self?.loadRuns(of: [taskID], revision: revision, generation: generation)
        }
    }

    /// Waits for every read in flight (tests).
    func settle() async {
        while let load = loads.values.first {
            await load.value
        }
    }

    // MARK: - Reads

    private func loadList(revision: String) -> Task<Void, Never> {
        requestedRevision = revision
        let generation = self.generation
        return track { [weak self] in
            await self?.readList(revision: revision, generation: generation)
        }
    }

    private func readList(revision: String, generation: Int) async {
        guard let source else { return }
        do {
            let list = try await source.scheduledTasks()
            guard generation == self.generation else { return }
            apply(list, revision: revision)
            await loadRuns(of: Array(expanded), revision: revision, generation: generation)
        } catch {
            guard generation == self.generation else { return }
            requestedRevision = nil
            if !(error is CancellationError) { availability = .failed(Self.message(for: error)) }
        }
    }

    private func loadRuns(of taskIDs: [String], revision: String, generation: Int) async {
        guard let source else { return }
        let listed = Set(tasks.map(\.id))
        for taskID in taskIDs.sorted() where listed.contains(taskID) {
            do {
                let history = try await source.scheduleRuns(scheduleID: taskID, limit: Self.runsLimit)
                guard generation == self.generation else { return }
                runsByTask[taskID] = history.runs
                runsRevision[taskID] = revision
            } catch {
                guard generation == self.generation else { return }
                if !(error is CancellationError) { availability = .failed(Self.message(for: error)) }
            }
        }
    }

    private func apply(_ list: RemoteSchedulesList, revision: String) {
        tasks = list.schedules
        let listed = Set(list.schedules.map(\.id))
        if let confirming = confirmingDeleteTaskID, !listed.contains(confirming) {
            confirmingDeleteTaskID = nil
        }
        runsByTask = runsByTask.filter { listed.contains($0.key) }
        runsRevision = runsRevision.filter { listed.contains($0.key) }
        loadedRevision = revision
        requestedRevision = nil
        availability = .ready
    }

    // MARK: - Host changes

    private func reset(to next: Scope?) {
        scope = next
        generation += 1
        expanded = []
        editing = nil
        confirmingDeleteTaskID = nil
        actionError = nil
        clearRows()
        availability = .loading
    }

    private func setWrites(_ next: ScheduledTaskWrites) {
        if next != writes { writes = next }
    }

    private func clearRows() {
        tasks = []
        runsByTask = [:]
        runsRevision = [:]
        loadedRevision = nil
        requestedRevision = nil
    }

    // MARK: - The user's edits

    func openNewTask() {
        editing = ScheduledTaskEditing(task: nil)
    }

    func openEditor(for task: RemoteScheduledTask) {
        confirmingDeleteTaskID = nil
        editing = ScheduledTaskEditing(task: task)
    }

    func closeEditor() {
        editing = nil
    }

    func requestDelete(_ taskID: String) {
        confirmingDeleteTaskID = taskID
    }

    func cancelDelete() {
        confirmingDeleteTaskID = nil
    }

    /// Delete the task and its history; its Run Sessions stay.
    @discardableResult
    func confirmDelete(_ taskID: String, writer: any ScheduledTasksWriter) -> Task<Void, Never> {
        confirmingDeleteTaskID = nil
        return perform { try await writer.deleteSchedule(id: taskID) }
    }

    @discardableResult
    func runNow(_ taskID: String, writer: any ScheduledTasksWriter) -> Task<Void, Never> {
        perform { _ = try await writer.runScheduleNow(id: taskID) }
    }

    /// Pause (`true`) or Resume (`false`): the task's `enabled`.
    @discardableResult
    func setPaused(_ task: RemoteScheduledTask, _ paused: Bool, writer: any ScheduledTasksWriter) -> Task<Void, Never> {
        perform { _ = try await writer.editSchedule(RemoteScheduleEdit(scheduleID: task.id, enabled: !paused)) }
    }

    /// A copy with every setting, named "<name> copy".
    @discardableResult
    func duplicate(_ task: RemoteScheduledTask, writer: any ScheduledTasksWriter) -> Task<Void, Never> {
        perform { _ = try await writer.createSchedule(ScheduledTaskForm.duplicateRequest(of: task)) }
    }

    /// One row action. The list itself refreshes from the bootstrap
    /// revision the write moves; only a refusal is kept here, for the
    /// Host it was made on.
    private func perform(_ write: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let generation = self.generation
        return track { [weak self] in
            do {
                try await write()
                guard let self, generation == self.generation else { return }
                self.actionError = nil
            } catch {
                guard let self, generation == self.generation, !(error is CancellationError) else { return }
                self.actionError = ScheduledTaskErrorText.message(for: error)
            }
        }
    }

    private func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        nextLoadID += 1
        let id = nextLoadID
        let task = Task { [weak self] in
            await body()
            self?.loads[id] = nil
        }
        loads[id] = task
        return task
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - The Host

extension RemoteHostRuntime: ScheduledTasksSource, ScheduledTasksWriter {
    func scheduledTasks() async throws -> RemoteSchedulesList {
        let data = try await resourceRequest(
            operation: "schedules",
            capability: RemoteControlProtocol.schedulesCapability,
            parameters: [:]
        )
        return try JSONDecoder().decode(RemoteSchedulesList.self, from: data)
    }

    func scheduleRuns(scheduleID: String, limit: Int?) async throws -> RemoteScheduleRunHistory {
        let data = try await resourceRequest(
            operation: "scheduleRuns",
            capability: RemoteControlProtocol.scheduleRunsCapability,
            parameters: RemoteScheduleRunHistory.query(scheduleID: scheduleID, limit: limit)
        )
        return try JSONDecoder().decode(RemoteScheduleRunHistory.self, from: data)
    }

    func createSchedule(_ request: RemoteScheduleCreate) async throws -> RemoteScheduledTask {
        let data = try await scheduleWrite("createSchedule", RemoteControlProtocol.schedulesCreateCapability, request)
        return try JSONDecoder().decode(RemoteScheduleSaved.self, from: data).schedule
    }

    func editSchedule(_ request: RemoteScheduleEdit) async throws -> RemoteScheduledTask {
        let data = try await scheduleWrite("editSchedule", RemoteControlProtocol.schedulesEditCapability, request)
        return try JSONDecoder().decode(RemoteScheduleSaved.self, from: data).schedule
    }

    func deleteSchedule(id: String) async throws {
        _ = try await scheduleWrite(
            "deleteSchedule", RemoteControlProtocol.schedulesDeleteCapability, RemoteScheduleTarget(scheduleID: id)
        )
    }

    func runScheduleNow(id: String) async throws -> String {
        let data = try await scheduleWrite(
            "runSchedule", RemoteControlProtocol.schedulesRunCapability, RemoteScheduleTarget(scheduleID: id)
        )
        return try JSONDecoder().decode(RemoteScheduleRunStarted.self, from: data).runID
    }

    /// One write with its JSON body. A remote Host has no state-bus wake
    /// for this Mac, so the bootstrap is reread at once: its
    /// `schedulesRevision` moves and the section rereads the list.
    private func scheduleWrite(_ operation: String, _ capability: String, _ body: some Encodable) async throws -> Data {
        let data = try await resourceRequest(
            operation: operation,
            capability: capability,
            parameters: [:],
            bytes: try JSONEncoder().encode(body)
        )
        requestImmediateRefresh()
        return data
    }
}
