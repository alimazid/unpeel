import AppKit
import SwiftUI

/// Hosts `ExplorerNSOutlineView` inside SwiftUI. Not public — `ExplorerPanelView`
/// is this library's only public surface.
struct ExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var viewModel: ExplorerViewModel
    let palette: ExplorerPalette
    let actionHandler: (any ExplorerActionHandler)?

    /// Owns the scroll-bounds observation so it can be torn down in
    /// `dismantleNSView`. The token can't live on `ExplorerOutlineController`
    /// itself: that controller is created once per `Coordinator` lifetime but
    /// has no hook of its own into the representable's dismantle step, and
    /// only the coordinator that `makeNSView` populated is guaranteed to be
    /// handed back to `dismantleNSView` for the matching `NSScrollView`.
    @MainActor
    final class Coordinator {
        let controller: ExplorerOutlineController
        var scrollObserver: NSObjectProtocol?

        init(controller: ExplorerOutlineController) {
            self.controller = controller
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: ExplorerOutlineController(viewModel: viewModel, palette: palette))
    }

    /// The outline view exactly as the panel builds it. Internal (rather
    /// than inline in `makeNSView`) so the rendering tests drive the real
    /// configuration and cannot drift from it.
    static func makeOutlineView() -> ExplorerNSOutlineView {
        let outline = ExplorerNSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.style = .fullWidth
        outline.backgroundColor = .clear
        // Necessary but not sufficient: it only redistributes width when the
        // table's frame changes. `ExplorerNSOutlineView.fitColumnToClipView`
        // is what actually sizes the single column on reloads and mounts —
        // neither works without the other, so do not remove one alone.
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autosaveExpandedItems = false
        // The terminal panes live in this same app, so the local mask matters
        // as much as the external one for "drag a row onto a terminal".
        // Fork-only: explorer operations — `.move` for rows dragged within
        // the tree; a terminal pane still takes the drop as a pasted path.
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .generic, .link], forLocal: false)
        outline.registerForDraggedTypes([.fileURL])
        return outline
    }

    /// The scroll view exactly as the panel builds it, minus the bounds
    /// observation the coordinator owns. Shared with the rendering tests.
    static func makeScrollView(documentView outline: ExplorerNSOutlineView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        return scroll
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = Self.makeOutlineView()
        let controller = context.coordinator.controller
        controller.attach(to: outline)

        let scroll = Self.makeScrollView(documentView: outline)
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak controller, weak scroll] _ in
            MainActor.assumeIsolated {
                guard let scroll else { return }
                controller?.noteScrolled(to: Double(scroll.contentView.bounds.origin.y))
            }
        }
        return scroll
    }

    // Called during a SwiftUI view update, so nothing reached from here may
    // synchronously publish to `viewModel` (would trigger "Publishing changes
    // from within view updates"). `apply` suppresses its own delegate/data
    // source callbacks while it drives the outline view, and the scroll it
    // performs in `applyRestoredScrollIfNeeded` only ever writes
    // `scrollOffset`, which is deliberately not `@Published`.
    func updateNSView(_: NSScrollView, context: Context) {
        let controller = context.coordinator.controller
        controller.actionHandler = actionHandler
        controller.palette = palette
        controller.apply(
            model: viewModel.model, filter: viewModel.filter, selection: viewModel.selection,
            decorations: viewModel.decorations, draft: viewModel.draft
        )
        controller.applyRestoredScrollIfNeeded()
        // Fork-only: explorer operations.
        controller.applyRevealIfNeeded()
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.scrollObserver = nil
        }
    }
}
