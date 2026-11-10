import Foundation

// Fork-only: Scheduled Tasks. What a Host answers on `GET /mobile/schedules`
// (`RemoteControlProtocol.schedulesCapability`) and `GET /mobile/schedules/
// runs` (`scheduleRunsCapability`); `protocol/schedules-samples-v1.json`
// pins both bodies. Run status and Trigger kind are open sets: a newer
// Host's value decodes, and Controllers render it generically.

/// Every Scheduled Task of the Host's workspace, with its next run and its
/// latest Run.
public struct RemoteSchedulesList: Decodable, Equatable, Sendable {
    /// The bootstrap's `schedulesRevision` this answer was read at.
    public let revision: String?
    public let schedules: [RemoteScheduledTask]

    public init(revision: String?, schedules: [RemoteScheduledTask]) {
        self.revision = revision
        self.schedules = schedules
    }

    private enum CodingKeys: String, CodingKey { case revision, schedules }

    /// A task this Controller cannot read costs that task, never the list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        let rows = try container.decodeIfPresent([Lossy<RemoteScheduledTask>].self, forKey: .schedules)
        schedules = rows?.compactMap(\.value) ?? []
    }
}

public struct RemoteScheduledTask: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let projectID: String
    public let presetID: String
    public let trigger: RemoteScheduleTrigger
    public let enabled: Bool
    public let notifyWhenDone: Bool
    public let createdAtMs: Int64
    /// What each Run types into the agent; only an Agent Preset task has
    /// them.
    public let instructions: String?
    /// When the Host fires it next; nil while disabled, before the Host has
    /// stepped a new task, or for a Trigger it cannot fire.
    public let nextRun: NextRun?
    public let lastRun: RemoteScheduleRun?

    /// The next occurrence as the Host's local date-time
    /// (`2026-11-07T09:43`) and as an instant.
    public struct NextRun: Decodable, Equatable, Sendable {
        public let at: String
        public let atMs: Int64?

        public init(at: String, atMs: Int64?) {
            self.at = at
            self.atMs = atMs
        }
    }

    public init(
        id: String,
        name: String,
        projectID: String = "",
        presetID: String = "",
        trigger: RemoteScheduleTrigger = RemoteScheduleTrigger(kind: "unknown"),
        enabled: Bool = true,
        notifyWhenDone: Bool = true,
        createdAtMs: Int64 = 0,
        instructions: String? = nil,
        nextRun: NextRun? = nil,
        lastRun: RemoteScheduleRun? = nil
    ) {
        self.instructions = instructions
        self.id = id
        self.name = name
        self.projectID = projectID
        self.presetID = presetID
        self.trigger = trigger
        self.enabled = enabled
        self.notifyWhenDone = notifyWhenDone
        self.createdAtMs = createdAtMs
        self.nextRun = nextRun
        self.lastRun = lastRun
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, projectID, presetID, trigger, enabled, notifyWhenDone, createdAtMs, instructions
        case nextRun, lastRun
    }

    /// Only the id is required; the rest falls back the way the Host's own
    /// reader does (enabled and notify-when-done default on).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID) ?? ""
        trigger = (try? container.decodeIfPresent(RemoteScheduleTrigger.self, forKey: .trigger))
            ?? RemoteScheduleTrigger(kind: "unknown")
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notifyWhenDone = try container.decodeIfPresent(Bool.self, forKey: .notifyWhenDone) ?? true
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        instructions = try? container.decodeIfPresent(String.self, forKey: .instructions)
        nextRun = try? container.decodeIfPresent(NextRun.self, forKey: .nextRun)
        lastRun = try? container.decodeIfPresent(RemoteScheduleRun.self, forKey: .lastRun)
    }
}

/// When a task comes due. `kind` is an open set (`once`, `daily`, … and
/// `unknown` for one the Host cannot fire); the fields a kind uses are set,
/// and only those are encoded, the stored shape a write sends back.
public struct RemoteScheduleTrigger: Codable, Hashable, Sendable {
    public let kind: String
    /// `HH:MM[:SS]` for time-of-day kinds.
    public let time: String?
    /// `YYYY-MM-DDTHH:MM[:SS]` for `once`.
    public let at: String?
    public let minute: Int?
    public let weekday: String?
    public let expr: String?

    public init(
        kind: String,
        time: String? = nil,
        at: String? = nil,
        minute: Int? = nil,
        weekday: String? = nil,
        expr: String? = nil
    ) {
        self.kind = kind
        self.time = time
        self.at = at
        self.minute = minute
        self.weekday = weekday
        self.expr = expr
    }
}

/// One Run of a task: an occurrence that started a Session, was skipped,
/// or failed before it could start.
public struct RemoteScheduleRun: Decodable, Equatable, Sendable, Identifiable {
    public let runID: String
    /// The occurrence it ran for, as the Host's local date-time; nil for
    /// Run now.
    public let scheduledFor: String?
    public let startedAtMs: Int64?
    public let endedAtMs: Int64?
    public let status: RemoteScheduleRunStatus
    /// Started more than 2 minutes after its occurrence.
    public let late: Bool
    /// The Run's Session; it may since have been removed.
    public let sessionID: String?
    public let exitCode: Int?
    public let reason: String?
    public let snippet: String?
    /// The Run's own Session's last report (#81); nil until it sends one,
    /// and from an older Host.
    public let report: RemoteScheduleRunReport?
    /// The Host's word that the Run needs the user (#81): its report is
    /// `blocked` and it has not failed. Shown so whatever its status; false
    /// from an older Host.
    public let needsAttention: Bool

    public var id: String { runID }

    public init(
        runID: String,
        scheduledFor: String? = nil,
        startedAtMs: Int64? = nil,
        endedAtMs: Int64? = nil,
        status: RemoteScheduleRunStatus,
        late: Bool = false,
        sessionID: String? = nil,
        exitCode: Int? = nil,
        reason: String? = nil,
        snippet: String? = nil,
        report: RemoteScheduleRunReport? = nil,
        needsAttention: Bool = false
    ) {
        self.runID = runID
        self.scheduledFor = scheduledFor
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.status = status
        self.late = late
        self.sessionID = sessionID
        self.exitCode = exitCode
        self.reason = reason
        self.snippet = snippet
        self.report = report
        self.needsAttention = needsAttention
    }

    private enum CodingKeys: String, CodingKey {
        case runID, scheduledFor, startedAtMs, endedAtMs, status, late, sessionID, exitCode, reason, snippet
        case report, needsAttention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        scheduledFor = try container.decodeIfPresent(String.self, forKey: .scheduledFor)
        startedAtMs = try container.decodeIfPresent(Int64.self, forKey: .startedAtMs)
        endedAtMs = try container.decodeIfPresent(Int64.self, forKey: .endedAtMs)
        status = try container.decodeIfPresent(RemoteScheduleRunStatus.self, forKey: .status)
            ?? .other("unknown")
        late = try container.decodeIfPresent(Bool.self, forKey: .late) ?? false
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet)
        report = try? container.decodeIfPresent(RemoteScheduleRunReport.self, forKey: .report)
        needsAttention = try container.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
    }
}

/// What a Run's own agent last said came of it: its Session's
/// `sessions report` during the Run. `status` is an open set (`done`,
/// `blocked`, `update`, `progress` today); whether the Run needs attention
/// is the Host's `RemoteScheduleRun.needsAttention`, never read from it.
public struct RemoteScheduleRunReport: Decodable, Equatable, Sendable {
    public let status: String
    public let summary: String
    public let atMs: Int64?

    public init(status: String, summary: String, atMs: Int64? = nil) {
        self.status = status
        self.summary = summary
        self.atMs = atMs
    }
}

/// What came of a Run, as the Host words it. A word this Controller does
/// not know is `.other`, never a decoding failure.
public enum RemoteScheduleRunStatus: Equatable, Hashable, Sendable, Decodable {
    case running
    case done
    case needsYou
    case failedToStart
    case failed
    case skipped
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "running": self = .running
        case "done": self = .done
        case "needs_you": self = .needsYou
        case "failed_to_start": self = .failedToStart
        case "failed": self = .failed
        case "skipped": self = .skipped
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .running: return "running"
        case .done: return "done"
        case .needsYou: return "needs_you"
        case .failedToStart: return "failed_to_start"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .other(let word): return word
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
}

/// A task's Run history, newest first.
public struct RemoteScheduleRunHistory: Decodable, Equatable, Sendable {
    public let scheduleID: String
    public let runs: [RemoteScheduleRun]

    public init(scheduleID: String, runs: [RemoteScheduleRun]) {
        self.scheduleID = scheduleID
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey { case scheduleID, runs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scheduleID = try container.decode(String.self, forKey: .scheduleID)
        let rows = try container.decodeIfPresent([Lossy<RemoteScheduleRun>].self, forKey: .runs)
        runs = rows?.compactMap(\.value) ?? []
    }

    /// The query of `GET /mobile/schedules/runs`: the newest `limit` Runs
    /// of one task (all it keeps when nil).
    public static func query(scheduleID: String, limit: Int?) -> [String: String] {
        var query = ["scheduleID": scheduleID]
        if let limit { query["limit"] = String(limit) }
        return query
    }
}

/// One element of a list that decodes on its own.
private struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
