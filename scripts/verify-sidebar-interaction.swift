// verify-sidebar-interaction.swift — the driver behind
// verify-sidebar-interaction.sh. It clicks and drags PROJECTS rows in a
// running dev app with real pointer events and checks every step against the
// app's accessibility tree and the Host's session list.
//
//   driver prepare --pid P
//   driver run --pid P --ls <script> --order-file F [--clicks N] [--drags N] [--only a,b] [--report F]
//
// It never fights the user: it starts only after the machine has been quiet,
// and any pointer motion or key press it did not make pauses the run, releases
// the button in place, and resumes after the user has been quiet again.
import AppKit
import ApplicationServices

// MARK: - Arguments

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? ""
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
guard let pidValue = option("--pid").flatMap({ pid_t($0) }) else {
    print("usage: driver prepare|run --pid P [--ls script] [--clicks N] [--drags N] [--only a,b] [--report F]")
    exit(2)
}
let pid = pidValue
let clickCount = option("--clicks").flatMap(Int.init) ?? 30
let dragCount = option("--drags").flatMap(Int.init) ?? 20
let only = option("--only").map { Set($0.split(separator: ",").map(String.init)) }
let listScript = option("--ls")
let reportPath = option("--report")
let quietSeconds = option("--quiet").flatMap(Double.init) ?? 20

func log(_ line: String) {
    print(line)
    fflush(stdout)
}

// MARK: - Accessibility

let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute),
          let size = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    // swiftlint:disable:next force_cast
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    // swiftlint:disable:next force_cast
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    guard origin.x.isFinite, origin.y.isFinite, extent.width.isFinite, extent.height.isFinite else { return nil }
    return CGRect(origin: origin, size: extent)
}

func mainWindow() -> AXUIElement? {
    let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    return windows.max { (frame(of: $0)?.height ?? 0) < (frame(of: $1)?.height ?? 0) }
}

func firstScrollArea(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if (attribute(element, kAXRoleAttribute) as? String) == "AXScrollArea" { return element }
    guard depth < 12 else { return nil }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if let found = firstScrollArea(in: child, depth: depth + 1) { return found }
    }
    return nil
}

struct Row {
    let label: String
    let frame: CGRect
}

/// The PROJECTS rows on screen, top to bottom: one per title text.
func readRows() -> [Row] {
    guard let window = mainWindow(), let area = firstScrollArea(in: window),
          let visible = frame(of: area) else { return [] }
    var rows: [Row] = []
    func walk(_ element: AXUIElement, _ depth: Int) {
        if (attribute(element, kAXRoleAttribute) as? String) == "AXStaticText",
           let text = (attribute(element, kAXValueAttribute) as? String)
           ?? (attribute(element, kAXTitleAttribute) as? String),
           text != "›", !text.isEmpty, let rect = frame(of: element),
           rect.midY > visible.minY, rect.midY < visible.maxY {
            rows.append(Row(label: text, frame: rect))
        }
        guard depth < 14 else { return }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(child, depth + 1)
        }
    }
    walk(area, 0)
    return rows.sorted { $0.frame.midY < $1.frame.midY }
}

// MARK: - Staying out of the user's way

let anyInput = CGEventType(rawValue: ~0)!

func screenIsLocked() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
}

/// The last place this tool put the pointer; nil before its first event.
var lastPosted: CGPoint?
var pauses = 0

func userInterfered() -> Bool {
    if screenIsLocked() { return true }
    if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 2 { return true }
    guard let last = lastPosted, let now = CGEvent(source: nil)?.location else { return false }
    return abs(now.x - last.x) > 2 || abs(now.y - last.y) > 2
}

/// Blocks until nothing but this tool has touched the machine for `quietSeconds`.
func waitForQuiet() {
    var announced = false
    while screenIsLocked()
        || CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput) < quietSeconds {
        if !announced {
            log("  waiting for \(Int(quietSeconds)) s of quiet (screen locked: \(screenIsLocked()))")
            announced = true
        }
        Thread.sleep(forTimeInterval: 1)
    }
    lastPosted = CGEvent(source: nil)?.location
}

func topWindowOwner(at point: CGPoint) -> pid_t? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let top = windows.first { window in
        guard (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return rect.contains(point)
    }
    return top?[kCGWindowOwnerPID as String] as? pid_t
}

/// Waits out any interference, then makes sure the app's window is what a
/// press at `point` will hit. False when it cannot get there.
func ready(for point: CGPoint) -> Bool {
    if userInterfered() {
        pauses += 1
        log("  input from the user: pausing")
        waitForQuiet()
    }
    for _ in 0 ..< 6 {
        if topWindowOwner(at: point) == pid { return true }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}

// MARK: - Pointer

var lastClick: (at: Date, point: CGPoint, count: Int)?

func post(_ type: CGEventType, _ point: CGPoint, clicks: Int64 = 0) {
    guard let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left
    ) else { return }
    if clicks > 0 { event.setIntegerValueField(.mouseEventClickState, value: clicks) }
    event.post(tap: .cghidEventTap)
    lastPosted = point
}

/// A click the way hardware reports it: a second click soon after in the same
/// spot carries click count 2.
func click(_ point: CGPoint) {
    post(.mouseMoved, point)
    Thread.sleep(forTimeInterval: 0.09)
    var count = 1
    if let last = lastClick, Date().timeIntervalSince(last.at) < NSEvent.doubleClickInterval,
       abs(last.point.x - point.x) < 4, abs(last.point.y - point.y) < 4 {
        count = last.count + 1
    }
    post(.leftMouseDown, point, clicks: Int64(count))
    Thread.sleep(forTimeInterval: 0.07)
    post(.leftMouseUp, point, clicks: Int64(count))
    lastClick = (Date(), point, count)
}

func appWindowNumbers() -> Set<Int> {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(windows.compactMap { window in
        (window[kCGWindowOwnerPID as String] as? pid_t) == pid ? window[kCGWindowNumber as String] as? Int : nil
    })
}

enum DragResult {
    case finished(lifted: Bool)
    case interrupted
}

/// Presses at `from`, travels through `path` at a human pace, holds, releases.
/// `lifted` says the floating card window appeared.
///
/// Rows part around a drag, so a target moves under it. `aim`, when given, is
/// asked for the target's current spot after the path, and the pointer follows,
/// the way a person aims at what they see.
func drag(
    from: CGPoint, path: [CGPoint], holdMs: Int = 200, aim: (() -> CGPoint?)? = nil, aimWait: Double = 0
) -> DragResult {
    let windowsBefore = appWindowNumbers()
    post(.mouseMoved, from)
    Thread.sleep(forTimeInterval: 0.12)
    post(.leftMouseDown, from, clicks: 1)
    Thread.sleep(forTimeInterval: 0.1)
    lastClick = nil
    var lifted = false
    var current = from
    for target in path {
        let steps = max(1, Int(hypot(target.x - current.x, target.y - current.y) / 5))
        let start = current
        for step in 1 ... steps {
            if userInterfered() {
                post(.leftMouseUp, CGEvent(source: nil)?.location ?? current)
                return .interrupted
            }
            let t = CGFloat(step) / CGFloat(steps)
            current = CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
            post(.leftMouseDragged, current)
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
        }
        lifted = lifted || !appWindowNumbers().subtracting(windowsBefore).isEmpty
    }
    if let aim {
        // Hold where the path ended until the target comes into view.
        let waitEnd = Date().addingTimeInterval(aimWait)
        while aim() == nil, Date() < waitEnd, !userInterfered() {
            post(.leftMouseDragged, current)
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Follow it until it stops moving: rows part, and auto-scroll may run on.
        var settled = 0
        for _ in 0 ..< 16 where settled < 2 {
            Thread.sleep(forTimeInterval: 0.25)
            guard let target = aim(), !userInterfered() else { break }
            let distance = hypot(target.x - current.x, target.y - current.y)
            settled = distance < 2 ? settled + 1 : 0
            let steps = max(1, Int(distance / 5))
            let start = current
            for step in 1 ... steps {
                let t = CGFloat(step) / CGFloat(steps)
                current = CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
                post(.leftMouseDragged, current)
                Thread.sleep(forTimeInterval: 1.0 / 60.0)
            }
        }
    }
    let holdEnd = Date().addingTimeInterval(Double(holdMs) / 1000)
    while Date() < holdEnd {
        post(.leftMouseDragged, current)
        Thread.sleep(forTimeInterval: 1.0 / 30.0)
    }
    lifted = lifted || !appWindowNumbers().subtracting(windowsBefore).isEmpty
    post(.leftMouseUp, current)
    return .finished(lifted: lifted)
}

// MARK: - Results

final class Scenario {
    let name: String
    var passed = 0
    var failed = 0
    var details: [String] = []
    init(_ name: String) { self.name = name }

    func pass() { passed += 1 }
    func fail(_ detail: String) {
        failed += 1
        details.append(detail)
        log("  FAIL \(name) #\(passed + failed): \(detail)")
    }
}

var scenarios: [Scenario] = []
func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }

func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < end
    return condition()
}

func press(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + 6, y: rect.midY) }
func labels(_ rows: [Row]) -> [String] { rows.map(\.label) }
/// Each row with its indent, for a failure report.
func layout(_ rows: [Row]) -> String {
    let left = rows.map(\.frame.minX).min() ?? 0
    return rows.map { "\(summary([$0.label]))@\(Int($0.frame.minX - left))" }.joined(separator: " ")
}
func summary(_ names: [String]) -> String {
    names.map { $0.replacingOccurrences(of: "~/w/Big/", with: "") }.joined(separator: " ")
}

/// Rows strictly between two rows, the children of a group that ends at `end`.
func between(_ rows: [String], _ start: String, _ end: String?) -> [String] {
    guard let from = rows.firstIndex(of: start) else { return [] }
    let tail = rows[(from + 1)...]
    guard let end, let to = tail.firstIndex(of: end) else { return Array(tail) }
    return Array(tail[..<to])
}

struct HostSession {
    let id: String
    let label: String
    let projectID: String
}

/// What the Host persisted: each Session's project, from its manifest.
func hostSessions() -> [HostSession] {
    guard let listScript else { return [] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: listScript)
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    return list.compactMap { session in
        guard let id = session["id"] as? String, let cwd = session["cwd"] as? String,
              let project = session["project_id"] as? String else { return nil }
        return HostSession(id: id, label: "~/w/Big/" + (cwd as NSString).lastPathComponent, projectID: project)
    }
}

func hostProjects() -> [String: String] {
    Dictionary(uniqueKeysWithValues: hostSessions().map { ($0.label, $0.projectID) })
}

/// The order the Host persisted for one list, as row labels.
func hostOrder(of projectID: String) -> [String] {
    guard let orderPath = option("--order-file"),
          let data = FileManager.default.contents(atPath: orderPath),
          let orders = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String]] else { return [] }
    let labels = Dictionary(uniqueKeysWithValues: hostSessions().map { ($0.id, $0.label) })
    return (orders[projectID] ?? []).compactMap { labels[$0] }
}

/// Moves the pointer off the rows. A hovered row's title leaves the
/// accessibility tree's flat text, so the row under the pointer reads as missing.
func nudge() {
    guard let window = mainWindow().flatMap({ frame(of: $0) }) else { return }
    post(.mouseMoved, CGPoint(x: window.minX + 700, y: window.midY))
    Thread.sleep(forTimeInterval: 0.15)
}

/// Blocks until the rows' positions have held still for a moment: a wheel
/// scroll keeps moving after its last event.
func waitForStillRows() {
    var last = readRows().map(\.frame.minY)
    var still = 0
    for _ in 0 ..< 60 where still < 4 {
        Thread.sleep(forTimeInterval: 0.1)
        let now = readRows().map(\.frame.minY)
        still = now == last ? still + 1 : 0
        last = now
    }
}

// MARK: - Scenarios

let alphaChildren = ["Inner", "~/w/Big/alpha-3", "~/w/Big/alpha-2", "~/w/Big/alpha-1"]
let betaChildren = ["~/w/Big/beta-3", "~/w/Big/beta-2", "~/w/Big/beta-1"]
let innerChildren = ["~/w/Big/inner-1", "~/w/Big/inner-2"]

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
        let wasExpanded = children.contains(where: before.contains)
        let started = Date()
        click(point)
        let settled = waitUntil(seconds: 1.5) {
            let now = Set(labels(readRows()))
            return wasExpanded ? !children.contains(where: now.contains) : children.allSatisfy(now.contains)
        }
        if settled {
            scenario.pass()
        } else {
            // Does it clear by itself, or only with another click? Asked once
            // per scenario: a stuck header would otherwise cost 6 s per click.
            let late = waitUntil(seconds: scenario.failed == 0 ? 6 : 0.3) {
                let now = Set(labels(readRows()))
                return wasExpanded ? !children.contains(where: now.contains) : children.allSatisfy(now.contains)
            }
            scenario.fail(
                "click \(attempt): \(group) stayed \(wasExpanded ? "expanded" : "collapsed")"
                    + (late ? "; it applied late" : "; still unchanged")
            )
        }
        let spare = 0.7 - Date().timeIntervalSince(started)
        if spare > 0 { Thread.sleep(forTimeInterval: spare) }
    }
}

/// One drag whose result is `expected()`. A drag the user interrupted is retried.
func runDrag(
    _ scenario: Scenario,
    attempt: Int,
    from: CGPoint,
    path: [CGPoint],
    describe: String,
    holdMs: Int = 200,
    aim: (() -> CGPoint?)? = nil,
    aimWait: Double = 0,
    expected: @escaping () -> Bool,
    actual: () -> String
) {
    for _ in 0 ..< 5 {
        guard ready(for: from) else {
            scenario.fail("drag \(attempt): the app's window is not on top")
            return
        }
        switch drag(from: from, path: path, holdMs: holdMs, aim: aim, aimWait: aimWait) {
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
                scenario.pass()
            } else {
                scenario.fail("drag \(attempt): \(describe): landed wrong: \(actual())")
            }
            Thread.sleep(forTimeInterval: 0.35)
            return
        }
    }
    scenario.fail("drag \(attempt): \(describe): interrupted five times")
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

/// Reorder in a project's own list, past no folder: one Session moves down two
/// rows, then back up. The Host's order and the rows on screen both show it.
func runListReorder(count: Int) {
    let scenario = Scenario("list-reorder")
    scenarios.append(scenario)
    let session = "~/w/Big/big-05"
    let home = hostProjects()[session] ?? ""
    log("reorder \(summary([session])) in Big's own list x\(count)")
    func rowsOfBig() -> [String] { labels(readRows()).filter { $0.hasPrefix("~/w/Big/big-") } }
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

/// Wheel-scrolls the list to one end, with the pointer over it.
func scroll(by pixels: Int32) {
    guard let area = mainWindow().flatMap({ firstScrollArea(in: $0) }).flatMap({ frame(of: $0) }) else { return }
    post(.mouseMoved, CGPoint(x: area.midX, y: area.midY))
    Thread.sleep(forTimeInterval: 0.1)
    for _ in 0 ..< 12 {
        CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0
        )?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
    nudge()
    waitForStillRows()
}

func scrollToBottom() { scroll(by: -300) }
func scrollToTop() { scroll(by: 300) }

/// The same reorder as `runListReorder`, in a list scrolled to its end: the
/// rows at the top are unmounted by then.
func runScrolledListReorder(count: Int) {
    let scenario = Scenario("scrolled-list-reorder")
    scenarios.append(scenario)
    let session = "~/w/Big/big-05"
    let home = hostProjects()[session] ?? ""
    log("reorder \(summary([session])) in a scrolled list x\(count)")
    func rowsOfBig() -> [String] { labels(readRows()).filter { $0.hasPrefix("~/w/Big/big-") } }
    for attempt in 1 ... count {
        scrollToBottom()
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
        // The whole list, since the visible rows are only part of what's ordered.
        let before = hostOrder(of: home).filter { $0.hasPrefix("~/w/Big/big-") }
        runDrag(
            scenario, attempt: attempt, from: press(source.frame),
            path: [CGPoint(x: source.frame.minX + 6, y: anchor.frame.midY)],
            describe: "\(summary([session])) to \(summary([order[to]]))'s place",
            expected: {
                let host = hostOrder(of: home).filter { $0.hasPrefix("~/w/Big/big-") }
                guard let index = host.firstIndex(of: session) else { return false }
                return before.firstIndex(of: session).map { abs($0 - index) == 2 } ?? (host != before)
            },
            actual: { "the Host has \(summary(hostOrder(of: home))); on screen \(layout(readRows()))" }
        )
    }
}

/// A row that scrolled away and back still lifts and reorders. A row missing
/// from the drag registry looks fine and ignores the press.
func runScrolledBackReorder(count: Int) {
    let scenario = Scenario("scrolled-back-reorder")
    scenarios.append(scenario)
    let session = "~/w/Big/big-28"
    let home = hostProjects()[session] ?? ""
    log("reorder \(summary([session])) after scrolling away and back x\(count)")
    func rowsOfBig() -> [String] { labels(readRows()).filter { $0.hasPrefix("~/w/Big/big-") } }
    for attempt in 1 ... count {
        scrollToBottom()
        scrollToTop()
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
        let before = hostOrder(of: home).filter { $0.hasPrefix("~/w/Big/big-") }
        runDrag(
            scenario, attempt: attempt, from: press(source.frame),
            path: [CGPoint(x: source.frame.minX + 6, y: anchor.frame.midY)],
            describe: "\(summary([session])) to \(summary([order[to]]))'s place",
            expected: {
                let host = hostOrder(of: home).filter { $0.hasPrefix("~/w/Big/big-") }
                guard let index = host.firstIndex(of: session) else { return false }
                return before.firstIndex(of: session).map { abs($0 - index) == 2 } ?? (host != before)
            },
            actual: { "the Host has \(summary(hostOrder(of: home)))" }
        )
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
/// edge until auto-scroll brings the group in, then drops on it.
func runScrolledGroupDrop(count: Int) {
    let scenario = Scenario("scrolled-group-drop")
    scenarios.append(scenario)
    let session = "~/w/Big/big-05"
    let home = hostProjects()[session] ?? ""
    log("file \(summary([session])) into off-screen Beta x\(count)")
    for attempt in 1 ... count {
        scrollToBottom()
        var rows = readRows()
        if !labels(rows).contains(session) {
            // A drop that landed elsewhere left it nearer the top.
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
            actual: { "the Host has it in \(hostProjects()[session] ?? "nothing"); \(layout(readRows()))" }
        )
        // Back home for the next round: both are near the top now.
        let now = readRows()
        if hostProjects()[session] == "g-beta",
           let filed = now.first(where: { $0.label == session }),
           let big = now.first(where: { $0.label == "Big" }) {
            _ = ready(for: press(filed.frame))
            _ = drag(from: press(filed.frame), path: [press(big.frame)], holdMs: 350,
                     aim: { readRows().first(where: { $0.label == "Big" }).map { press($0.frame) } })
            _ = waitUntil(seconds: 3) { hostProjects()[session] == home }
        }
        Thread.sleep(forTimeInterval: 0.4)
    }
}

/// Filing a Session: from its project's own list onto a group header, then
/// from the group back onto the project's header.
func runGroupDrop(count: Int) {
    let scenario = Scenario("group-drop")
    scenarios.append(scenario)
    let session = "~/w/Big/big-11"
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

/// Reorder two rows that sit side by side: whichever is lower goes above the
/// other. `sameLevel` keeps only the rows being compared.
func runSwap(_ name: String, first: String, second: String, count: Int) {
    let scenario = Scenario(name)
    scenarios.append(scenario)
    log("\(name): swap \(first) and \(second) x\(count)")
    for attempt in 1 ... count {
        let rows = readRows()
        guard let a = rows.first(where: { $0.label == first }),
              let b = rows.first(where: { $0.label == second }) else {
            scenario.fail("drag \(attempt): the rows are not on screen")
            continue
        }
        let (upper, lower) = a.frame.midY < b.frame.midY ? (a, b) : (b, a)
        let target = CGPoint(x: lower.frame.minX + 6, y: upper.frame.minY + 2)
        runDrag(
            scenario, attempt: attempt, from: press(lower.frame), path: [target],
            describe: "\(lower.label) above \(upper.label)",
            expected: {
                let now = readRows()
                guard let moved = now.first(where: { $0.label == lower.label }),
                      let other = now.first(where: { $0.label == upper.label }) else { return false }
                return moved.frame.midY < other.frame.midY
            },
            actual: { layout(readRows()) }
        )
    }
}

/// A folder lifts, and a drop leaves it where it was.
func runFolderStaysPut(_ name: String, count: Int) {
    let scenario = Scenario(name)
    scenarios.append(scenario)
    log("\(name): drag Beta above Alpha x\(count): it stays put")
    for attempt in 1 ... count {
        let rows = readRows()
        guard let beta = rows.first(where: { $0.label == "Beta" }),
              let alpha = rows.first(where: { $0.label == "Alpha" }) else {
            scenario.fail("drag \(attempt): the rows are not on screen: \(layout(rows))")
            continue
        }
        let order = labels(rows)
        runDrag(
            scenario, attempt: attempt, from: press(beta.frame),
            path: [CGPoint(x: alpha.frame.minX + 6, y: alpha.frame.minY + 2)],
            describe: "Beta above Alpha",
            expected: { labels(readRows()) == order },
            actual: { layout(readRows()) }
        )
    }
}

// MARK: - Entry

if command == "prepare" {
    guard let window = mainWindow() else {
        print("no window")
        exit(1)
    }
    var origin = CGPoint(x: 60, y: 60)
    var size = CGSize(width: 1100, height: option("--window-height").flatMap(Double.init) ?? 1280)
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    print(summary(labels(readRows())))
    exit(0)
}

guard AXIsProcessTrusted() else {
    print("this process needs Accessibility permission")
    exit(2)
}

waitForQuiet()
NSRunningApplication(processIdentifier: pid)?.activate(options: [])
Thread.sleep(forTimeInterval: 0.6)
log("rows: \(summary(labels(readRows())))")

if wanted("toggle-project") {
    runToggles("Small", children: ["~/w/Big/small-3", "~/w/Big/small-2", "~/w/Big/small-1"], count: clickCount)
    runToggles("Quiet", children: ["~/w/Big/quiet-1"], count: clickCount)
    // Quiet starts collapsed, and an even count leaves it there.
}
if wanted("toggle") {
    runToggles("Inner", children: innerChildren, count: clickCount)
    if !Set(labels(readRows())).isSuperset(of: innerChildren), let inner = readRows().first(where: { $0.label == "Inner" }) {
        click(press(inner.frame))
        Thread.sleep(forTimeInterval: 0.7)
    }
    runToggles("Beta", children: betaChildren, count: clickCount)
    runToggles("Alpha", children: alphaChildren, count: clickCount)
    // Leave all three open for the drags, whatever state the toggles ended in.
    for (group, children) in [("Alpha", alphaChildren), ("Inner", innerChildren), ("Beta", betaChildren)] {
        let rows = readRows()
        if !Set(labels(rows)).isSuperset(of: children), let header = rows.first(where: { $0.label == group }) {
            click(press(header.frame))
            Thread.sleep(forTimeInterval: 0.8)
        }
    }
}
if wanted("group-reorder") { runGroupReorder(count: dragCount) }
if only?.contains("scrolled-list-reorder") == true { runScrolledListReorder(count: dragCount) }
if only?.contains("scrolled-group-drop") == true { runScrolledGroupDrop(count: dragCount) }
if only?.contains("long-list-drop") == true { runLongListDrop(count: dragCount) }
if only?.contains("scrolled-back-reorder") == true { runScrolledBackReorder(count: dragCount) }
if wanted("list-reorder") { runListReorder(count: dragCount) }
if wanted("group-drop") { runGroupDrop(count: dragCount) }
if wanted("out-and-back") { runDragOutAndBack(count: dragCount) }
func setExpanded(_ group: String, children: [String], _ expanded: Bool) {
    let rows = readRows()
    guard Set(labels(rows)).isSuperset(of: children) != expanded,
          let header = rows.first(where: { $0.label == group }) else { return }
    click(press(header.frame))
    Thread.sleep(forTimeInterval: 0.8)
}

if wanted("folder-reorder") {
    // A folder lifts and shows its gap, but a Host-served list commits only its
    // Sessions' order (`commitSessionReorder`), so the drop snaps back, collapsed
    // or expanded. This asserts today's behaviour; a fix for it flips this check.
    runFolderStaysPut("folder-expanded", count: dragCount)
    setExpanded("Alpha", children: alphaChildren, false)
    setExpanded("Beta", children: betaChildren, false)
    runFolderStaysPut("folder-collapsed", count: dragCount)
    setExpanded("Alpha", children: alphaChildren, true)
    setExpanded("Beta", children: betaChildren, true)
}
if wanted("project-reorder") { runSwap("project-reorder", first: "Quiet", second: "Empty", count: dragCount) }

log("")
log("scenario            passed  failed")
for scenario in scenarios {
    log(scenario.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        + String(format: "%6d  %6d", scenario.passed, scenario.failed))
}
let failures = scenarios.reduce(0) { $0 + $1.failed }
log("total failures: \(failures); user pauses: \(pauses)")
if let reportPath {
    let report = scenarios.map { ["name": $0.name, "passed": $0.passed, "failed": $0.failed, "details": $0.details] as [String: Any] }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
        FileManager.default.createFile(atPath: reportPath, contents: data)
    }
}
exit(failures == 0 ? 0 : 1)
