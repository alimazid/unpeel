import Foundation
import Testing
@testable import UnpeelShared

/// Fork-only: Scheduled Tasks (Q32). The two additive session-row fields
/// both Host builders publish on a Run Session: `scheduleID` and
/// `superseded`. Absent on every other row and on older Hosts.
struct RemoteRunSessionRowTests {
    @Test func aRunSessionsRowCarriesItsTaskAndWhetherItIsSuperseded() throws {
        let older = try decode(#"{"scheduleID":"sch_a","superseded":true}"#)
        #expect(older.scheduleID == "sch_a")
        #expect(older.superseded)

        let latest = try decode(#"{"scheduleID":"sch_a","superseded":false}"#)
        #expect(latest.scheduleID == "sch_a")
        #expect(!latest.superseded)
    }

    @Test func anyOtherRowOrAnOlderHostsHasNeither() throws {
        let row = try decode("")
        #expect(row.scheduleID == nil)
        #expect(!row.superseded)
    }

    @Test func theFieldsRoundTrip() throws {
        let older = try decode(#"{"scheduleID":"sch_a","superseded":true}"#)
        let again = try JSONDecoder().decode(
            RemoteSessionSummary.self, from: try JSONEncoder().encode(older)
        )
        #expect(again == older)
    }

    private func decode(_ extra: String) throws -> RemoteSessionSummary {
        let fields = extra.isEmpty ? "" : "," + extra.dropFirst().dropLast()
        let json = """
        {"id":"s1","projectID":"p1","title":"Nightly","command":"true",
         "createdAtUnixMs":1,"status":"exited","activity":"idle"\(fields)}
        """
        return try JSONDecoder().decode(RemoteSessionSummary.self, from: Data(json.utf8))
    }
}
