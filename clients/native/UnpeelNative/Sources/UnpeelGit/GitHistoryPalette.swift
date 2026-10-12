import AppKit

/// Colours and fonts injected by the app so Git History matches the sidebar
/// without importing the app's theme (the same arrangement as the
/// EXPLORER's `ExplorerPalette`).
@MainActor
public struct GitHistoryPalette {
    public let text: NSColor
    public let secondaryText: NSColor
    public let rowFont: NSFont

    public init(text: NSColor, secondaryText: NSColor, rowFont: NSFont) {
        self.text = text
        self.secondaryText = secondaryText
        self.rowFont = rowFont
    }

    public static var system: GitHistoryPalette {
        GitHistoryPalette(
            text: .labelColor,
            secondaryText: .secondaryLabelColor,
            rowFont: .systemFont(ofSize: 13, weight: .medium)
        )
    }
}
