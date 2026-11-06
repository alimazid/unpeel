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
        #expect(list.schedules.map(\.id) == ["sch_daily", "sch_paused", "sch_future"])

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

    @Test func bootstrapCarriesTheSchedulesRevision() throws {
        let body = #"{"protocolVersion":1,"folders":[],"projects":[],"presets":[],"sessions":[],"capturedAtUnixMs":1,"schedulesRevision":"abc"}"#
        let snapshot = try JSONDecoder().decode(RemoteBootstrapSnapshot.self, from: Data(body.utf8))
        #expect(snapshot.schedulesRevision == "abc")
        let older = #"{"protocolVersion":1,"folders":[],"projects":[],"presets":[],"sessions":[],"capturedAtUnixMs":1}"#
        #expect(try JSONDecoder().decode(RemoteBootstrapSnapshot.self, from: Data(older.utf8)).schedulesRevision == nil)
    }

    // MARK: - Fixtures

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
