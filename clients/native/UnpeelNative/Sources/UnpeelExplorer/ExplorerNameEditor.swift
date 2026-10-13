import AppKit

/// Fork-only: explorer operations. The inline name field of a row being
/// renamed, or of a Draft Row: turns the row's label into an editable
/// field, validates as the user types (VS Code's messages, shown in a
/// bubble under the row), and reports the outcome once. Return commits
/// unless an error shows, Escape cancels, and leaving the field commits a
/// valid, changed name — otherwise it cancels.
@MainActor
final class ExplorerNameEditor: NSObject, NSTextFieldDelegate {
    enum Outcome: Equatable {
        case commit(String)
        case cancel
    }

    let field: NSTextField
    let purpose: FileNameValidation.Purpose
    private let isTaken: (String) -> Bool
    private let onFinish: (Outcome) -> Void
    private let message = ExplorerNameMessageView()
    private(set) var issue: FileNameIssue?
    private(set) var isFinished = false

    init(
        field: NSTextField,
        purpose: FileNameValidation.Purpose,
        isTaken: @escaping (String) -> Bool,
        onFinish: @escaping (Outcome) -> Void
    ) {
        self.field = field
        self.purpose = purpose
        self.isTaken = isTaken
        self.onFinish = onFinish
    }

    private var originalName: String {
        if case .rename(let current) = purpose { return current }
        return ""
    }

    /// Makes the field editable and focused, with `selection` selected.
    @discardableResult
    func begin(selecting selection: NSRange? = nil) -> Bool {
        field.stringValue = originalName
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        guard let window = field.window, window.makeFirstResponder(field) else {
            restoreLabel()
            return false
        }
        field.currentEditor()?.selectedRange = selection ?? Self.defaultSelection(for: originalName)
        return true
    }

    /// VS Code pre-selects a file's name up to its last dot (`archive.tar`
    /// of `archive.tar.gz`); a dotfile or a folder is selected whole.
    static func defaultSelection(for name: String, isFolder: Bool = false) -> NSRange {
        let ns = name as NSString
        let dot = ns.range(of: ".", options: .backwards).location
        guard !isFolder, dot != NSNotFound, dot > 0 else { return NSRange(location: 0, length: ns.length) }
        return NSRange(location: 0, length: dot)
    }

    // MARK: - Validation

    /// The issue with what the field holds now, shown under the row.
    func validate() {
        let name = currentText
        issue = name.isEmpty && originalName.isEmpty
            ? nil
            : FileNameValidation.validate(name, purpose: purpose, isTaken: isTaken)
        message.show(issue, below: field)
    }

    private var currentText: String {
        field.currentEditor()?.string ?? field.stringValue
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_: Notification) {
        validate()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            validate()
            if issue?.severity == .error { return true }
            finish(commitIfChanged())
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(.cancel)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_: Notification) {
        guard !isFinished else { return }
        // A field taken off screen (its row reloaded or scrolled away) did
        // not lose focus to the user: half-typed names are never committed.
        guard field.window != nil, field.superview != nil else {
            finish(.cancel)
            return
        }
        validate()
        finish(issue?.severity == .error ? .cancel : commitIfChanged())
    }

    // MARK: - Finishing

    /// Ends editing without a commit, reporting `.cancel`.
    func cancel() {
        finish(.cancel)
    }

    /// Ends editing and reports nothing — for the outline's own update
    /// pass, where reporting would reach the view model mid-update.
    func discard() {
        guard !isFinished else { return }
        isFinished = true
        restoreLabel()
    }

    private func commitIfChanged() -> Outcome {
        let name = FileNameValidation.wellFormed(currentText)
        return name.isEmpty || name == originalName ? .cancel : .commit(name)
    }

    private func finish(_ outcome: Outcome) {
        guard !isFinished else { return }
        isFinished = true
        let hadFocus = field.currentEditor() != nil
        restoreLabel()
        // The row shows the new name until the reload replaces it, rather
        // than flashing the old one.
        if case .commit(let name) = outcome { field.stringValue = name }
        if hadFocus, let outline = field.enclosingScrollView?.documentView {
            field.window?.makeFirstResponder(outline)
        }
        onFinish(outcome)
    }

    private func restoreLabel() {
        field.delegate = nil
        field.abortEditing()
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.cell?.isScrollable = false
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingMiddle
        message.hide()
    }
}

/// The bubble under an edited name: red for an error, orange for a
/// warning, as VS Code's input validation box.
@MainActor
final class ExplorerNameMessageView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    var text: String { label.stringValue }

    func show(_ issue: FileNameIssue?, below field: NSTextField) {
        guard let issue, let host = field.enclosingScrollView?.documentView else {
            hide()
            return
        }
        label.stringValue = issue.message
        let tint: NSColor = issue.severity == .error ? .systemRed : .systemOrange
        layer?.borderColor = tint.cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.85, of: tint)?
            .withAlphaComponent(1).cgColor ?? NSColor.windowBackgroundColor.cgColor
        let anchor = field.convert(field.bounds, to: host)
        let width = max(anchor.width, 160)
        label.preferredMaxLayoutWidth = width - 12
        let height = label.intrinsicContentSize.height + 8
        let y = host.isFlipped ? anchor.maxY : anchor.minY - height
        frame = NSRect(x: anchor.minX, y: y, width: width, height: height)
        if superview !== host { host.addSubview(self) }
    }

    func hide() {
        removeFromSuperview()
    }
}
