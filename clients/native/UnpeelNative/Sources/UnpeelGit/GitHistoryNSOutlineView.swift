import AppKit

/// Git History's outline. Public so the app can find it in a window to
/// tell whether GIT HISTORY holds keyboard focus (⌃⇧G).
@MainActor
public final class GitHistoryNSOutlineView: NSOutlineView {
    /// Return: expand or collapse the selected commit.
    var onToggle: (() -> Bool)?
    /// ⌘C: copy the selected commit's SHA.
    var onCopy: (() -> Bool)?

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
        fittedClipWidth = clipWidth
        fittedColumnWidth = column.width
    }

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
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
