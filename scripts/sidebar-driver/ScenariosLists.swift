import AppKit

/// Every click on a group header flips it, and its rows all come or all go.
func runToggles(_ group: String, children: [String], count: Int) {
    let scenario = Scenario("toggle-\(group)")
    scenarios.append(scenario)
    log("toggle \(group) x\(count)")
    for attempt in 1 ... count {
        guard let header = readRows().first(where: { $0.label == group }) else {
            scenario.fail("click \(attempt): no \(group) row on screen")
            continue
        }
        let point = press(header.frame)
        guard ready(for: point) else {
            scenario.fail("click \(attempt): the app's window is not on top")
            continue
        }
        let before = Set(labels(readRows()))
        guard before.contains(group) else {
            scenario.fail("click \(attempt): no \(group) row on screen")
            continue
        }
        let wasExpanded = children.contains(where: before.contains)
        // A hung app reads as no rows at all, which isn't a collapse: the
        // header has to be there too.
        func applied() -> Bool {
            let now = Set(labels(readRows()))
            guard now.contains(group) else { return false }
            return wasExpanded ? !children.contains(where: now.contains) : children.allSatisfy(now.contains)
        }
        let started = Date()
        click(point)
        if waitUntil(seconds: 1.5, applied) {
            scenario.pass()
        } else {
            // Does it clear by itself, or only with another click? Asked once
            // per scenario: a stuck header would otherwise cost 6 s per click.
            let late = waitUntil(seconds: scenario.failed == 0 ? 6 : 0.3, applied)
            scenario.fail(
                "click \(attempt): \(group) stayed \(wasExpanded ? "expanded" : "collapsed")"
                    + (late ? "; it applied late" : "; still unchanged")
            )
        }
        let spare = 0.7 - Date().timeIntervalSince(started)
        if spare > 0 { Thread.sleep(forTimeInterval: spare) }
    }
}

/// The three groups' headers each toggle, and all three end up open for the drags.
func runGroupToggles(count: Int) {
    runToggles("Inner", children: innerChildren, count: count)
    if !Set(labels(readRows())).isSuperset(of: innerChildren), let inner = readRows().first(where: { $0.label == "Inner" }) {
        click(press(inner.frame))
        Thread.sleep(forTimeInterval: 0.7)
    }
    runToggles("Beta", children: betaChildren, count: count)
    runToggles("Alpha", children: alphaChildren, count: count)
    // Leave all three open for the drags, whatever state the toggles ended in.
    for (group, children) in [("Alpha", alphaChildren), ("Inner", innerChildren), ("Beta", betaChildren)] {
        let rows = readRows()
        if !Set(labels(rows)).isSuperset(of: children), let header = rows.first(where: { $0.label == group }) {
            click(press(header.frame))
            Thread.sleep(forTimeInterval: 0.8)
        }
    }
}

/// Reorder inside a group: the group's first row goes below its last. The
/// Host's order and the rows on screen both have to show it.
func runGroupReorder(count: Int) {
    let scenario = Scenario("group-reorder")
    scenarios.append(scenario)
    log("reorder inside Beta x\(count)")
    func rowsOfBeta() -> [String] {
        let all = labels(readRows())
        guard let start = all.firstIndex(of: "Beta") else { return [] }
        return all[(start + 1)...].filter(betaChildren.contains)
    }
    for attempt in 1 ... count {
        let rows = readRows()
        let order = rowsOfBeta()
        guard order.count == betaChildren.count,
              let first = rows.first(where: { $0.label == order[0] }),
              let last = rows.first(where: { $0.label == order[order.count - 1] }) else {
            scenario.fail("drag \(attempt): Beta's rows are not all on screen: \(layout(rows))")
            nudge()
            Thread.sleep(forTimeInterval: 1)
            continue
        }
        let expected = Array(order.dropFirst()) + [order[0]]
        let target = CGPoint(x: first.frame.minX + 6, y: last.frame.midY)
        runDrag(
            scenario, attempt: attempt, from: press(first.frame), path: [target],
            describe: "\(summary([order[0]])) below \(summary([order[order.count - 1]]))",
            expected: { hostOrder(of: "g-beta") == expected && rowsOfBeta() == expected },
            actual: { "the Host has \(summary(hostOrder(of: "g-beta"))); on screen \(layout(readRows()))" }
        )
    }
}

func rowsOfBig() -> [String] { labels(readRows()).filter { $0.hasPrefix("~/w/Big/big-") } }

/// Reorder in a project's own list, past no folder: one Session moves down two
/// rows, then back up. The Host's order and the rows on screen both show it.
func runListReorder(count: Int) {
    let scenario = Scenario("list-reorder")
    scenarios.append(scenario)
    let session = "~/w/Big/big-05"
    let home = hostProjects()[session] ?? ""
    log("reorder \(summary([session])) in Big's own list x\(count)")
    for attempt in 1 ... count {
        let rows = readRows()
        let order = rowsOfBig()
        guard let from = order.firstIndex(of: session),
              let source = rows.first(where: { $0.label == session }) else {
            scenario.fail("drag \(attempt): \(summary([session])) is not on screen: \(layout(rows))")
            nudge()
            Thread.sleep(forTimeInterval: 1)
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
            expected: {
                hostOrder(of: home).filter { $0.hasPrefix("~/w/Big/big-") } == expected && rowsOfBig() == expected
            },
            actual: { "the Host has \(summary(hostOrder(of: home))); on screen \(layout(readRows()))" }
        )
    }
}

/// Filing a Session: from its project's own list onto a group header, then
/// from the group back onto the project's header.
func runGroupDrop(count: Int) {
    let scenario = Scenario("group-drop")
    scenarios.append(scenario)
    let session = "~/w/Big/big-02"
    let home = hostProjects()[session] ?? ""
    log("file \(summary([session])) into Beta and back x\(count)")
    for attempt in 1 ... count {
        let rows = readRows()
        let goal = hostProjects()[session] == home ? ("Beta", "g-beta") : ("Big", home)
        guard let source = rows.first(where: { $0.label == session }),
              let header = rows.first(where: { $0.label == goal.0 }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            nudge()
            Thread.sleep(forTimeInterval: 1)
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

/// Out of the sidebar and back: the row lifts, leaves, returns, and lands
/// where it started.
func runDragOutAndBack(count: Int) {
    let scenario = Scenario("out-and-back")
    scenarios.append(scenario)
    let session = "~/w/Big/inner-2"
    log("drag \(summary([session])) out and back x\(count)")
    for attempt in 1 ... count {
        let rows = readRows()
        guard let source = rows.first(where: { $0.label == session }),
              let window = mainWindow().flatMap(frame(of:)) else {
            scenario.fail("drag \(attempt): the row is not on screen")
            continue
        }
        let order = labels(rows)
        let home = press(source.frame)
        let outside = CGPoint(x: window.minX + 700, y: home.y)
        runDrag(
            scenario, attempt: attempt, from: home, path: [outside, home],
            describe: "\(summary([session])) out and back",
            expected: { labels(readRows()) == order && hostProjects()[session] == "g-inner" },
            actual: { layout(readRows()) }
        )
    }
}

/// Quiet goes around Small, which is expanded: above aims at Small's header,
/// below at its last row, where #45 pins each gap. The direction comes from
/// where Quiet is, so no attempt asks for the order it already has. The rows on
/// screen and the order the Host wrote both have to show it.
func runProjectReorder(count: Int) {
    let scenario = Scenario("project-reorder")
    scenarios.append(scenario)
    let moved = "Quiet", target = "Small"
    log("project-reorder: \(moved) above and below \(target) x\(count)")
    func isAbove(_ order: [String]) -> Bool? {
        guard let first = order.firstIndex(of: moved), let second = order.firstIndex(of: target) else { return nil }
        return first < second
    }
    for attempt in 1 ... count {
        let rows = readRows()
        guard let source = rows.first(where: { $0.label == moved }),
              let header = rows.first(where: { $0.label == target }),
              let last = rows.last(where: { $0.label == target || smallChildren.contains($0.label) }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        let goAbove = source.frame.midY > header.frame.midY
        let aimY = goAbove ? header.frame.minY + 2 : last.frame.maxY - 2
        runDrag(
            scenario, attempt: attempt, from: press(source.frame),
            path: [CGPoint(x: source.frame.minX + 6, y: aimY)],
            describe: "\(moved) \(goAbove ? "above \(target)" : "below \(target)'s last row")",
            expected: { isAbove(labels(readRows())) == goAbove && isAbove(hostProjectOrder()) == goAbove },
            actual: { "the Host has \(hostProjectOrder()); on screen \(layout(readRows()))" }
        )
    }
}

/// The card stays in front of the app's window from the release until it lands.
/// The window orders itself to the front at mouse-up, and a card behind it leaves
/// an empty slot for the length of the flight home.
func runDropCard(count: Int) {
    let scenario = Scenario("drop-card")
    scenarios.append(scenario)
    let moved = "~/w/Big/big-05", target = "~/w/Big/big-03"
    log("drop-card: the card stays in front as \(summary([moved])) lands x\(count)")
    for attempt in 1 ... count {
        nudge() // The row under the pointer reads as missing.
        let rows = readRows()
        guard let source = rows.first(where: { $0.label == moved }),
              let goal = rows.first(where: { $0.label == target }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        let from = press(source.frame)
        var looks = 0
        var behind = 0
        runDrag(
            scenario, attempt: attempt, from: from, path: [CGPoint(x: from.x, y: goal.frame.midY)],
            describe: "\(summary([moved])) onto \(summary([target]))",
            afterRelease: { before in
                looks = 0
                behind = 0
                let end = Date().addingTimeInterval(0.6)
                while Date() < end {
                    let now = appWindowsFrontToBack()
                    if let card = now.first(where: { !before.contains($0) }) {
                        looks += 1
                        if now.first != card { behind += 1 }
                    } else if looks > 0 {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            },
            expected: { looks > 0 && behind == 0 },
            actual: { "the card was behind the app's window in \(behind) of \(looks) looks" }
        )
    }
    nudge()
}
