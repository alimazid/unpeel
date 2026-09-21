import AppKit

/// Colours and fonts injected by the app so the library matches the sidebar
/// without importing the app's theme.
@MainActor
public struct ExplorerPalette {
    public let text: NSColor
    public let secondaryText: NSColor
    public let rowFont: NSFont

    public init(text: NSColor, secondaryText: NSColor, rowFont: NSFont) {
        self.text = text
        self.secondaryText = secondaryText
        self.rowFont = rowFont
    }

    public static var system: ExplorerPalette {
        ExplorerPalette(
            text: .labelColor,
            secondaryText: .secondaryLabelColor,
            rowFont: .systemFont(ofSize: 13, weight: .medium)
        )
    }
}

/// What the explorer cannot do on its own; implemented by the host app.
@MainActor
public protocol ExplorerActionHandler: AnyObject {
    var canSendToAgent: Bool { get }
    func openInEditor(path: String)
    func sendPathToAgent(path: String)
}
