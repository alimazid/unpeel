import AppKit

/// Geometry shared by the commit rows and the rows of an expanded commit.
enum GitHistoryRowMetrics {
    static let commitRowHeight: CGFloat = 36
    static let gutterWidth: CGFloat = 20
    static let dotDiameter: CGFloat = 7
    /// The y of a commit dot's centre, from the row's top (flipped).
    static let dotCenterY: CGFloat = 12
}

/// One commit: the single-lane dot gutter, the subject with its ref labels,
/// and `author · age` underneath.
final class GitCommitCellView: NSTableCellView {
    let gutter = GitCommitGutterView()
    let subjectField = NSTextField(labelWithString: "")
    let pills = GitRefPillsView()
    let metaField = NSTextField(labelWithString: "")

    private var restingText: NSColor = .labelColor
    private var restingSecondary: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        subjectField.lineBreakMode = .byTruncatingTail
        metaField.lineBreakMode = .byTruncatingTail
        subjectField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pills.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        pills.setContentHuggingPriority(.required, for: .horizontal)
        for view in [gutter, subjectField, pills, metaField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = subjectField
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: GitHistoryRowMetrics.gutterWidth),
            subjectField.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 2),
            subjectField.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            pills.leadingAnchor.constraint(equalTo: subjectField.trailingAnchor, constant: 4),
            pills.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            pills.centerYAnchor.constraint(equalTo: subjectField.centerYAnchor),
            metaField.leadingAnchor.constraint(equalTo: subjectField.leadingAnchor),
            metaField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            metaField.topAnchor.constraint(equalTo: subjectField.bottomAnchor, constant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(commit: GitCommit, lineAbove: Bool, lineBelow: Bool, palette: GitHistoryPalette, now: Date) {
        subjectField.font = palette.rowFont
        metaField.font = .systemFont(ofSize: max(10, palette.rowFont.pointSize - 2))
        subjectField.stringValue = commit.subject
        metaField.stringValue = "\(commit.author) · \(GitRelativeDate.text(for: commit.date, now: now))"
        restingText = palette.text
        restingSecondary = palette.secondaryText
        pills.labels = GitRefPillsView.ordered(commit.refs)
        gutter.isHead = commit.isHead
        gutter.isMerge = commit.isMerge
        gutter.lineAbove = lineAbove
        gutter.lineBelow = lineBelow
        gutter.color = palette.secondaryText
        toolTip = "\(commit.subject)\n\(commit.author), \(GitRelativeDate.tooltipFormatter.string(from: commit.date))\n\(commit.sha)"
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    /// The emphasized selection fill is the accent colour; the palette's
    /// fixed colours are unreadable on it (see `ExplorerRowCellView`).
    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        subjectField.textColor = emphasized ? .alternateSelectedControlTextColor : restingText
        metaField.textColor = emphasized ? .alternateSelectedControlTextColor : restingSecondary
        pills.isEmphasized = emphasized
    }
}

/// The single-lane graph: a vertical line through every row, a dot per
/// commit (a ring for HEAD, hollow for a merge). The line stops above the
/// newest commit and below the oldest one when nothing older exists.
final class GitCommitGutterView: NSView {
    var isHead = false { didSet { needsDisplay = true } }
    var isMerge = false { didSet { needsDisplay = true } }
    var lineAbove = true { didSet { needsDisplay = true } }
    var lineBelow = true { didSet { needsDisplay = true } }
    /// Detail rows of an expanded commit draw only the line.
    var showsDot = true { didSet { needsDisplay = true } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let centerX = bounds.midX
        let centerY = showsDot ? GitHistoryRowMetrics.dotCenterY : bounds.midY
        let line = NSBezierPath()
        line.lineWidth = 1.5
        if lineAbove {
            line.move(to: NSPoint(x: centerX, y: 0))
            line.line(to: NSPoint(x: centerX, y: centerY))
        }
        if lineBelow {
            line.move(to: NSPoint(x: centerX, y: centerY))
            line.line(to: NSPoint(x: centerX, y: bounds.maxY))
        }
        color.withAlphaComponent(0.6).setStroke()
        line.stroke()
        guard showsDot else { return }
        let diameter = isHead ? GitHistoryRowMetrics.dotDiameter + 3 : GitHistoryRowMetrics.dotDiameter
        let dot = NSBezierPath(ovalIn: NSRect(
            x: centerX - diameter / 2, y: centerY - diameter / 2, width: diameter, height: diameter
        ))
        let tint = isHead ? NSColor.controlAccentColor : color
        if isMerge || isHead {
            NSColor.windowBackgroundColor.setFill()
            dot.fill()
            dot.lineWidth = isHead ? 2.5 : 1.5
            tint.setStroke()
            dot.stroke()
        } else {
            tint.setFill()
            dot.fill()
        }
    }
}

/// Ref labels as small tinted capsules, drawn directly so a row needs no
/// subview per label.
final class GitRefPillsView: NSView {
    /// HEAD, then local branches, tags, and remote-tracking branches.
    static func ordered(_ refs: [GitRefLabel]) -> [GitRefLabel] {
        func rank(_ kind: GitRefLabel.Kind) -> Int {
            switch kind {
            case .head: return 0
            case .localBranch: return 1
            case .tag: return 2
            case .remoteBranch: return 3
            }
        }
        return refs.enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }
            .map(\.element)
    }

    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let horizontalPadding: CGFloat = 4
    private static let spacing: CGFloat = 3
    private static let height: CGFloat = 14

    var labels: [GitRefLabel] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var isEmphasized = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    static func tint(for kind: GitRefLabel.Kind) -> NSColor {
        switch kind {
        case .head: return .controlAccentColor
        case .localBranch: return .systemBlue
        case .tag: return .systemOrange
        case .remoteBranch: return .secondaryLabelColor
        }
    }

    private static func width(of label: GitRefLabel) -> CGFloat {
        ceil((label.name as NSString).size(withAttributes: [.font: font]).width) + horizontalPadding * 2
    }

    override var intrinsicContentSize: NSSize {
        guard !labels.isEmpty else { return NSSize(width: 0, height: Self.height) }
        let widths = labels.map(Self.width(of:))
        return NSSize(width: widths.reduce(0, +) + Self.spacing * CGFloat(labels.count - 1), height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let y = (bounds.height - Self.height) / 2
        for label in labels {
            let width = Self.width(of: label)
            guard x + width <= bounds.width + 0.5 else { break }
            let rect = NSRect(x: x, y: y, width: width, height: Self.height)
            let tint = isEmphasized ? NSColor.alternateSelectedControlTextColor : Self.tint(for: label.kind)
            tint.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            (label.name as NSString).draw(
                at: NSPoint(x: x + Self.horizontalPadding, y: y + 1),
                withAttributes: [.font: Self.font, .foregroundColor: tint]
            )
            x += width + Self.spacing
        }
    }
}
