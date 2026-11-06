import Foundation

// Fork-only: Scheduled Tasks. The bodies of the user's writes
// (`RemoteControlProtocol.schedulesCreateCapability` and its siblings) and
// what the Host answers. Fields a write leaves nil are not sent, so an edit
// changes only what it names; `protocol/host-conformance-v1.json` holds the
// bodies the Host's own tests send.

/// `POST /mobile/schedules`: a new task.
public struct RemoteScheduleCreate: Encodable, Equatable, Sendable {
    public let name: String
    public let projectID: String
    public let presetID: String
    public let trigger: RemoteScheduleTrigger
    /// Only for an Agent Preset; nil sends none.
    public let instructions: String?
    public let enabled: Bool
    public let notifyWhenDone: Bool

    public init(
        name: String,
        projectID: String,
        presetID: String,
        trigger: RemoteScheduleTrigger,
        instructions: String?,
        enabled: Bool,
        notifyWhenDone: Bool
    ) {
        self.name = name
        self.projectID = projectID
        self.presetID = presetID
        self.trigger = trigger
        self.instructions = instructions
        self.enabled = enabled
        self.notifyWhenDone = notifyWhenDone
    }
}

/// `POST /mobile/schedules/edit`: change the fields that are set. Pausing
/// is `enabled: false`, resuming `true`; empty `instructions` removes them.
public struct RemoteScheduleEdit: Encodable, Equatable, Sendable {
    public let scheduleID: String
    public let name: String?
    public let projectID: String?
    public let presetID: String?
    public let trigger: RemoteScheduleTrigger?
    public let instructions: String?
    public let enabled: Bool?
    public let notifyWhenDone: Bool?

    public init(
        scheduleID: String,
        name: String? = nil,
        projectID: String? = nil,
        presetID: String? = nil,
        trigger: RemoteScheduleTrigger? = nil,
        instructions: String? = nil,
        enabled: Bool? = nil,
        notifyWhenDone: Bool? = nil
    ) {
        self.scheduleID = scheduleID
        self.name = name
        self.projectID = projectID
        self.presetID = presetID
        self.trigger = trigger
        self.instructions = instructions
        self.enabled = enabled
        self.notifyWhenDone = notifyWhenDone
    }

    /// Whether the edit changes anything at all.
    public var changesSomething: Bool {
        name != nil || projectID != nil || presetID != nil || trigger != nil
            || instructions != nil || enabled != nil || notifyWhenDone != nil
    }
}

/// `POST /mobile/schedules/delete` and `POST /mobile/schedules/run`.
public struct RemoteScheduleTarget: Encodable, Equatable, Sendable {
    public let scheduleID: String

    public init(scheduleID: String) {
        self.scheduleID = scheduleID
    }
}

/// A create's or an edit's answer: the task as the list now shows it.
public struct RemoteScheduleSaved: Decodable, Equatable, Sendable {
    public let schedule: RemoteScheduledTask
}

/// Run now's answer: the Run it started.
public struct RemoteScheduleRunStarted: Decodable, Equatable, Sendable {
    public let scheduleID: String
    public let runID: String
}
