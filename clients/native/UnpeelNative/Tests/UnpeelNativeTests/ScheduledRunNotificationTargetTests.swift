import XCTest
@testable import UnpeelNative

/// Fork-only: Scheduled Tasks. Where a `notification.deliver` lands.
final class ScheduledRunNotificationTargetTests: XCTestCase {
    func testAKnownSessionIsTheTargetAsBefore() {
        for scheduleID in [nil, "sch_1"] {
            XCTAssertEqual(
                NotificationTarget.resolve(
                    sessionID: "session-1", sessionKnown: true, scheduleID: scheduleID
                ),
                NotificationTarget(
                    sessionID: "session-1", bannerKey: "session-1", pushSessionID: "session-1"
                )
            )
        }
    }

    func testAnUnknownSessionIsRefusedUnlessTheNoticeIsARuns() {
        XCTAssertNil(NotificationTarget.resolve(
            sessionID: "session-1", sessionKnown: false, scheduleID: nil
        ))
        XCTAssertNil(NotificationTarget.resolve(
            sessionID: "", sessionKnown: false, scheduleID: nil
        ))
    }

    func testARunWithNoSessionIsKeyedByItsTask() {
        // It never launched, or its Session never appeared: a tap selects
        // nothing, repeats of the task's notice replace each other, and the
        // phone gets a stand-in id (its payload requires one).
        let expected = NotificationTarget(
            sessionID: nil, bannerKey: "schedule:sch_1", pushSessionID: "schedule:sch_1"
        )
        XCTAssertEqual(
            NotificationTarget.resolve(sessionID: "", sessionKnown: false, scheduleID: "sch_1"),
            expected
        )
        XCTAssertEqual(
            NotificationTarget.resolve(
                sessionID: "never-started", sessionKnown: false, scheduleID: "sch_1"
            ),
            expected
        )
    }
}
