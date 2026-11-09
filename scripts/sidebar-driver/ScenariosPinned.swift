import AppKit

/// Pinned folders on a Host-served list, in project Pins: Pin-A and Pin-B, then
/// Plain and a Session below them. Big closes for the run, so the rows fit a
/// laptop screen, and the run ends with Pin-B above, for a relaunch to check.
func runPinnedFolders(count: Int) {
    let scenario = Scenario("folder-pinned")
    scenarios.append(scenario)
    log("folder-pinned: swap open Pin-A and Pin-B x\(count), up and down, ending with Pin-B above")
    guard let pins = hostProjectID(named: "Pins") else {
        scenario.fail("the Host has no project named Pins")
        return
    }
    setExpanded("Big", children: ["Alpha", "Beta"], false)
    setExpanded("Pins", children: pinsRows, true)
    runOpenSwaps(scenario, list: pins, pinA, pinB, count: count)
    let rest = min(count, 6)
    runPinnedPastUnpinned(pins: pins, count: rest)
    runUnpinnedAbovePinned(pins: pins, count: rest)
    runSessionAbovePinned(pins: pins, count: rest)
    runSessionIntoPinned(pins: pins, trips: max(1, rest / 2))
    setExpanded("Pins", children: pinsRows, false)
    setExpanded("Big", children: ["Alpha", "Beta"], true)
}

/// A pinned folder dropped on an unpinned row is refused and goes home. This
/// guards a rule #53 didn't change: nothing has turned it red.
func runPinnedPastUnpinned(pins: String, count: Int) {
    let scenario = Scenario("pinned-past-unpinned")
    scenarios.append(scenario)
    log("pinned-past-unpinned: Pin-B onto the Session below Plain x\(count): it goes home")
    for attempt in 1 ... count {
        let rows = readRows()
        guard let moved = rows.first(where: { $0.label == pinB.label }),
              let target = rows.firstIndex(where: { $0.label == pinsSession }),
              target >= pinB.block.count else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        // Pin-B's block leaves as it lifts, so the target comes up that many rows.
        let aimY = rows[target - pinB.block.count].frame.midY
        dragStaysPut(
            scenario, attempt: attempt, list: pins, rows: rows, from: press(moved.frame),
            to: CGPoint(x: moved.frame.minX + 6, y: aimY),
            describe: "Pin-B onto \(summary([pinsSession]))"
        )
    }
}

/// For `whileHeld`: a gap above a pinned folder pushes the pinned rows down, so
/// they have to be where they were, once a gap's spring has had time to run.
func expectNoGapAbovePinned(_ scenario: Scenario, attempt: Int, before rows: [Row]) -> () -> Void {
    let before = positions(rows)
    return {
        Thread.sleep(forTimeInterval: 0.35)
        let moved = movedRows(pinnedBlock, from: before, to: positions(readRows()))
        if !moved.isEmpty {
            scenario.fail("drag \(attempt): a gap opened above a pinned folder: \(summary(moved)) moved")
        }
    }
}

/// An unpinned folder over a pinned one gets no gap, since it would float back
/// below it, and the drop leaves everything where it was.
func runUnpinnedAbovePinned(pins: String, count: Int) {
    let scenario = Scenario("unpinned-above-pinned")
    scenarios.append(scenario)
    log("unpinned-above-pinned: Plain over the top pinned folder x\(count): no gap, and it stays put")
    for attempt in 1 ... count {
        let rows = readRows()
        guard let moved = rows.first(where: { $0.label == plain.label }),
              let top = placed(pinA, pinB, in: rows)?.upper else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        dragStaysPut(
            scenario, attempt: attempt, list: pins, rows: rows, from: press(moved.frame),
            to: CGPoint(x: top.row.frame.minX + 6, y: top.row.frame.minY + 2),
            describe: "Plain above \(top.folder.label)",
            whileHeld: expectNoGapAbovePinned(scenario, attempt: attempt, before: rows)
        )
    }
}

/// A Session over the edge of a pinned folder gets no gap there either, and
/// isn't filed inside it. It may land above Plain on the way, below the pinned
/// block.
func runSessionAbovePinned(pins: String, count: Int) {
    let scenario = Scenario("session-above-pinned")
    scenarios.append(scenario)
    log("session-above-pinned: \(summary([pinsSession])) over the top pinned folder's edge x\(count): no gap")
    func staysBelowThePinned() -> Bool {
        let now = labels(readRows())
        return [pinA.label, pinB.label].allSatisfy { isAbove($0, pinsSession, in: now) == true }
            && hostProjects()[pinsSession] == pins
    }
    for attempt in 1 ... count {
        let rows = readRows()
        guard let moved = rows.first(where: { $0.label == pinsSession }),
              let top = placed(pinA, pinB, in: rows)?.upper else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        runDrag(
            scenario, attempt: attempt, from: press(moved.frame),
            path: [CGPoint(x: top.row.frame.minX + 6, y: top.row.frame.minY + 2)],
            describe: "\(summary([pinsSession])) above \(top.folder.label)",
            whileHeld: expectNoGapAbovePinned(scenario, attempt: attempt, before: rows),
            expected: staysBelowThePinned,
            drifted: { !staysBelowThePinned() },
            actual: { "it's in \(hostProjects()[pinsSession] ?? "nothing"); on screen \(layout(readRows()))" }
        )
    }
}

/// The rule that keeps a gap off a pinned folder's edges leaves its middle alone:
/// a Session dropped there files inside. Each trip goes in and comes back out over
/// the project's header.
func runSessionIntoPinned(pins: String, trips: Int) {
    let scenario = Scenario("session-into-pinned")
    scenarios.append(scenario)
    log("session-into-pinned: \(summary([pinsSession])) into Pin-A and back x\(trips)")
    for attempt in 1 ... trips * 2 {
        let rows = readRows()
        let goingIn = hostProjects()[pinsSession] == pins
        let goal = goingIn ? (label: pinA.label, id: pinA.id) : (label: "Pins", id: pins)
        guard let source = rows.first(where: { $0.label == pinsSession }),
              let header = rows.first(where: { $0.label == goal.label }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        runDrag(
            scenario, attempt: attempt, from: press(source.frame), path: [press(header.frame)],
            describe: "\(summary([pinsSession])) onto \(goal.label)", holdMs: 350,
            expected: { hostProjects()[pinsSession] == goal.id },
            actual: { "the Host has it in \(hostProjects()[pinsSession] ?? "nothing"); \(layout(readRows()))" }
        )
    }
}
