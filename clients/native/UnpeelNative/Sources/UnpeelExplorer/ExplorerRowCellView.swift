import AppKit

/// A row cell whose label follows the injected palette, except while AppKit
/// draws the row with an EMPHASIZED selection fill (the key window's accent
/// colour): the palette's text colour is a fixed near-black in light
/// appearance, which is unreadable on that fill, and AppKit only recolours
/// labels it recognises as system colours. An unemphasized selection keeps
/// its grey fill, on which the palette colour stays legible, so only the
/// emphasized case switches.
final class ExplorerRowCellView: NSTableCellView {
    /// The label's colour whenever the row is not emphasized.
    var restingTextColor: NSColor = .labelColor {
        didSet { applyTextColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColor() }
    }

    private func applyTextColor() {
        textField?.textColor = backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor
            : restingTextColor
    }
}
