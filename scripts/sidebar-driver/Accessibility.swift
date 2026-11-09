import AppKit
import ApplicationServices

let app: AXUIElement = {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 3)
    return element
}()

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
