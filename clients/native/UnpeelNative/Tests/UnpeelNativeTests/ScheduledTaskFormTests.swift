import Foundation
import Testing
import UnpeelShared
@testable import UnpeelNative

/// Fork-only: Scheduled Tasks. The edit sheet's model: which fields show
/// for which preset (only the Host's Agent Preset flag counts), the
/// approval-bypass warning, a cron Trigger kept read-only, what a save
/// sends, and the Host's refusals in words a person reads.
struct ScheduledTaskFormTests {
    // MARK: Fields by preset kind

    @Test
    func instructionsShowOnlyWhenTheHostSaysThePresetIsAnAgentPreset() {
        #expect(ScheduledTaskForm.showsInstructions(preset("claude", "claude", agent: true)))
        #expect(!ScheduledTaskForm.showsInstructions(preset("ok", "./backup.sh", agent: false)))
        // An older Host says nothing: the app never guesses from the command.
        #expect(!ScheduledTaskForm.showsInstructions(preset("old", "claude", agent: nil)))
        #expect(!ScheduledTaskForm.showsInstructions(nil))
    }

    @Test
    func aProjectSeesItsOwnPresetsAndTheGlobalOnesItDoesNotOverride() {
        let presets = [
            preset("claude", "claude", agent: true),
            preset("ok", "true", agent: false),
            preset("claude", "claude --resume", agent: true, projectID: "p"),
            preset("other", "codex", agent: true, projectID: "q"),
            preset("off", "true", agent: false, enabled: false),
        ]
        let forP = ScheduledTaskForm.presets(for: "p", in: presets)
        #expect(forP.map(\.command) == ["claude --resume", "true"])
        #expect(ScheduledTaskForm.presets(for: "q", in: presets).map(\.id) == ["claude", "ok", "other"])
        #expect(ScheduledTaskForm.preset(id: "claude", projectID: "p", in: presets)?.command == "claude --resume")
    }

    @Test
    func onlyProjectsWithAFolderCanRunATask() {
        let projects = [
            RemoteProjectSummary(id: "p", name: "Inbox", path: "/work/inbox"),
            RemoteProjectSummary(id: "g", name: "Clients", path: "", isGroup: true),
            RemoteProjectSummary(id: "w", name: "Inbox", path: "/work/inbox-fix",
                                 parentProjectID: "p", worktreeBranch: "fix"),
        ]
        let choices = ScheduledTaskForm.projectChoices(projects)
        #expect(choices.map(\.id) == ["p", "w"])
        #expect(choices.map(\.title) == ["Inbox", "Inbox (fix)"])
    }

    // MARK: Approval-bypass warning

    @Test
    func theApprovalBypassWarningFollowsTheHostAlone() {
        let flagged = RemotePresetSummary(
            id: "yolo", label: "yolo", command: "gemini --yolo", bypassesApprovals: true
        )
        let warning = ScheduledTaskForm.bypassWarning(for: flagged)
        #expect(warning?.contains("approval prompts") == true)
        #expect(warning?.contains("\n") == false, "one line")
        // The command is never read: only the Host's verdict counts, and an
        // older Host that says nothing gets no warning.
        let unflagged = RemotePresetSummary(
            id: "plain", label: "plain", command: "claude --dangerously-skip-permissions",
            bypassesApprovals: false
        )
        let older = RemotePresetSummary(id: "old", label: "old", command: "gemini --yolo")
        #expect(ScheduledTaskForm.bypassWarning(for: unflagged) == nil)
        #expect(ScheduledTaskForm.bypassWarning(for: older) == nil)
        #expect(ScheduledTaskForm.bypassWarning(for: nil) == nil)
    }

    // MARK: Trigger

    @Test
    func aCronTriggerOpensReadOnlyAndIsSentBackUnchanged() throws {
        let cron = RemoteScheduleTrigger(kind: "cron", expr: "*/15 9-17 * * 1-5")
        #expect(!ScheduledTaskForm.isTriggerEditable(cron))
        #expect(!ScheduledTaskForm.isTriggerEditable(RemoteScheduleTrigger(kind: "fortnightly")))
        for kind in ["hourly", "daily", "weekdays", "weekly", "once"] {
            #expect(ScheduledTaskForm.isTriggerEditable(RemoteScheduleTrigger(kind: kind)), "\(kind)")
        }
        let task = RemoteScheduledTask(id: "sch_c", name: "Quarter hours", projectID: "p",
                                       presetID: "ok", trigger: cron)
        let draft = ScheduledTaskDraft(task: task, calendar: calendar)
        #expect(draft.fixedTrigger == cron)
        #expect(draft.trigger(calendar: calendar) == cron)
        #expect(ScheduledTaskForm.readOnlyTriggerText(cron).contains("*/15 9-17 * * 1-5"))
        #expect(ScheduledTaskForm.readOnlyTriggerText(cron).contains("unpeel schedules edit"))

        var renamed = draft
        renamed.name = "Every quarter hour"
        let edit = ScheduledTaskForm.editRequest(original: task, initial: draft, draft: renamed,
                                                 showsInstructions: false, calendar: calendar)
        #expect(edit == RemoteScheduleEdit(scheduleID: "sch_c", name: "Every quarter hour"))
    }

    @Test
    func everyEditableTriggerRoundTripsThroughTheDraft() {
        let triggers = [
            RemoteScheduleTrigger(kind: "hourly", minute: 15),
            RemoteScheduleTrigger(kind: "daily", time: "09:43"),
            RemoteScheduleTrigger(kind: "weekdays", time: "08:30"),
            RemoteScheduleTrigger(kind: "weekly", time: "17:00", weekday: "friday"),
            RemoteScheduleTrigger(kind: "once", at: "2026-11-07T15:00"),
        ]
        for trigger in triggers {
            let draft = ScheduledTaskDraft(task: RemoteScheduledTask(id: "s", name: "n", trigger: trigger),
                                           calendar: calendar)
            #expect(draft.fixedTrigger == nil)
            #expect(draft.trigger(calendar: calendar) == trigger, "\(trigger.kind)")
        }
        var draft = ScheduledTaskDraft.blank(projectID: "p", presetID: "ok", now: at(6, 22, 10), calendar: calendar)
        draft.triggerKind = .weekly
        draft.weekday = "monday"
        #expect(draft.trigger(calendar: calendar) == RemoteScheduleTrigger(kind: "weekly", time: "09:00", weekday: "monday"))
        draft.triggerKind = .once
        #expect(draft.trigger(calendar: calendar) == RemoteScheduleTrigger(kind: "once", at: "2026-11-06T23:00"),
                "a new Once defaults to the next whole hour")
    }

    // MARK: What a save sends

    @Test
    func aBlankSheetCreatesAnEnabledTaskThatNotifiesByDefault() {
        var draft = ScheduledTaskDraft.blank(projectID: "p", presetID: "claude", now: at(6, 22, 10), calendar: calendar)
        #expect(draft.enabled && draft.notifyWhenDone)
        #expect(draft.triggerKind == .daily)
        #expect(ScheduledTaskForm.problem(draft) == "Give the task a name.")
        draft.name = "  Morning briefing "
        draft.instructions = "  brief me  "
        #expect(ScheduledTaskForm.problem(draft) == nil)
        let create = ScheduledTaskForm.createRequest(draft, showsInstructions: true, calendar: calendar)
        #expect(create == RemoteScheduleCreate(
            name: "Morning briefing", projectID: "p", presetID: "claude",
            trigger: RemoteScheduleTrigger(kind: "daily", time: "09:00"),
            instructions: "brief me", enabled: true, notifyWhenDone: true
        ))
        // Instructions typed for an agent preset are not sent once a script
        // preset is picked.
        let script = ScheduledTaskForm.createRequest(draft, showsInstructions: false, calendar: calendar)
        #expect(script.instructions == nil)

        draft.projectID = ""
        #expect(ScheduledTaskForm.problem(draft) == "Pick a Project.")
        draft.projectID = "p"
        draft.presetID = ""
        #expect(ScheduledTaskForm.problem(draft) == "Pick a preset.")
    }

    @Test
    func anEditSendsOnlyWhatChanged() {
        let task = RemoteScheduledTask(
            id: "sch_1", name: "Morning", projectID: "p", presetID: "claude",
            trigger: RemoteScheduleTrigger(kind: "daily", time: "09:43:30"),
            enabled: true, notifyWhenDone: true, instructions: "brief me"
        )
        let initial = ScheduledTaskDraft(task: task, calendar: calendar)
        let unchanged = ScheduledTaskForm.editRequest(original: task, initial: initial, draft: initial,
                                                      showsInstructions: true, calendar: calendar)
        #expect(!unchanged.changesSomething, "opening and saving changes nothing, seconds included")

        var draft = initial
        draft.notifyWhenDone = false
        draft.enabled = false
        draft.instructions = "brief me twice"
        draft.triggerKind = .weekdays
        let edit = ScheduledTaskForm.editRequest(original: task, initial: initial, draft: draft,
                                                 showsInstructions: true, calendar: calendar)
        #expect(edit == RemoteScheduleEdit(
            scheduleID: "sch_1", trigger: RemoteScheduleTrigger(kind: "weekdays", time: "09:43"),
            instructions: "brief me twice", enabled: false, notifyWhenDone: false
        ))

        var toScript = initial
        toScript.presetID = "ok"
        let moved = ScheduledTaskForm.editRequest(original: task, initial: initial, draft: toScript,
                                                  showsInstructions: false, calendar: calendar)
        #expect(moved == RemoteScheduleEdit(scheduleID: "sch_1", presetID: "ok", instructions: ""),
                "a script preset drops the task's instructions")
    }

    @Test
    func duplicatingCopiesEverySettingUnderANewName() {
        let task = RemoteScheduledTask(
            id: "sch_1", name: "Morning", projectID: "p", presetID: "claude",
            trigger: RemoteScheduleTrigger(kind: "cron", expr: "0 9 * * 1-5"),
            enabled: false, notifyWhenDone: false, instructions: "brief me"
        )
        #expect(ScheduledTaskForm.duplicateRequest(of: task) == RemoteScheduleCreate(
            name: "Morning copy", projectID: "p", presetID: "claude",
            trigger: RemoteScheduleTrigger(kind: "cron", expr: "0 9 * * 1-5"),
            instructions: "brief me", enabled: false, notifyWhenDone: false
        ))
        let untitled = RemoteScheduledTask(id: "sch_2", name: " ", projectID: "p", presetID: "ok",
                                           trigger: RemoteScheduleTrigger(kind: "hourly", minute: 0))
        #expect(ScheduledTaskForm.duplicateRequest(of: untitled).name == "Untitled task copy")
    }

    // MARK: The Host's refusals

    @Test
    func hostRefusalsReadByTheirCodeNeverTheirText() {
        let refused = { (status: Int, code: String?, text: String) -> Error in
            NativeRemoteBackendError(
                result: -1, code: "host_operation_rejected",
                message: "Host Host resource returned \(status): \(text)",
                kind: "notApplied", operation: "Host resource",
                hostStatus: status, hostCode: code, hostMessage: text
            )
        }
        #expect(ScheduledTaskErrorText.message(for: refused(409, "run_in_progress", "a Run of Morning is still in progress"))
            == "A Run of this task is still in progress. Try again once it finishes.")
        // The code decides, whatever the text says.
        #expect(ScheduledTaskErrorText.message(for: refused(400, "trigger_in_past", "cannot resume: something else"))
            == "That time has already passed. Pick a time in the future.")
        #expect(ScheduledTaskErrorText.message(for: refused(400, "invalid_trigger", "invalid Trigger: \"25:00\" is not a local time"))
            == "That Trigger isn't valid. Check its time and how often it repeats.")
        #expect(ScheduledTaskErrorText.message(for: refused(404, "unknown_task", "no Scheduled Task sch_1"))
            == "This Scheduled Task no longer exists on the Host.")
        // A code this build does not know, or none, shows the Host's message.
        #expect(ScheduledTaskErrorText.message(for: refused(400, "a_future_code", "the moon is not up"))
            == "The moon is not up.")
        #expect(ScheduledTaskErrorText.message(for: refused(500, nil, "could not read Scheduled Tasks"))
            == "Could not read Scheduled Tasks.")
        // Anything that is not a Host refusal keeps its own words, even if
        // it reads like one.
        let plain = ScheduledTaskFormTestError(message: "This Host does not support Scheduled Tasks yet. Update Unpeel on the Host.")
        #expect(ScheduledTaskErrorText.message(for: plain) == plain.message)
        let lookalike = ScheduledTaskFormTestError(message: "Host resource returned 409: in progress")
        #expect(ScheduledTaskErrorText.message(for: lookalike) == lookalike.message)
    }

    /// Every code in the Host's refusal vocabulary the app should word is
    /// worded (`invalid_request` and `internal` show the Host's message).
    @Test
    func everyRefusalCodeTheHostListsIsWorded() throws {
        let fixture = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try Self.protocolFile("host-conformance-v1.json"))
        ) as? [String: Any]
        let refusals = fixture?["scheduleWriteRefusals"] as? [String: Any]
        let codes = (refusals?["codes"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        #expect(!codes.isEmpty)
        for code in codes where !["invalid_request", "internal"].contains(code) {
            #expect(ScheduledTaskErrorText.byCode[code] != nil, "\(code)")
        }
    }

    /// `protocol/<name>` of this checkout (UNPEEL_PROTOCOL_DIR points at
    /// another copy), as the other conformance tests find it.
    private static func protocolFile(_ name: String) throws -> URL {
        if let override = ProcessInfo.processInfo.environment["UNPEEL_PROTOCOL_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent(name)
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent("protocol").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    // MARK: Fixtures

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func preset(
        _ id: String,
        _ command: String,
        agent: Bool?,
        projectID: String? = nil,
        enabled: Bool = true
    ) -> RemotePresetSummary {
        RemotePresetSummary(id: id, label: id, command: command, enabled: enabled,
                            projectID: projectID, agentPreset: agent)
    }
}

private struct ScheduledTaskFormTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
