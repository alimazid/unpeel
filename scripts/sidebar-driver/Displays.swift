import AppKit

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
