import Foundation
import Testing
@testable import UnpeelShared

/// Fork-only (#63): the additive `detectedLocalURLs` both Host builders
/// publish on a running Session that serves a local site. Absent on every
/// other row and on older Hosts.
struct RemoteLocalSiteRowTests {
    @Test func aRunningSitesRowCarriesItsURLs() throws {
        let row = try decode(#"{"detectedLocalURLs":["http://127.0.0.1:5173/","http://localhost:3000/"]}"#)
        #expect(row.detectedLocalURLs == ["http://127.0.0.1:5173/", "http://localhost:3000/"])
    }

    @Test func anyOtherRowOrAnOlderHostsHasNone() throws {
        #expect(try decode("").detectedLocalURLs.isEmpty)
    }

    @Test func theFieldRoundTrips() throws {
        let row = try decode(#"{"detectedLocalURLs":["http://127.0.0.1:5173/"]}"#)
        let again = try JSONDecoder().decode(
            RemoteSessionSummary.self, from: try JSONEncoder().encode(row)
        )
        #expect(again == row)
    }

    @Test func theConformanceLedgerListsTheField() throws {
        let conformance = try fixtureJSON("host-conformance-v1.json")
        let fields = try #require(conformance["additiveBootstrapFields"] as? [[String: Any]])
        #expect(fields.contains {
            $0["field"] as? String == "sessions[].detectedLocalURLs" && $0["required"] as? Bool == false
        })
    }

    private func decode(_ extra: String) throws -> RemoteSessionSummary {
        let fields = extra.isEmpty ? "" : "," + extra.dropFirst().dropLast()
        let json = """
        {"id":"s1","projectID":"p1","title":"Site","command":"npm run dev",
         "createdAtUnixMs":1,"status":"running","activity":"idle"\(fields)}
        """
        return try JSONDecoder().decode(RemoteSessionSummary.self, from: Data(json.utf8))
    }

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
