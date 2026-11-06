import Foundation
import Testing
@testable import UnpeelShared

/// Fork-only: Scheduled Tasks. The shared DTOs against the Host's own
/// contract files: `protocol/schedules-samples-v1.json` (bodies the Rust
/// Host test proves it answers) and the `schedules.*` cases of
/// `protocol/host-conformance-v1.json` and the capability ledger.
struct RemoteScheduledTasksTests {
    @Test func theListDecodesFromTheHostsSampleAnswer() throws {
        let list = try JSONDecoder().decode(
            RemoteSchedulesList.self,
            from: try sampleData(["responses", "list"])
        )
        #expect(list.revision == "0000000000000000")
        #expect(list.schedules.map(\.id)
            == ["sch_daily", "sch_paused", "sch_future", "sch_weekly", "sch_cron", "sch_overlap"])

        let daily = list.schedules[0]
        #expect(daily.name == "Morning briefing")
        #expect(daily.projectID == "p" && daily.presetID == "ok")
        #expect(daily.trigger.kind == "daily" && daily.trigger.time == "09:43")
        #expect(daily.enabled && daily.notifyWhenDone)
        #expect(daily.nextRun == RemoteScheduledTask.NextRun(at: "2026-11-07T09:43", atMs: 1_794_062_580_000))
        #expect(daily.lastRun?.runID == "run_skipped")
        #expect(daily.lastRun?.status == .skipped)
        #expect(daily.lastRun?.reason == "the previous Run was still in progress")

        let paused = list.schedules[1]
        #expect(!paused.enabled && paused.nextRun == nil)
        #expect(paused.trigger.kind == "once" && paused.trigger.at == "2026-11-06T15:00")
        #expect(paused.lastRun?.status == .failed)

        let future = list.schedules[2]
        #expect(future.trigger.kind == "unknown")
        #expect(future.nextRun == nil && future.lastRun == nil)

        #expect(list.schedules[3].trigger
            == RemoteScheduleTrigger(kind: "weekly", time: "08:15", weekday: "monday"))
        #expect(list.schedules[4].trigger == RemoteScheduleTrigger(kind: "cron", expr: "*/15 9-17 * * 1-5"))

        // An occurrence skipped behind a Run in progress never hides it.
        let overlap = list.schedules[5]
        #expect(overlap.lastRun?.runID == "run_overnight")
        #expect(overlap.lastRun?.status == .needsYou)
        #expect(overlap.lastRun?.sessionID == "9a1c2b3d-4e5f-4a6b-8c7d-0e1f2a3b4c5d")
    }

    @Test func runHistoryDecodesNewestFirstWithItsOpenStatuses() throws {
        let history = try JSONDecoder().decode(
            RemoteScheduleRunHistory.self,
            from: try sampleData(["responses", "runs", "body"])
        )
        #expect(history.scheduleID == "sch_daily")
        #expect(history.runs.map(\.runID) == ["run_skipped", "run_now", "run_late"])
        #expect(history.runs.map(\.status) == [.skipped, .other("unknown"), .done])
        let late = history.runs[2]
        #expect(late.late && late.exitCode == 0)
        #expect(late.sessionID == "4f0b6a52-1c3e-4d8e-9a77-1b2c3d4e5f60")
        #expect(late.scheduledFor == "2026-11-05T09:43")
        #expect(late.startedAtMs == 1_793_976_300_000 && late.endedAtMs == 1_793_976_360_000)
        #expect(late.snippet?.hasPrefix("Morning briefing ready") == true)
        #expect(history.runs[1].scheduledFor == nil, "a Run now has no occurrence")
    }

    @Test func everyRunStatusTheHostWritesHasAName() throws {
        let words = ["running", "done", "needs_you", "failed_to_start", "failed", "skipped", "paused_forever"]
        let decoded = try words.map { word in
            try JSONDecoder().decode(RemoteScheduleRunStatus.self, from: Data("\"\(word)\"".utf8))
        }
        #expect(decoded == [.running, .done, .needsYou, .failedToStart, .failed, .skipped, .other("paused_forever")])
        #expect(decoded.map(\.rawValue) == words)
    }

    /// One task the Controller cannot read costs that task, never the list.
    @Test func aTaskThatWillNotDecodeIsDroppedAlone() throws {
        let body = #"""
        {"revision":"r","schedules":[
          {"id":"sch_ok","name":"Fine","projectID":"p","presetID":"ok","trigger":{"kind":"hourly","minute":5},
           "enabled":true,"notifyWhenDone":false,"createdAtMs":1,"nextRun":null,"lastRun":null},
          {"name":"no id"},
          {"id":"sch_sparse"}
        ]}
        """#
        let list = try JSONDecoder().decode(RemoteSchedulesList.self, from: Data(body.utf8))
        #expect(list.schedules.map(\.id) == ["sch_ok", "sch_sparse"])
        #expect(list.schedules[0].trigger.minute == 5 && !list.schedules[0].notifyWhenDone)
        let sparse = list.schedules[1]
        #expect(sparse.name == "" && sparse.enabled && sparse.notifyWhenDone)
        #expect(sparse.trigger.kind == "unknown")
    }

    /// The Swift request side of the contract: the capability ids and the
    /// query the Mac sends are the ones the Host's ledger and conformance
    /// cases name.
    @Test func theRequestsMatchTheHostsLedgerAndConformanceCases() throws {
        let ledger = try fixtureJSON("host-capabilities-v1.json")
        let capabilities = try #require(ledger["capabilities"] as? [[String: Any]])
        func entry(_ id: String) -> [String: Any]? { capabilities.first { $0["id"] as? String == id } }
        let list = try #require(entry(RemoteControlProtocol.schedulesCapability))
        let runs = try #require(entry(RemoteControlProtocol.scheduleRunsCapability))
        #expect(list["method"] as? String == "GET" && list["path"] as? String == "/mobile/schedules")
        #expect(runs["method"] as? String == "GET" && runs["path"] as? String == "/mobile/schedules/runs")
        #expect(list["native"] as? Bool == true && list["tui"] as? Bool == true)
        #expect(runs["native"] as? Bool == true && runs["tui"] as? Bool == true)

        let conformance = try fixtureJSON("host-conformance-v1.json")
        let cases = try #require(conformance["cases"] as? [[String: Any]])
            .filter { ($0["id"] as? String)?.hasPrefix("schedules.") == true }
        let statuses = Dictionary(uniqueKeysWithValues: cases.map { item in
            (item["id"] as? String ?? "", (item["expected"] as? [String: Int])?["native"] ?? 0)
        })
        #expect(statuses == [
            "schedules.list": 200,
            "schedules.runs.missing-id": 400,
            "schedules.runs.invalid-id": 400,
            "schedules.runs.unknown": 404,
            "schedules.create.no-name": 400,
            "schedules.create.no-trigger": 400,
            "schedules.edit.missing-id": 400,
            "schedules.edit.unknown": 404,
            "schedules.delete.missing-id": 400,
            "schedules.delete.unknown": 404,
            "schedules.run.missing-id": 400,
            "schedules.run.unknown": 404,
        ])
        let unknown = try #require(cases.first { $0["id"] as? String == "schedules.runs.unknown" })
        #expect(unknown["query"] as? [String: String]
            == RemoteScheduleRunHistory.query(scheduleID: "conformance-unknown", limit: nil))

        let samples = try fixtureJSON("schedules-samples-v1.json")
        let limited = try #require((samples["responses"] as? [String: Any])?["limitedRuns"] as? [String: Any])
        #expect(limited["query"] as? [String: String]
            == RemoteScheduleRunHistory.query(scheduleID: "sch_daily", limit: 1))

        let fields = try #require(conformance["additiveBootstrapFields"] as? [[String: Any]])
        #expect(fields.contains { $0["field"] as? String == "schedulesRevision" && $0["required"] as? Bool == false })
    }

    /// The write side: the ledger names each write's route, and the bodies
    /// the Mac sends are the ones the conformance cases send.
    @Test func theWritesMatchTheHostsLedgerAndConformanceBodies() throws {
        let ledger = try fixtureJSON("host-capabilities-v1.json")
        let capabilities = try #require(ledger["capabilities"] as? [[String: Any]])
        let routes = [
            RemoteControlProtocol.schedulesCreateCapability: "/mobile/schedules",
            RemoteControlProtocol.schedulesEditCapability: "/mobile/schedules/edit",
            RemoteControlProtocol.schedulesDeleteCapability: "/mobile/schedules/delete",
            RemoteControlProtocol.schedulesRunCapability: "/mobile/schedules/run",
        ]
        for (id, path) in routes {
            let entry = try #require(capabilities.first { $0["id"] as? String == id }, "\(id)")
            #expect(entry["method"] as? String == "POST" && entry["path"] as? String == path, "\(id)")
        }

        let conformance = try fixtureJSON("host-conformance-v1.json")
        let cases = try #require(conformance["cases"] as? [[String: Any]])
        func body(_ id: String) throws -> [String: AnyHashable] {
            let item = try #require(cases.first { $0["id"] as? String == id }, "\(id)")
            return try #require(item["body"] as? [String: AnyHashable], "\(id)")
        }
        #expect(try encoded(RemoteScheduleTarget(scheduleID: "conformance-unknown"))
            == body("schedules.run.unknown"))
        #expect(try encoded(RemoteScheduleTarget(scheduleID: "conformance-unknown"))
            == body("schedules.delete.unknown"))
        #expect(try encoded(RemoteScheduleEdit(scheduleID: "conformance-unknown", name: "Conformance"))
            == body("schedules.edit.unknown"))
    }

    @Test func aCreateCarriesEveryFieldAndATriggerOnlyItsOwn() throws {
        let create = RemoteScheduleCreate(
            name: "Morning", projectID: "p", presetID: "claude",
            trigger: RemoteScheduleTrigger(kind: "weekly", time: "17:00", weekday: "friday"),
            instructions: "brief me", enabled: true, notifyWhenDone: false
        )
        #expect(try encoded(create) == [
            "name": "Morning", "projectID": "p", "presetID": "claude",
            "trigger": ["kind": "weekly", "time": "17:00", "weekday": "friday"] as [String: AnyHashable],
            "instructions": "brief me", "enabled": true, "notifyWhenDone": false,
        ])
        let script = RemoteScheduleCreate(
            name: "Backup", projectID: "p", presetID: "ok",
            trigger: RemoteScheduleTrigger(kind: "hourly", minute: 5),
            instructions: nil, enabled: true, notifyWhenDone: true
        )
        let body = try encoded(script)
        #expect(body["instructions"] == nil, "a script task sends no instructions")
        #expect(body["trigger"] == AnyHashable(["kind": "hourly", "minute": 5] as [String: AnyHashable]))
    }

    /// An edit sends only what changed; empty instructions remove them.
    @Test func anEditSendsOnlyWhatChanged() throws {
        #expect(try encoded(RemoteScheduleEdit(scheduleID: "sch_1", enabled: false))
            == ["scheduleID": "sch_1", "enabled": false])
        #expect(try encoded(RemoteScheduleEdit(scheduleID: "sch_1", instructions: ""))
            == ["scheduleID": "sch_1", "instructions": ""])
        let moved = RemoteScheduleEdit(
            scheduleID: "sch_1", projectID: "q", presetID: "ok",
            trigger: RemoteScheduleTrigger(kind: "once", at: "2026-11-07T08:00"), notifyWhenDone: true
        )
        #expect(try encoded(moved) == [
            "scheduleID": "sch_1", "projectID": "q", "presetID": "ok",
            "trigger": ["kind": "once", "at": "2026-11-07T08:00"] as [String: AnyHashable],
            "notifyWhenDone": true,
        ])
    }

    @Test func theWriteAnswersDecode() throws {
        let saved = try JSONDecoder().decode(
            RemoteScheduleSaved.self,
            from: Data(#"{"schedule":{"id":"sch_1","name":"Morning","instructions":"brief me"}}"#.utf8)
        )
        #expect(saved.schedule.id == "sch_1" && saved.schedule.instructions == "brief me")
        let started = try JSONDecoder().decode(
            RemoteScheduleRunStarted.self, from: Data(#"{"scheduleID":"sch_1","runID":"run_9"}"#.utf8)
        )
        #expect(started.runID == "run_9")
    }

    @Test func aTasksInstructionsAndEachPresetsAgentFlagDecode() throws {
        let list = try JSONDecoder().decode(
            RemoteSchedulesList.self, from: try sampleData(["responses", "list"])
        )
        #expect(list.schedules.first { $0.id == "sch_overlap" }?.instructions == "write the nightly report")
        #expect(list.schedules.first { $0.id == "sch_daily" }?.instructions == nil)

        let body = #"""
        {"protocolVersion":1,"folders":[],"projects":[],"sessions":[],"capturedAtUnixMs":1,"presets":[
          {"id":"claude","label":"Claude","command":"claude","enabled":true,"quickLaunch":false,"isDefault":false,"agentPreset":true},
          {"id":"ok","label":"OK","command":"true","enabled":true,"quickLaunch":false,"isDefault":false,"agentPreset":false},
          {"id":"old","label":"Old","command":"claude","enabled":true,"quickLaunch":false,"isDefault":false}
        ]}
        """#
        let snapshot = try JSONDecoder().decode(RemoteBootstrapSnapshot.self, from: Data(body.utf8))
        #expect(snapshot.presets.map(\.agentPreset) == [true, false, nil])
    }

    @Test func bootstrapCarriesTheSchedulesRevision() throws {
        let body = #"{"protocolVersion":1,"folders":[],"projects":[],"presets":[],"sessions":[],"capturedAtUnixMs":1,"schedulesRevision":"abc"}"#
        let snapshot = try JSONDecoder().decode(RemoteBootstrapSnapshot.self, from: Data(body.utf8))
        #expect(snapshot.schedulesRevision == "abc")
        let older = #"{"protocolVersion":1,"folders":[],"projects":[],"presets":[],"sessions":[],"capturedAtUnixMs":1}"#
        #expect(try JSONDecoder().decode(RemoteBootstrapSnapshot.self, from: Data(older.utf8)).schedulesRevision == nil)
    }

    // MARK: - Fixtures

    /// A request body as the Host reads it.
    private func encoded(_ value: some Encodable) throws -> [String: AnyHashable] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
    }

    private func sampleData(_ path: [String]) throws -> Data {
        var value: Any = try fixtureJSON("schedules-samples-v1.json")
        for key in path {
            value = try #require((value as? [String: Any])?[key], "missing \(key)")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    /// `protocol/<name>` in this checkout, or under UNPEEL_PROTOCOL_DIR (the
    /// same lookup as `RemoteControlProtocolTests.fixtureJSON`).
    private func fixtureJSON(_ name: String) throws -> [String: Any] {
        if let override = ProcessInfo.processInfo.environment["UNPEEL_PROTOCOL_DIR"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: override).appendingPathComponent(name))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent("protocol").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
            directory.deleteLastPathComponent()
        }
        Issue.record("could not locate protocol/\(name) from \(#filePath); set UNPEEL_PROTOCOL_DIR")
        return [:]
    }
}
