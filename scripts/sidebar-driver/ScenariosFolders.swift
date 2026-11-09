import AppKit

/// Two open folders side by side swap places: the one going up, or the other
/// going down. It closes as it lifts and both are open once it lands.
func swapOpenFolders(
    _ scenario: Scenario, attempt: Int, list: String, _ one: Folder, _ two: Folder, goingUp: Bool
) {
    let rows = readRows()
    guard let pair = placed(one, two, in: rows) else {
        scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
        return
    }
    let moved = goingUp ? pair.lower : pair.upper
    let target = goingUp ? pair.upper : pair.lower
    guard let index = rows.firstIndex(where: { $0.label == moved.folder.label }), index + 1 < rows.count else {
        scenario.fail("drag \(attempt): nothing below \(moved.folder.label): \(layout(rows))")
        return
    }
    // Going down, the block leaves as it lifts, and the target's header comes up
    // to the row right under the moved header. That's where a person aims.
    let aimY = goingUp ? target.row.frame.minY + 2 : rows[index + 1].frame.midY
    var inTheAir: [String] = []
    dragIntoPlace(
        scenario, attempt: attempt, list: list,
        moved: moved.row, movedID: moved.folder.id,
        target: target.row, targetID: target.folder.id,
        aimY: aimY,
        whileHeld: { inTheAir = labels(readRows()) },
        landed: {
            let now = labels(readRows())
            return isOpen(one, in: now) && isOpen(two, in: now)
        }
    )
    if moved.folder.block.contains(where: inTheAir.contains) {
        scenario.fail("drag \(attempt): \(moved.folder.label) stayed open in the air: \(summary(inTheAir))")
    }
}

/// Swaps two open folders, up and down in turn, ending with `two` above.
func runOpenSwaps(_ scenario: Scenario, list: String, _ one: Folder, _ two: Folder, count: Int) {
    for attempt in 1 ... count {
        swapOpenFolders(scenario, attempt: attempt, list: list, one, two, goingUp: attempt % 2 == 1)
    }
    if isAbove(two.label, one.label, in: labels(readRows())) != true {
        swapOpenFolders(scenario, attempt: count + 1, list: list, one, two, goingUp: true)
    }
}

/// An open folder drags like a closed one: every drag swaps it with its sibling,
/// so none can pass by leaving things as they were.
func runOpenFolderMoves(count: Int) {
    let scenario = Scenario("folder-expanded")
    scenarios.append(scenario)
    log("folder-expanded: swap open Alpha and Beta x\(count), up and down, ending with Beta above")
    guard let big = hostProjectID(named: "Big") else {
        scenario.fail("the Host has no project named Big")
        return
    }
    runOpenSwaps(scenario, list: big, alphaFolder, betaFolder, count: count)
}

/// The run's last word on Big's order comes from open folders, so that's what a
/// relaunch checks. Each goes up in turn, which needs nothing about what sits
/// between them, and it ends with Beta above, which isn't the default order.
func runOpenFolderLastMoves() {
    let scenario = Scenario("folder-expanded-last")
    scenarios.append(scenario)
    log("folder-expanded-last: open Alpha above Beta, then open Beta above Alpha")
    guard let big = hostProjectID(named: "Big") else {
        scenario.fail("the Host has no project named Big")
        return
    }
    for attempt in 1 ... 2 {
        swapOpenFolders(scenario, attempt: attempt, list: big, alphaFolder, betaFolder, goingUp: true)
    }
}

/// A cancelled drag changes nothing: released outside the sidebar or with Esc, a
/// folder comes back in its place, open if it was open and closed if it was
/// closed, and the Host never hears of it.
func runFolderCancel(count: Int) {
    let scenario = Scenario("folder-cancel")
    scenarios.append(scenario)
    log("folder-cancel: drag open and closed Beta, cancelling each way, x\(count)")
    let escape: CGKeyCode = 53
    guard let big = hostProjectID(named: "Big") else {
        scenario.fail("the Host has no project named Big")
        return
    }
    func cancelOnce(attempt: Int, state: String, withEscape: Bool) {
        let rows = readRows()
        guard let beta = rows.first(where: { $0.label == "Beta" }),
              let window = mainWindow().flatMap(frame(of:)) else {
            scenario.fail("drag \(attempt): Beta is not on screen: \(layout(rows))")
            return
        }
        let home = press(beta.frame)
        dragStaysPut(
            scenario, attempt: attempt, list: big, rows: rows, from: home,
            to: withEscape ? CGPoint(x: home.x, y: home.y + 40) : CGPoint(x: window.minX + 700, y: home.y),
            describe: "\(state) Beta, \(withEscape ? "Esc" : "released outside the sidebar")",
            whileHeld: withEscape ? { pressKey(keyCode: escape) } : nil
        )
        if withEscape { Thread.sleep(forTimeInterval: keyInputHold) }
    }
    setExpanded("Beta", children: betaChildren, true)
    for attempt in 1 ... count { cancelOnce(attempt: attempt, state: "open", withEscape: attempt % 2 == 0) }
    setExpanded("Beta", children: betaChildren, false)
    for attempt in 1 ... count { cancelOnce(attempt: attempt, state: "closed", withEscape: attempt % 2 == 0) }
    setExpanded("Beta", children: betaChildren, true)
}

/// A closed folder swaps places with its sibling. Every drag changes the
/// order, so none can pass by leaving things as they were, and the run ends with
/// Beta above Alpha, which isn't the default order, so a relaunch has something
/// to lose. It's the dragged row that has to be collapsed: the sibling can be
/// either.
func runFolderReorder(_ name: String, count: Int) {
    let scenario = Scenario(name)
    scenarios.append(scenario)
    log("\(name): swap Beta and Alpha x\(count), ending with Beta above")
    guard let big = hostProjectID(named: "Big") else {
        scenario.fail("the Host has no project named Big")
        return
    }
    func swapOnce(attempt: Int) {
        let rows = readRows()
        guard let alpha = rows.first(where: { $0.label == "Alpha" }),
              let beta = rows.first(where: { $0.label == "Beta" }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            return
        }
        let betaIsBelow = beta.frame.midY > alpha.frame.midY
        let target = betaIsBelow ? alpha : beta
        dragIntoPlace(
            scenario, attempt: attempt, list: big,
            moved: betaIsBelow ? beta : alpha, movedID: betaIsBelow ? "g-beta" : "g-alpha",
            target: target, targetID: betaIsBelow ? "g-alpha" : "g-beta",
            aimY: target.frame.minY + 2,
            landed: {
                let now = Set(labels(readRows()))
                return now.isDisjoint(with: alphaChildren) && now.isDisjoint(with: betaChildren)
            }
        )
    }
    for attempt in 1 ... count { swapOnce(attempt: attempt) }
    if isAbove("Beta", "Alpha", in: labels(readRows())) != true { swapOnce(attempt: count + 1) }
}

/// A collapsed Beta past an expanded Alpha: only Beta can drag, so each drag takes
/// Alpha's header slot, and the run ends with Beta above.
func runBetaPastExpandedAlpha(count: Int) {
    let scenario = Scenario("folder-past-expanded")
    scenarios.append(scenario)
    log("folder-past-expanded: collapsed Beta past an expanded Alpha x\(count)")
    guard let big = hostProjectID(named: "Big") else {
        scenario.fail("the Host has no project named Big")
        return
    }
    func dragOnce(attempt: Int) {
        let rows = readRows()
        guard let beta = rows.first(where: { $0.label == "Beta" }),
              let alpha = rows.first(where: { $0.label == "Alpha" }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            return
        }
        dragIntoPlace(
            scenario, attempt: attempt, list: big,
            moved: beta, movedID: "g-beta",
            target: alpha, targetID: "g-alpha",
            aimY: alpha.frame.minY + 2
        )
    }
    for attempt in 1 ... count { dragOnce(attempt: attempt) }
    if isAbove("Beta", "Alpha", in: labels(readRows())) != true { dragOnce(attempt: count + 1) }
}

/// The Session on the row right below a folder.
func sessionBelow(_ folder: String, in rows: [Row]) -> HostSession? {
    guard let index = rows.firstIndex(where: { $0.label == folder }), index + 1 < rows.count else { return nil }
    return hostSessions().first { $0.label == rows[index + 1].label }
}

/// A folder is a slot like any other in the list: one moves past the Session
/// below it, and back.
func runFolderPastSession(count: Int) {
    let scenario = Scenario("folder-past-session")
    scenarios.append(scenario)
    log("folder-past-session: Alpha past the Session below it, and back, x\(count)")
    let rows = readRows()
    guard let big = hostProjectID(named: "Big"), let session = sessionBelow("Alpha", in: rows) else {
        scenario.fail("no Session below Alpha: \(layout(rows))")
        return
    }
    for attempt in 1 ... count {
        let now = readRows()
        guard let alpha = now.first(where: { $0.label == "Alpha" }),
              let target = now.first(where: { $0.label == session.label }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(now))")
            continue
        }
        dragIntoPlace(
            scenario, attempt: attempt, list: big,
            moved: alpha, movedID: "g-alpha",
            target: target, targetID: session.id,
            aimY: target.frame.midY
        )
    }
}

/// A Session dropped above a folder stays above it, on a list that ranked no
/// folder before the drop. The bands at a folder's edges place a Session beside
/// the folder, not in it.
func runSessionAboveFolder(count: Int) {
    let scenario = Scenario("session-above-folder")
    scenarios.append(scenario)
    log("session-above-folder: the Session below Beta goes above it, and back, x\(count)")
    let rows = readRows()
    guard let big = hostProjectID(named: "Big"), let session = sessionBelow("Beta", in: rows) else {
        scenario.fail("no Session below Beta: \(layout(rows))")
        return
    }
    guard !hostRawOrder(of: big).contains("g-beta") else {
        scenario.fail("the list already ranks a folder, so this proves nothing: \(hostRawOrder(of: big))")
        return
    }
    for attempt in 1 ... count {
        let now = readRows()
        guard let beta = now.first(where: { $0.label == "Beta" }),
              let moved = now.first(where: { $0.label == session.label }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(now))")
            continue
        }
        dragIntoPlace(
            scenario, attempt: attempt, list: big,
            moved: moved, movedID: session.id,
            target: beta, targetID: "g-beta",
            aimY: moved.frame.midY > beta.frame.midY ? beta.frame.minY + 2 : beta.frame.maxY - 2
        )
    }
}

/// A Session from a group, dropped into a slot of its parent's list, lands there
/// and leaves that list's folders unranked. Each odd drag goes out, each even one
/// files it back into its group.
func runCrossProjectInsert(count: Int) {
    let scenario = Scenario("cross-project-insert")
    scenarios.append(scenario)
    let label = "~/w/Big/beta-1"
    log("cross-project-insert: \(summary([label])) into a slot of Big's list, and back, x\(count)")
    guard let big = hostProjectID(named: "Big"),
          let session = hostSessions().first(where: { $0.label == label }) else {
        scenario.fail("the Host has no Big, or no \(summary([label]))")
        return
    }
    for attempt in 1 ... count {
        let rows = readRows()
        let goingOut = hostProjects()[label] == "g-beta"
        guard let source = rows.first(where: { $0.label == label }),
              let target = rows.first(where: { $0.label == (goingOut ? "~/w/Big/big-05" : "Beta") }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        runDrag(
            scenario, attempt: attempt, from: press(source.frame),
            path: [goingOut ? CGPoint(x: target.frame.minX + 6, y: target.frame.midY) : press(target.frame)],
            describe: goingOut ? "\(summary([label])) into Big's list" : "\(summary([label])) back into Beta",
            holdMs: 350,
            expected: {
                let order = hostRawOrder(of: big)
                guard goingOut else { return hostProjects()[label] == "g-beta" }
                return hostProjects()[label] == big && order.contains(session.id)
                    && !order.contains("g-alpha") && !order.contains("g-beta")
            },
            actual: { "it's in \(hostProjects()[label] ?? "nothing"); Big's order is \(hostRawOrder(of: big))" }
        )
    }
}

/// Session-only drags leave a list's folders unranked: a list that ranks one
/// renders new Sessions above the folders.
func checkFoldersUnranked() {
    let scenario = Scenario("folders-unranked")
    scenarios.append(scenario)
    guard let big = hostProjectID(named: "Big") else {
        scenario.fail("the Host has no project named Big")
        return
    }
    let order = hostRawOrder(of: big)
    if order.contains("g-alpha") || order.contains("g-beta") {
        scenario.fail("Session drags ranked a folder: \(order)")
    } else {
        scenario.pass()
    }
}

/// Every way a folder moves in Big's list, open and closed, ending with both open.
func runFolderMoves(count: Int) {
    runOpenFolderMoves(count: count)
    setExpanded("Alpha", children: alphaChildren, false)
    setExpanded("Beta", children: betaChildren, false)
    runFolderReorder("folder-collapsed", count: count)
    runFolderPastSession(count: min(count, 6))
    setExpanded("Alpha", children: alphaChildren, true)
    runBetaPastExpandedAlpha(count: count)
    setExpanded("Beta", children: betaChildren, true)
    runOpenFolderLastMoves()
}

func setExpanded(_ group: String, children: [String], _ expanded: Bool) {
    let rows = readRows()
    guard Set(labels(rows)).isSuperset(of: children) != expanded,
          let header = rows.first(where: { $0.label == group }) else { return }
    click(press(header.frame))
    Thread.sleep(forTimeInterval: 0.8)
}
