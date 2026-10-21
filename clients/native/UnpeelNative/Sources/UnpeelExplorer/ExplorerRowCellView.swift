import AppKit

/// A row cell whose label follows the injected palette, except while AppKit
/// draws the row with an EMPHASIZED selection fill (the key window's accent
/// colour): the palette's text colour is a fixed near-black in light
/// appearance, which is unreadable on that fill, and AppKit only recolours
/// labels it recognises as system colours. An unemphasized selection keeps
/// its grey fill, on which the palette colour stays legible, so only the
/// emphasized case switches.
final class ExplorerRowCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("unpeel.explorer.cell")

    /// The label's colour whenever the row is not emphasized.
    var restingTextColor: NSColor = .labelColor {
        didSet { applyTextColor() }
    }

    /// Fork-only: git support. The trailing Git Status Decoration (a
    /// letter, or a dot on a folder); empty when the row has none. It is
    /// drawn in the label's colour.
    var decorationField: NSTextField?

    /// Fork-only: date modified column. The row's date, right-aligned at
    /// the cell's trailing edge in a field of one shared width, so the
    /// dates of every depth line up as a column; empty on rows without one.
    var dateField: NSTextField?
    var dateWidth: NSLayoutConstraint?

    /// The date's colour whenever the row is not emphasized.
    var restingDateColor: NSColor = .secondaryLabelColor {
        didSet { applyTextColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColor() }
    }

    /// Fork-only: explorer operations. While the label is a name field it
    /// draws its own white background, so its text is the text colour
    /// whatever fill the row has.
    var isEditingName = false {
        didSet { applyTextColor() }
    }

    private func applyTextColor() {
        let emphasized = backgroundStyle == .emphasized
        let color = emphasized ? .alternateSelectedControlTextColor : restingTextColor
        textField?.textColor = isEditingName ? .textColor : color
        decorationField?.textColor = color
        dateField?.textColor = emphasized ? .alternateSelectedControlTextColor : restingDateColor
    }

    /// A cell with its icon, name, decoration and date laid out. The name
    /// is the only part that gives way when the row is narrow.
    static func make() -> ExplorerRowCellView {
        let cell = ExplorerRowCellView()
        cell.identifier = reuseIdentifier
        let image = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        // Fork-only: git support. The decoration keeps its width; a long
        // name truncates instead.
        let decoration = NSTextField(labelWithString: "")
        decoration.alignment = .right
        decoration.setContentHuggingPriority(.required, for: .horizontal)
        decoration.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Fork-only: date modified column. Below the name in giving way,
        // but not required: in a row too narrow for the icon and the date
        // (a zero-width mount), the date clips instead of a broken icon.
        let date = NSTextField(labelWithString: "")
        date.alignment = .right
        date.lineBreakMode = .byClipping
        date.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [image, label, decoration, date] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = label
        cell.decorationField = decoration
        cell.dateField = date
        let dateWidth = date.widthAnchor.constraint(equalToConstant: 0)
        dateWidth.priority = .init(999)
        cell.dateWidth = dateWidth
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: decoration.leadingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            decoration.trailingAnchor.constraint(equalTo: date.leadingAnchor, constant: -6),
            decoration.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            date.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            date.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dateWidth,
        ])
        return cell
    }
}
