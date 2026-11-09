import AppKit

/// After a relaunch, `upper` is still above `lower` and both are open. The app's
/// first rows come from its own disk scan, which reads the order file directly, so
/// only rows read after the Host's first bootstrap can show a rank that didn't
/// survive it.
func checkStillAbove(_ scenario: Scenario, list: String, upper: Folder, lower: Folder) {
    if waitUntil(seconds: 2, {
        nudge()
        let now = labels(readRows())
        return isAbove(upper.label, lower.label, in: now) != true || !isOpen(upper, in: now) || !isOpen(lower, in: now)
    }) {
        scenario.fail("the Host has \(hostRawOrder(of: list)); on screen \(layout(readRows()))")
    } else {
        scenario.pass()
    }
}

func runFolderPersisted() {
    let scenario = Scenario("folder-persisted")
    scenarios.append(scenario)
    log("folder-persisted: Beta is still above Alpha after a relaunch, both open")
    guard let big = hostProjectID(named: "Big"),
          isAbove(betaFolder.id, alphaFolder.id, in: hostRawOrder(of: big)) == true else {
        scenario.fail("the Host doesn't have Beta above Alpha, so this proves nothing")
        return
    }
    Thread.sleep(forTimeInterval: 8)
    checkStillAbove(scenario, list: big, upper: betaFolder, lower: alphaFolder)
}

func runPinnedPersisted() {
    let scenario = Scenario("pinned-persisted")
    scenarios.append(scenario)
    log("pinned-persisted: Pin-B is still above Pin-A after a relaunch, both open")
    guard let pins = hostProjectID(named: "Pins"),
          isAbove(pinB.id, pinA.id, in: hostRawOrder(of: pins)) == true else {
        scenario.fail("the Host doesn't have Pin-B above Pin-A, so this proves nothing")
        return
    }
    Thread.sleep(forTimeInterval: 8)
    setExpanded("Big", children: ["Alpha", "Beta"], false)
    setExpanded("Pins", children: pinsRows, true)
    checkStillAbove(scenario, list: pins, upper: pinB, lower: pinA)
}
