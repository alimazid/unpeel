import AppKit

/// One drag whose result is `expected()`. A drag the user interrupted is retried.
/// `drifted`, when given, is watched for a moment after it lands: rows that land
/// and then move read as landed to `expected` alone.
func runDrag(
    _ scenario: Scenario,
    attempt: Int,
    from: CGPoint,
    path: [CGPoint],
    describe: String,
    holdMs: Int = 200,
    aim: (() -> CGPoint?)? = nil,
    aimWait: Double = 0,
    whileHeld: (() -> Void)? = nil,
    afterRelease: ((Set<Int>) -> Void)? = nil,
    expected: @escaping () -> Bool,
    drifted: (() -> Bool)? = nil,
    actual: () -> String
) {
    for _ in 0 ..< 5 {
        guard ready(for: from) else {
            scenario.fail("drag \(attempt): the app's window is not on top")
            return
        }
        switch drag(
            from: from, path: path, holdMs: holdMs, aim: aim, aimWait: aimWait,
            whileHeld: whileHeld, afterRelease: afterRelease
        ) {
        case .interrupted:
            pauses += 1
            log("  drag \(attempt) interrupted by the user: retrying after quiet")
            waitForQuiet()
            Thread.sleep(forTimeInterval: 1)
            continue
        case let .finished(lifted):
            guard lifted else {
                scenario.fail("drag \(attempt): \(describe): the row never lifted")
                Thread.sleep(forTimeInterval: 0.6)
                return
            }
            if waitUntil(seconds: 2.5, {
                nudge()
                return expected()
            }) {
                if let drifted, waitUntil(seconds: 2, {
                    nudge()
                    return drifted()
                }) {
                    scenario.fail("drag \(attempt): \(describe): landed, then moved: \(actual())")
                } else {
                    scenario.pass()
                }
            } else {
                scenario.fail("drag \(attempt): \(describe): landed wrong: \(actual())")
            }
            Thread.sleep(forTimeInterval: 0.35)
            return
        }
    }
    scenario.fail("drag \(attempt): \(describe): interrupted five times")
}

/// One drag of a row onto another's place, where the Host's order and the rows
/// on screen both have to show `movedID` on the wanted side of `targetID`.
func dragIntoPlace(
    _ scenario: Scenario,
    attempt: Int,
    list: String,
    moved: Row,
    movedID: String,
    target: Row,
    targetID: String,
    aimY: CGFloat,
    whileHeld: (() -> Void)? = nil,
    landed: @escaping () -> Bool = { true }
) {
    let goAbove = moved.frame.midY > target.frame.midY
    runDrag(
        scenario, attempt: attempt, from: press(moved.frame),
        path: [CGPoint(x: moved.frame.minX + 6, y: aimY)],
        describe: "\(summary([moved.label])) \(goAbove ? "above" : "below") \(summary([target.label]))",
        whileHeld: whileHeld,
        expected: {
            isAbove(moved.label, target.label, in: labels(readRows())) == goAbove
                && isAbove(movedID, targetID, in: hostRawOrder(of: list)) == goAbove
                && landed()
        },
        drifted: { isAbove(moved.label, target.label, in: labels(readRows())) == !goAbove },
        actual: { "the Host has \(hostRawOrder(of: list)); on screen \(layout(readRows()))" }
    )
}

/// One drag that has to leave the list as it was, on screen and in the Host's order.
func dragStaysPut(
    _ scenario: Scenario,
    attempt: Int,
    list: String,
    rows: [Row],
    from: CGPoint,
    to target: CGPoint,
    describe: String,
    whileHeld: (() -> Void)? = nil
) {
    let order = labels(rows)
    let raw = hostRawOrder(of: list)
    runDrag(
        scenario, attempt: attempt, from: from, path: [target], describe: describe,
        whileHeld: whileHeld,
        expected: { labels(readRows()) == order && hostRawOrder(of: list) == raw },
        drifted: { labels(readRows()) != order },
        actual: { "the Host has \(hostRawOrder(of: list)); on screen \(layout(readRows()))" }
    )
}
