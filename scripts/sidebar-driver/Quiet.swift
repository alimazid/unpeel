import AppKit

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
