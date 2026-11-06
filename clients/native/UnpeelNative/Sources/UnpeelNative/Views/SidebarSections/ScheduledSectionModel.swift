//
//  ScheduledSectionModel.swift
//  UnpeelNative
//
//  Fork-only: Scheduled Tasks. The SCHEDULED section's state: the selected
//  Host's tasks and the Runs of the expanded ones. It has no timer. It reads
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
            return nil
        }
        let next = Scope(id: scopeID, hostID: snapshot.macID)
        if next != scope { reset(to: next) }
        self.source = source
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
        clearRows()
        availability = .loading
    }

    private func clearRows() {
        tasks = []
        runsByTask = [:]
        runsRevision = [:]
        loadedRevision = nil
        requestedRevision = nil
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

extension RemoteHostRuntime: ScheduledTasksSource {
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
}
