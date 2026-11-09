// verify-sidebar-interaction.swift — the driver behind
// verify-sidebar-interaction.sh. It clicks and drags PROJECTS rows in a
// running dev app with real pointer events and checks every step against the
// app's accessibility tree and the Host's session list.
//
//   driver check [--only a,b]
//   driver prepare --pid P [--window-height H] [--scale S]
//   driver run --pid P --ls <script> --home DIR [--clicks N] [--drags N] [--only a,b] [--report F] [--scale S]
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
if command == "locked" {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    exit((session?["CGSSessionScreenIsLocked"] as? Bool) == true ? 0 : 1)
}

/// What `--only` takes. A name missing here is refused, so a new scenario adds
/// its name; the scrolled ones, long-list-drop, far-select, cross-project-insert,
/// session-above-folder, folder-persisted and pinned-persisted run only when named.
let knownScenarios: Set<String> = [
    "toggle-project", "toggle", "group-reorder", "list-reorder", "group-drop", "out-and-back",
    "drop-card", "folder-cancel", "folder-reorder", "folder-pinned", "project-reorder",
    "scrolled-list-reorder", "scrolled-group-drop", "long-list-drop", "scrolled-back-reorder", "far-select",
    "scrolled-folder", "cross-project-insert", "session-above-folder", "folder-persisted", "pinned-persisted",
]
let only = option("--only").map { Set($0.split(separator: ",").map(String.init)) }
if let only {
    let unknown = only.subtracting(knownScenarios).sorted()
    guard !only.isEmpty, unknown.isEmpty else {
        print("--only: no scenario named '\(unknown.joined(separator: ","))'; there are: "
            + knownScenarios.sorted().joined(separator: ","))
        exit(2)
    }
}
if command == "check" { exit(0) }

guard let pidValue = option("--pid").flatMap({ pid_t($0) }) else {
    print("usage: driver check|prepare|run --pid P [--ls script] [--home DIR] [--clicks N] [--drags N] [--only a,b] [--report F] [--scale S]")
    exit(2)
}
let pid = pidValue
let clickCount = option("--clicks").flatMap(Int.init) ?? 30
let dragCount = option("--drags").flatMap(Int.init) ?? 20
let listScript = option("--ls")
let fixtureHome = option("--home")
let wantedScale = option("--scale").flatMap(Double.init).map { CGFloat($0) }
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

// MARK: - Displays

/// A rectangle from AppKit's bottom-up space in the top-down one AX and CGEvent use.
func topDown(_ rect: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// The scale of the display under the window's center.
func windowScale() -> CGFloat? {
    guard let window = mainWindow().flatMap({ frame(of: $0) }) else { return nil }
    let center = CGPoint(x: window.midX, y: window.midY)
    return NSScreen.screens.first { topDown($0.frame).contains(center) }?.backingScaleFactor
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

/// This app's windows on screen, front to back, by number.
func appWindowsFrontToBack() -> [Int] {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { window in
        (window[kCGWindowOwnerPID as String] as? pid_t) == pid ? window[kCGWindowNumber as String] as? Int : nil
    }
}

func appWindowNumbers() -> Set<Int> { Set(appWindowsFrontToBack()) }

enum DragResult {
    case finished(lifted: Bool)
    case interrupted
}

/// Presses at `from`, travels through `path` at a human pace, holds, releases.
/// `lifted` says the floating card window appeared.
///
/// Rows part around a drag, so a target moves under it. `aim`, when given, is
/// asked for the target's current spot after the path, and the pointer follows,
/// the way a person aims at what they see. `whileHeld` runs with the row in the
/// air, before the hold. `afterRelease` gets the windows that were there before
/// the lift, so it can tell the card from them.
func drag(
    from: CGPoint, path: [CGPoint], holdMs: Int = 200, aim: (() -> CGPoint?)? = nil, aimWait: Double = 0,
    whileHeld: (() -> Void)? = nil, afterRelease: ((Set<Int>) -> Void)? = nil
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
    whileHeld?()
    let holdEnd = Date().addingTimeInterval(Double(holdMs) / 1000)
    while Date() < holdEnd {
        post(.leftMouseDragged, current)
        Thread.sleep(forTimeInterval: 1.0 / 30.0)
    }
    lifted = lifted || !appWindowNumbers().subtracting(windowsBefore).isEmpty
    post(.leftMouseUp, current)
    afterRelease?(windowsBefore)
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

func homeJSON(_ name: String) -> Any? {
    guard let fixtureHome,
          let data = FileManager.default.contents(atPath: (fixtureHome as NSString).appendingPathComponent(name))
    else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

/// The order the Host persisted for one list, as row labels.
func hostOrder(of projectID: String) -> [String] {
    guard let orders = homeJSON("session-order.json") as? [String: [String]] else { return [] }
    let labels = Dictionary(uniqueKeysWithValues: hostSessions().map { ($0.id, $0.label) })
    return (orders[projectID] ?? []).compactMap { labels[$0] }
}

/// The order the Host persisted for one list as it is on disk, folder ids and all.
func hostRawOrder(of projectID: String) -> [String] {
    (homeJSON("session-order.json") as? [String: [String]])?[projectID] ?? []
}

func hostProjectID(named name: String) -> String? {
    guard let state = homeJSON("app-state.json") as? [String: Any],
          let projects = state["projects"] as? [[String: Any]] else { return nil }
    return projects.first { ($0["name"] as? String) == name }?["id"] as? String
}

/// Whether `first` comes before `second`; nil unless the list has both.
func isAbove(_ first: String, _ second: String, in order: [String]) -> Bool? {
    guard let one = order.firstIndex(of: first), let two = order.firstIndex(of: second) else { return nil }
    return one < two
}

/// The project order the Host persisted, as project names. Empty until a first
/// project reorder writes it.
func hostProjectOrder() -> [String] {
    guard let ids = homeJSON("project-order.json") as? [String],
          let state = homeJSON("app-state.json") as? [String: Any],
          let projects = state["projects"] as? [[String: Any]] else { return [] }
    let names = projects.reduce(into: [String: String]()) { names, project in
        if let id = project["id"] as? String, let name = project["name"] as? String { names[id] = name }
    }
    return ids.compactMap { names[$0] }
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
let smallChildren = ["~/w/Big/small-3", "~/w/Big/small-2", "~/w/Big/small-1"]

/// A folder in a list, and the rows that show under it while it's open.
struct Folder {
    let label: String
    let id: String
    let block: [String]
}
let alphaFolder = Folder(label: "Alpha", id: "g-alpha", block: alphaChildren + innerChildren)
let betaFolder = Folder(label: "Beta", id: "g-beta", block: betaChildren)
let pinA = Folder(label: "Pin-A", id: "g-pin-a", block: ["~/w/Big/pin-a-1"])
let pinB = Folder(label: "Pin-B", id: "g-pin-b", block: ["~/w/Big/pin-b-1"])
let plain = Folder(label: "Plain", id: "g-plain", block: ["~/w/Big/plain-1"])
let pinsRows = [pinA.label, pinB.label, plain.label]
let pinnedBlock = [pinA.label, pinB.label] + pinA.block + pinB.block
let pinsSession = "~/w/Big/pins-1"

/// A folder and its row on screen.
struct PlacedFolder {
    let folder: Folder
    let row: Row
}

/// Two folders' rows, the upper one first; nil unless both are on screen.
func placed(_ one: Folder, _ two: Folder, in rows: [Row]) -> (upper: PlacedFolder, lower: PlacedFolder)? {
    guard let oneRow = rows.first(where: { $0.label == one.label }),
          let twoRow = rows.first(where: { $0.label == two.label }) else { return nil }
    let first = PlacedFolder(folder: one, row: oneRow)
    let second = PlacedFolder(folder: two, row: twoRow)
    return oneRow.frame.midY < twoRow.frame.midY ? (first, second) : (second, first)
}

/// Whether the folder's rows all come right after its header.
func isOpen(_ folder: Folder, in rows: [String]) -> Bool {
    guard let start = rows.firstIndex(of: folder.label), start + folder.block.count < rows.count else { return false }
    return Set(rows[(start + 1) ... (start + folder.block.count)]) == Set(folder.block)
}

/// The rows' positions, to compare two moments of one drag.
func positions(_ rows: [Row]) -> [String: CGFloat] {
    Dictionary(rows.map { ($0.label, $0.frame.minY) }, uniquingKeysWith: { first, _ in first })
}

/// Rows of `before` that sit elsewhere in `now`. A row gone from `now` isn't one.
func movedRows(_ names: [String], from before: [String: CGFloat], to now: [String: CGFloat]) -> [String] {
    names.filter { name in
        guard let was = before[name], let current = now[name] else { return false }
        return abs(was - current) > 2
    }
}

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

/// A key, delivered to the app alone: it never reaches the HID state that
/// `waitForQuiet` watches.
func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    for isDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { return }
        event.flags = flags
        event.postToPid(pid)
    }
}

/// A press counts as keyboard input for `userInterfered` this long.
let keyInputHold: TimeInterval = 2.1

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

// MARK: - Entry

if command == "prepare" {
    guard let window = mainWindow() else {
        print("no window")
        exit(1)
    }
    var origin = CGPoint(x: 60, y: 60)
    var size = CGSize(width: 1100, height: option("--window-height").flatMap(Double.init) ?? 1280)
    if let wantedScale {
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == wantedScale }) else {
            print("no display at \(wantedScale)x")
            exit(1)
        }
        let area = topDown(screen.visibleFrame)
        origin = CGPoint(x: area.minX + 60, y: area.minY + 10)
        size.height = min(size.height, area.height - 20)
    }
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
let scale = windowScale()
log("display scale: \(scale.map { "\($0)x" } ?? "unknown")")
if let wantedScale, scale != wantedScale {
    log("the window is not on a \(wantedScale)x display")
    exit(1)
}
log("rows: \(summary(labels(readRows())))")

if wanted("toggle-project") {
    runToggles("Small", children: smallChildren, count: clickCount)
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
if only?.contains("scrolled-list-reorder") == true {
    runScrolledReorder("scrolled-list-reorder", session: "~/w/Big/big-05", how: "in a scrolled list", count: dragCount) {
        scrollToBottom()
    }
}
if only?.contains("scrolled-group-drop") == true { runScrolledGroupDrop(count: dragCount) }
if only?.contains("long-list-drop") == true { runLongListDrop(count: dragCount) }
if only?.contains("scrolled-back-reorder") == true {
    // This doesn't catch a row missing from the drag registry: it stays green
    // with d978306 reverted. scrolled-group-drop and long-list-drop catch that.
    runScrolledReorder("scrolled-back-reorder", session: "~/w/Big/big-28", how: "after scrolling away and back", count: dragCount) {
        scrollToBottom()
        scrollToTop()
    }
}
if only?.contains("far-select") == true { runFarSelect(count: min(dragCount, 10)) }
if only?.contains("scrolled-folder") == true { runScrolledFolder(count: min(dragCount, 10)) }
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

if wanted("list-reorder") { checkFoldersUnranked() }
if wanted("drop-card") { runDropCard(count: min(dragCount, 6)) }
if wanted("folder-cancel") { runFolderCancel(count: min(dragCount, 6)) }
if wanted("folder-reorder") {
    runOpenFolderMoves(count: dragCount)
    setExpanded("Alpha", children: alphaChildren, false)
    setExpanded("Beta", children: betaChildren, false)
    runFolderReorder("folder-collapsed", count: dragCount)
    runFolderPastSession(count: min(dragCount, 6))
    setExpanded("Alpha", children: alphaChildren, true)
    runBetaPastExpandedAlpha(count: dragCount)
    setExpanded("Beta", children: betaChildren, true)
    runOpenFolderLastMoves()
}
if only?.contains("cross-project-insert") == true { runCrossProjectInsert(count: min(dragCount, 6)) }
if only?.contains("session-above-folder") == true {
    setExpanded("Alpha", children: alphaChildren, false)
    setExpanded("Beta", children: betaChildren, false)
    runSessionAboveFolder(count: min(dragCount, 6))
    setExpanded("Alpha", children: alphaChildren, true)
    setExpanded("Beta", children: betaChildren, true)
}
if only?.contains("folder-persisted") == true { runFolderPersisted() }
if only?.contains("pinned-persisted") == true { runPinnedPersisted() }
if wanted("folder-pinned") { runPinnedFolders(count: dragCount) }
if wanted("project-reorder") {
    setExpanded("Small", children: smallChildren, true)
    runProjectReorder(count: dragCount)
}

guard !scenarios.isEmpty else {
    log("no scenario ran")
    exit(2)
}
log("")
log("scenario                passed  failed")
for scenario in scenarios {
    log(scenario.name.padding(toLength: 24, withPad: " ", startingAt: 0)
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
