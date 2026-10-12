import AppKit

/// The expanded commit's full message (or "Loading…" / a failure), wrapped
/// and selectable, under the commit's lane.
final class GitMessageCellView: NSTableCellView {
    static let verticalPadding: CGFloat = 4
    static let trailingPadding: CGFloat = 8

    let gutter = GitCommitGutterView()
    let messageField = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        gutter.showsDot = false
        messageField.isSelectable = true
        messageField.lineBreakMode = .byWordWrapping
        for view in [gutter, messageField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = messageField
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: GitHistoryRowMetrics.gutterWidth),
            messageField.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 2),
            messageField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingPadding),
            messageField.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func font(_ palette: GitHistoryPalette) -> NSFont {
        .systemFont(ofSize: max(10, palette.rowFont.pointSize - 1))
    }

    func configure(message: String, lane: Bool, palette: GitHistoryPalette) {
        messageField.font = Self.font(palette)
        messageField.textColor = palette.secondaryText
        messageField.stringValue = message
        gutter.lineAbove = true
        gutter.lineBelow = lane
        gutter.color = palette.secondaryText
    }

    /// The row height that fits `message` wrapped at `width` (the column).
    static func height(for message: String, width: CGFloat, palette: GitHistoryPalette) -> CGFloat {
        let textWidth = max(40, width - GitHistoryRowMetrics.gutterWidth - 2 - trailingPadding)
        // Measured with the cell's own text system so wrapping matches.
        let measuring = NSTextField(wrappingLabelWithString: message.isEmpty ? " " : message)
        measuring.font = font(palette)
        let size = measuring.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude))
        return ceil((size?.height ?? 16) + verticalPadding * 2)
    }
}

/// One changed file of the expanded commit: its change letter in the shared
/// git colour, the file name, and its folder (or `folder ← old path` for a
/// rename or copy).
final class GitChangedFileCellView: NSTableCellView {
    let gutter = GitCommitGutterView()
    let letterField = NSTextField(labelWithString: "")
    let nameField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")

    private var restingText: NSColor = .labelColor
    private var restingSecondary: NSColor = .secondaryLabelColor
    private var letterColor: NSColor = .labelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        gutter.showsDot = false
        letterField.alignment = .center
        nameField.lineBreakMode = .byTruncatingMiddle
        detailField.lineBreakMode = .byTruncatingHead
        nameField.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [gutter, letterField, nameField, detailField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = nameField
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: GitHistoryRowMetrics.gutterWidth),
            letterField.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 2),
            letterField.widthAnchor.constraint(equalToConstant: 14),
            letterField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: letterField.trailingAnchor, constant: 4),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 6),
            detailField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detailField.firstBaselineAnchor.constraint(equalTo: nameField.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(file: GitChangedFile, lane: Bool, palette: GitHistoryPalette) {
        let size = max(10, palette.rowFont.pointSize - 1)
        letterField.font = .monospacedSystemFont(ofSize: size, weight: .bold)
        nameField.font = .systemFont(ofSize: size)
        detailField.font = .systemFont(ofSize: max(10, size - 1))
        letterField.stringValue = file.kind.letter
        nameField.stringValue = (file.path as NSString).lastPathComponent
        detailField.stringValue = Self.detailText(for: file)
        letterColor = file.kind.color
        restingText = palette.text
        restingSecondary = palette.secondaryText
        gutter.lineAbove = true
        gutter.lineBelow = lane
        gutter.color = palette.secondaryText
        toolTip = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        applyColors()
    }

    /// The folder, then `← old path` for a rename or copy.
    static func detailText(for file: GitChangedFile) -> String {
        let folder = (file.path as NSString).deletingLastPathComponent
        guard let oldPath = file.oldPath else { return folder }
        return folder.isEmpty ? "← \(oldPath)" : "\(folder) ← \(oldPath)"
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        letterField.textColor = emphasized ? .alternateSelectedControlTextColor : letterColor
        nameField.textColor = emphasized ? .alternateSelectedControlTextColor : restingText
        detailField.textColor = emphasized ? .alternateSelectedControlTextColor : restingSecondary
    }
}
