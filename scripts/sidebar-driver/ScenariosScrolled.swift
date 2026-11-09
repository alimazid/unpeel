import AppKit

/// The same reorder as `runListReorder`, in a list scrolled by `scrollFirst`:
/// the rows out of view are unmounted by then.
func runScrolledReorder(_ name: String, session: String, how: String, count: Int, scrollFirst: () -> Void) {
    let scenario = Scenario(name)
    scenarios.append(scenario)
    let home = hostProjects()[session] ?? ""
    log("reorder \(summary([session])) \(how) x\(count)")
    for attempt in 1 ... count {
        scrollFirst()
        let rows = readRows()
        let order = rowsOfBig()
        guard let from = order.firstIndex(of: session),
              let source = rows.first(where: { $0.label == session }) else {
            scenario.fail("drag \(attempt): \(summary([session])) is not on screen: \(layout(rows))")
            continue
        }
        let to = attempt % 2 == 1 ? from + 2 : from - 2
        guard order.indices.contains(to),
              let anchor = rows.first(where: { $0.label == order[to] }) else {
            scenario.fail("drag \(attempt): no row two away from \(summary([session]))")
            continue
        }
        var expected = order
        expected.remove(at: from)
        expected.insert(session, at: to)
        runDrag(
            scenario, attempt: attempt, from: press(source.frame),
            path: [CGPoint(x: source.frame.minX + 6, y: anchor.frame.midY)],
            describe: "\(summary([session])) to \(summary([order[to]]))'s place",
            // Only the rows that were on screen: the Host's list is longer, and
            // it has none at all before this list's first reorder.
            expected: { hostOrder(of: home).filter(order.contains) == expected },
            actual: { "the Host has \(summary(hostOrder(of: home))); expected \(summary(expected))" }
        )
    }
}

/// Selecting a far row from the keyboard (#46): ⌃2 goes to Small at the bottom
/// of the list, and ⌃1 comes back to Big's most recently used row. That row has
/// room above and below it, so it lands centered. A minimal scroll stops it at
/// the list's top edge, and no scroll leaves it off screen.
func runFarSelect(count: Int) {
    let scenario = Scenario("far-select")
    scenarios.append(scenario)
    let smallRow = "~/w/Big/small-3"
    let digit1: CGKeyCode = 18
    let digit2: CGKeyCode = 19

    /// Presses the key with `label` off screen, and returns its row once the
    /// list holds still.
    func select(_ label: String, keyCode: CGKeyCode, attempt: Int) -> (row: Row, area: CGRect)? {
        nudge()
        guard !labels(readRows()).contains(label) else {
            scenario.fail("select \(attempt): \(summary([label])) is already on screen, so this proves nothing")
            return nil
        }
        guard let area = mainWindow().flatMap({ firstScrollArea(in: $0) }).flatMap({ frame(of: $0) }),
              ready(for: CGPoint(x: area.midX, y: area.midY)) else {
            scenario.fail("select \(attempt): the window isn't in front")
            return nil
        }
        pressKey(keyCode: keyCode, flags: .maskControl)
        Thread.sleep(forTimeInterval: 0.4)
        nudge()
        waitForStillRows()
        let rows = readRows()
        guard let row = rows.first(where: { $0.label == label }) else {
            scenario.fail("select \(attempt): \(summary([label])) never came on screen: \(layout(rows))")
            return nil
        }
        return (row, area)
    }

    scrollToTop()
    nudge()
    // Far enough down the list to center, and the farthest such row from Small.
    let onScreen = rowsOfBig()
    guard onScreen.count > 2, let row = readRows().first(where: { $0.label == onScreen[2] }),
          ready(for: press(row.frame)) else {
        scenario.fail("no row of Big to select at the top of the list: \(layout(readRows()))")
        return
    }
    let bigRow = row.label
    log("select \(summary([smallRow])) and \(summary([bigRow])) off screen with ⌃2 and ⌃1 x\(count)")
    click(press(row.frame))
    Thread.sleep(forTimeInterval: 0.5)

    for attempt in 1 ... count {
        guard select(smallRow, keyCode: digit2, attempt: attempt) != nil else { continue }
        Thread.sleep(forTimeInterval: keyInputHold)
        guard let selected = select(bigRow, keyCode: digit1, attempt: attempt) else { continue }
        let offset = selected.row.frame.midY - selected.area.midY
        if abs(offset) <= 10 {
            scenario.pass()
        } else {
            scenario.fail("select \(attempt): \(summary([bigRow])) landed \(Int(offset)) pt from the list's center")
        }
        Thread.sleep(forTimeInterval: keyInputHold)
    }
}

/// Filing a Session from a list that overflows the window, with both rows on
/// screen and no auto-scroll: the rows below the fold are unmounted.
func runLongListDrop(count: Int) {
    let scenario = Scenario("long-list-drop")
    scenarios.append(scenario)
    let session = "~/w/Big/big-28"
    let home = hostProjects()[session] ?? ""
    log("file \(summary([session])) into Beta in a long list x\(count)")
    for attempt in 1 ... count {
        nudge()
        let rows = readRows()
        let goal = hostProjects()[session] == home ? ("Beta", "g-beta") : ("Big", home)
        guard let source = rows.first(where: { $0.label == session }),
              let header = rows.first(where: { $0.label == goal.0 }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        runDrag(
            scenario, attempt: attempt, from: press(source.frame), path: [press(header.frame)],
            describe: "\(summary([session])) onto \(goal.0)", holdMs: 350,
            aim: { readRows().first(where: { $0.label == goal.0 }).map { press($0.frame) } },
            expected: { hostProjects()[session] == goal.1 },
            actual: { "the Host has it in \(hostProjects()[session] ?? "nothing"); \(layout(readRows()))" }
        )
    }
}

/// Filing a Session whose group is off screen: the drag holds at the list's top
/// edge until auto-scroll brings the group in, then drops on it. The trip back
/// home is its own scenario, so the report shows when one failed.
func runScrolledGroupDrop(count: Int) {
    let scenario = Scenario("scrolled-group-drop")
    let homeTrip = Scenario("scrolled-group-home")
    scenarios += [scenario, homeTrip]
    let session = "~/w/Big/big-05"
    let home = hostProjects()[session] ?? ""
    log("file \(summary([session])) into off-screen Beta x\(count)")
    func location() -> String { hostProjects()[session] ?? "nothing" }
    // From the top: auto-scroll can stop with Big just above the list.
    func sendHome(attempt: Int) {
        scrollToTop()
        let rows = readRows()
        guard let filed = rows.first(where: { $0.label == session }),
              let big = rows.first(where: { $0.label == "Big" }) else {
            homeTrip.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            return
        }
        runDrag(
            homeTrip, attempt: attempt, from: press(filed.frame), path: [press(big.frame)],
            describe: "\(summary([session])) back onto Big", holdMs: 350,
            aim: { readRows().first(where: { $0.label == "Big" }).map { press($0.frame) } },
            expected: { hostProjects()[session] == home },
            actual: { "the Host has it in \(location()); \(layout(readRows()))" }
        )
    }
    for attempt in 1 ... count {
        // A Session already in Beta would pass this drop without filing anything.
        if hostProjects()[session] != home {
            sendHome(attempt: attempt)
            guard hostProjects()[session] == home else {
                scenario.fail("drag \(attempt): \(summary([session])) isn't home, so a drop proves nothing: it is in \(location())")
                continue
            }
        }
        scrollToBottom()
        var rows = readRows()
        if !labels(rows).contains(session) {
            // A reorder that landed elsewhere left it nearer the top.
            scrollToTop()
            rows = readRows()
        }
        guard let source = rows.first(where: { $0.label == session }),
              let area = mainWindow().flatMap({ firstScrollArea(in: $0) }).flatMap({ frame(of: $0) }) else {
            scenario.fail("drag \(attempt): \(summary([session])) is not on screen: \(layout(rows))")
            continue
        }
        let edge = CGPoint(x: source.frame.minX + 6, y: area.minY + 6)
        runDrag(
            scenario, attempt: attempt, from: press(source.frame), path: [edge],
            describe: "\(summary([session])) onto Beta past the edge", holdMs: 350,
            aim: { readRows().first(where: { $0.label == "Beta" }).map { press($0.frame) } },
            aimWait: 12,
            expected: { hostProjects()[session] == "g-beta" },
            actual: { "the Host has it in \(location()); \(layout(readRows()))" }
        )
        if hostProjects()[session] == "g-beta" { sendHome(attempt: attempt) }
        Thread.sleep(forTimeInterval: 0.4)
    }
}

/// An open folder at the bottom of a scrolled list: closing it shortens the list,
/// so the list scrolls back under the pointer as the folder lifts. The folder still
/// lands where it's aimed, and open.
func runScrolledFolder(count: Int) {
    let scenario = Scenario("scrolled-folder")
    scenarios.append(scenario)
    log("scrolled-folder: swap open Pin-A and Pin-B at the bottom of a scrolled list x\(count)")
    guard let pins = hostProjectID(named: "Pins") else {
        scenario.fail("the Host has no project named Pins")
        return
    }
    scrollToBottom()
    nudge()
    setExpanded("Pins", children: pinsRows, true)
    var scrolledBack = 0
    for attempt in 1 ... count {
        scrollToBottom()
        nudge()
        let rows = readRows()
        guard let pair = placed(pinA, pinB, in: rows) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        let moved = pair.lower
        let target = pair.upper
        let from = press(moved.row.frame)
        // Aimed once, after the lift: the gap then moves the target from under it.
        var aimed: CGPoint?
        runDrag(
            scenario, attempt: attempt, from: from,
            path: [CGPoint(x: from.x, y: from.y - 8)],
            describe: "\(moved.folder.label) above \(target.folder.label)",
            aim: {
                if aimed == nil {
                    Thread.sleep(forTimeInterval: 0.15)
                    guard let now = readRows().first(where: { $0.label == target.folder.label }) else { return nil }
                    if abs(now.frame.minY - target.row.frame.minY) > 2 { scrolledBack += 1 }
                    aimed = CGPoint(x: from.x, y: now.frame.minY + 2)
                }
                return aimed
            },
            aimWait: 1,
            expected: {
                let now = labels(readRows())
                return isAbove(moved.folder.label, target.folder.label, in: now) == true
                    && isAbove(moved.folder.id, target.folder.id, in: hostRawOrder(of: pins)) == true
                    && isOpen(pinA, in: now) && isOpen(pinB, in: now)
            },
            drifted: { isAbove(moved.folder.label, target.folder.label, in: labels(readRows())) != true },
            actual: { "the Host has \(hostRawOrder(of: pins)); on screen \(layout(readRows()))" }
        )
    }
    if scrolledBack == 0 {
        scenario.fail("the list never scrolled back at a lift, so this proves nothing")
    }
}
