import AppKit

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
