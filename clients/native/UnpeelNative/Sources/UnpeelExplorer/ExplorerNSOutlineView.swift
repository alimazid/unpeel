import AppKit
import Quartz

@MainActor
public final class ExplorerNSOutlineView: NSOutlineView {
    public var keyCommandHandler: ((ExplorerKeyCommand) -> Bool)?
    public var previewPaths: () -> [String] = { [] }

    /// The clip width and column width the column was last fitted for, so
    /// `fitColumnToClipView` only writes a width when something actually
    /// moved — writing one re-tiles the table and asks for another layout
    /// pass, which would otherwise never settle.
    private var fittedClipWidth: CGFloat = .nan
    private var fittedColumnWidth: CGFloat = .nan

    /// `.uniformColumnAutoresizingStyle` redistributes width only when the
    /// table's frame CHANGES. SwiftUI hands the scroll view its size after
    /// `makeNSView`, and every `reloadData`/`reloadItem` re-tiles the table
    /// back to a column width derived from its own content — 12 pt for a
    /// one-level tree — regardless of how wide the panel is. `frameOfCell`
    /// then hands each row a few points of width, and the row cell's Auto
    /// Layout has to break a required constraint: the label collapses to
    /// 4 pt behind the icon, and rows re-laid out by a later reload lose
    /// the icon's 16 pt width instead. Fitting the column in every layout
    /// pass covers all of it: first mount, each reload, a width drag, and
    /// the panel being hidden (zero width) and shown again.
    public override func layout() {
        super.layout()
        fitColumnToClipView()
    }

    private func fitColumnToClipView() {
        guard let clipWidth = enclosingScrollView?.contentView.bounds.width,
              let column = tableColumns.last,
              clipWidth != fittedClipWidth || column.width != fittedColumnWidth
        else { return }
        sizeLastColumnToFit()
        fittedClipWidth = clipWidth
        fittedColumnWidth = column.width
    }

    // MARK: - Edit menu (Fork-only: explorer operations)

    public weak var editTarget: (any ExplorerEditTarget)?

    @objc public func undo(_: Any?) { performEdit(.undo) }
    @objc public func redo(_: Any?) { performEdit(.redo) }
    @objc public func cut(_: Any?) { performEdit(.cut) }
    @objc public func copy(_: Any?) { performEdit(.copy) }
    @objc public func paste(_: Any?) { performEdit(.paste) }

    /// While a name field in a row is being edited, the field editor is
    /// first responder and its undo/redo reach the tree through the
    /// responder chain; those belong to the window's undo manager (the
    /// text's own undo), never to the Operation History.
    private var isEditingText: Bool {
        window?.firstResponder !== self && window?.firstResponder is NSText
    }

    private func performEdit(_ command: ExplorerEditCommand) {
        if isEditingText {
            if command == .undo { window?.undoManager?.undo() }
            if command == .redo { window?.undoManager?.redo() }
            return
        }
        guard editTarget?.title(for: command) != nil else { return }
        editTarget?.perform(command)
    }

    /// The menu item's enabled state and title for `command`.
    func editState(for command: ExplorerEditCommand) -> (enabled: Bool, title: String) {
        if isEditingText, let manager = window?.undoManager, command == .undo || command == .redo {
            return command == .undo
                ? (manager.canUndo, manager.undoMenuItemTitle)
                : (manager.canRedo, manager.redoMenuItemTitle)
        }
        guard let title = editTarget?.title(for: command) else { return (false, command.defaultTitle) }
        return (true, title)
    }

    /// `NSTableView` already validates its own items here (Select All), so
    /// this extends that rather than adding `validateMenuItem`, which AppKit
    /// would ask instead of it.
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let command = ExplorerEditCommand(action: item.action) else {
            return super.validateUserInterfaceItem(item)
        }
        let state = editState(for: command)
        (item as? NSMenuItem)?.title = state.title
        return state.enabled
    }

    public override func keyDown(with event: NSEvent) {
        if let command = ExplorerKeyCommand.from(keyCode: event.keyCode, modifiers: event.modifierFlags),
           keyCommandHandler?(command) == true {
            return
        }
        super.keyDown(with: event)
    }

    /// `QLPreviewPanel.shared()` creates the panel as a side effect, so
    /// existence must be checked first — calling `.shared()` unconditionally
    /// to read `.isVisible` would spin up a panel just to decide whether to
    /// hide one that was never open.
    public func toggleQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            showQuickLook()
        }
    }

    /// Opens the panel the first time; reloads an already-open one so a
    /// changed selection is reflected instead of the toggle hiding it.
    public func showQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Keeps an already-open panel in sync with a selection change without
    /// creating or showing the panel when it isn't open.
    public func reloadQuickLookIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        QLPreviewPanel.shared().reloadData()
    }

    public override nonisolated func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool { true }

    // NSResponder declares these Quick Look callbacks without @MainActor, so
    // an override on this @MainActor class is nonisolated too; QLPreviewPanel
    // always calls them on the main thread, so asserting isolation is safe.
    public override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
        }
    }

    public override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
        }
    }
}

// Kept as a separate conformance (rather than on the class declaration) so
// `@preconcurrency` only relaxes checking for this Objective-C protocol,
// not the class's own AppKit conformances.
extension ExplorerNSOutlineView: @preconcurrency QLPreviewPanelDataSource {
    public func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        previewPaths().count
    }

    public func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let paths = previewPaths()
        guard paths.indices.contains(index) else { return nil }
        return NSURL(fileURLWithPath: paths[index])
    }
}
