import AppKit

/// Git History's outline. Public so the app can find it in a window to
/// tell whether GIT HISTORY holds keyboard focus (⌃⇧G).
@MainActor
public final class GitHistoryNSOutlineView: NSOutlineView {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    /// Return: expand or collapse the selected commit.
    var onToggle: (() -> Bool)?
    /// ⌘C: copy the selected commit's SHA.
    var onCopy: (() -> Bool)?
    /// The column's width changed, so wrapped rows need new heights.
    var onColumnResize: (() -> Void)?

    /// See `ExplorerNSOutlineView.fitColumnToClipView`: the single column
    /// must follow the clip view's width on every layout pass.
    private var fittedClipWidth: CGFloat = .nan
    private var fittedColumnWidth: CGFloat = .nan

    public override func layout() {
        super.layout()
        guard let clipWidth = enclosingScrollView?.contentView.bounds.width,
              let column = tableColumns.last,
              clipWidth != fittedClipWidth || column.width != fittedColumnWidth
        else { return }
        sizeLastColumnToFit()
        let resized = column.width != fittedColumnWidth
        fittedClipWidth = clipWidth
        fittedColumnWidth = column.width
        if resized { onColumnResize?() }
    }

    /// No disclosure triangles: a click on the row expands a commit, and the
    /// dot gutter owns the leading edge.
    public override func frameOfOutlineCell(atRow _: Int) -> NSRect {
        .zero
    }

    public override func keyDown(with event: NSEvent) {
        // Keypad Enter carries the numeric-pad flag; only real modifiers
        // turn Return into something else.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isReturn = event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadEnterKeyCode
        if isReturn, modifiers.isEmpty, onToggle?() == true { return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        _ = onCopy?()
    }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}
