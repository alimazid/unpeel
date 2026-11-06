import XCTest
@testable import UnpeelNative

/// Fork-only: Settings ▸ Notifications "Notify when any agent finishes".
final class NotifyWhenDoneAllAgentsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suites = []
        super.tearDown()
    }

    private func makeSuite() -> UserDefaults {
        let name = "unpeel.tests.notify-all.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    // MARK: Eligibility

    func testNeedsInputIsAlwaysEligible() {
        XCTAssertTrue(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: false, sessionOptedIn: false, allAgents: false
        ))
    }

    func testDoneNeedsAnOptIn() {
        XCTAssertFalse(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: true, sessionOptedIn: false, allAgents: false
        ))
    }

    func testPerSessionOptInStillWorks() {
        XCTAssertTrue(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: true, sessionOptedIn: true, allAgents: false
        ))
    }

    func testAllAgentsMakesEveryDoneEligible() {
        XCTAssertTrue(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: true, sessionOptedIn: false, allAgents: true
        ))
    }

    // MARK: Scheduled Task Runs (the task's "Notify when done")

    func testATasksNotifyWhenDoneNotifiesWithTheGlobalSettingOff() {
        XCTAssertTrue(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: true, sessionOptedIn: false, allAgents: false,
            runNotifyWhenDone: true
        ))
    }

    func testATaskWithNotifyOffStaysSilentWithTheGlobalSettingOn() {
        XCTAssertFalse(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: true, sessionOptedIn: false, allAgents: true,
            runNotifyWhenDone: false
        ))
    }

    func testTheSessionsOwnToggleStillCountsOnARun() {
        // Turned on for that one Session by hand: the user asked for it.
        XCTAssertTrue(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: true, sessionOptedIn: true, allAgents: false,
            runNotifyWhenDone: false
        ))
    }

    func testARunsNeedsInputAndFailuresAlwaysNotify() {
        // Needs-input and failed / failed-to-start notices never require
        // the opt-in, whatever the task says.
        for runNotify in [true, false] {
            XCTAssertTrue(NotifyWhenDoneAllAgents.isEligible(
                requiresNotifyWhenDone: false, sessionOptedIn: false, allAgents: false,
                runNotifyWhenDone: runNotify
            ))
        }
        XCTAssertTrue(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: false, sessionOptedIn: false, allAgents: false,
            runNotifyWhenDone: nil
        ))
    }

    func testANoticeWithoutATaskSettingFollowsTheGlobalSetting() {
        // An older Host, or a deleted task's Run: today's rule.
        XCTAssertFalse(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: true, sessionOptedIn: false, allAgents: false,
            runNotifyWhenDone: nil
        ))
        XCTAssertTrue(NotifyWhenDoneAllAgents.isEligible(
            requiresNotifyWhenDone: true, sessionOptedIn: false, allAgents: true,
            runNotifyWhenDone: nil
        ))
    }

    // MARK: Resolution (own value → default workspace's → off)

    func testDefaultsToOff() {
        XCTAssertFalse(NotifyWhenDoneAllAgents.resolve(
            own: makeSuite(), baseline: makeSuite(), isDefaultInstance: true
        ))
    }

    func testOwnValueWins() {
        let own = makeSuite()
        let baseline = makeSuite()
        own.set(false, forKey: NotifyWhenDoneAllAgents.key)
        baseline.set(true, forKey: NotifyWhenDoneAllAgents.key)
        XCTAssertFalse(NotifyWhenDoneAllAgents.resolve(
            own: own, baseline: baseline, isDefaultInstance: false
        ))
        own.set(true, forKey: NotifyWhenDoneAllAgents.key)
        XCTAssertTrue(NotifyWhenDoneAllAgents.resolve(
            own: own, baseline: baseline, isDefaultInstance: true
        ))
    }

    func testOtherWorkspaceInheritsTheDefaultWorkspace() {
        let baseline = makeSuite()
        baseline.set(true, forKey: NotifyWhenDoneAllAgents.key)
        XCTAssertTrue(NotifyWhenDoneAllAgents.resolve(
            own: makeSuite(), baseline: baseline, isDefaultInstance: false
        ))
    }

    func testDefaultInstanceIgnoresTheBaselineSuite() {
        // The default instance's own suite IS the baseline; a separate
        // baseline value must not leak in.
        let baseline = makeSuite()
        baseline.set(true, forKey: NotifyWhenDoneAllAgents.key)
        XCTAssertFalse(NotifyWhenDoneAllAgents.resolve(
            own: makeSuite(), baseline: baseline, isDefaultInstance: true
        ))
    }

    func testHasOwnSettingTracksTheOwnSuite() {
        let own = makeSuite()
        XCTAssertFalse(NotifyWhenDoneAllAgents.hasOwnSetting(in: own))
        own.set(false, forKey: NotifyWhenDoneAllAgents.key)
        XCTAssertTrue(NotifyWhenDoneAllAgents.hasOwnSetting(in: own))
    }
}
