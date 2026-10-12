import AppKit
import SwiftUI

/// Hosts `GitHistoryNSOutlineView` inside SwiftUI.
struct GitHistoryOutlineView: NSViewRepresentable {
    @ObservedObject var viewModel: GitHistoryViewModel
    let palette: GitHistoryPalette
    let actionHandler: (any GitHistoryActionHandler)?

    @MainActor
    final class Coordinator {
        let controller: GitHistoryOutlineController
        var scrollObserver: NSObjectProtocol?

        init(controller: GitHistoryOutlineController) {
            self.controller = controller
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: GitHistoryOutlineController(viewModel: viewModel, palette: palette))
    }

    /// The outline exactly as the panel builds it; shared with the tests.
    static func makeOutlineView() -> GitHistoryNSOutlineView {
        let outline = GitHistoryNSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.indentationPerLevel = 0
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.style = .fullWidth
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autosaveExpandedItems = false
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        return outline
    }

    static func makeScrollView(documentView outline: GitHistoryNSOutlineView) -> NSScrollView {
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
                controller?.noteScrollOffset(scroll.contentView.bounds.minY)
                controller?.noteScrolled(visibleMaxY: scroll.contentView.bounds.maxY)
            }
        }
        return scroll
    }

    // Runs during a SwiftUI update: nothing reached from here may publish
    // to the view model synchronously. `apply` only drives the outline.
    func updateNSView(_: NSScrollView, context: Context) {
        let controller = context.coordinator.controller
        controller.palette = palette
        controller.actionHandler = actionHandler
        controller.apply(commits: viewModel.commits, expanded: viewModel.expanded)
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.scrollObserver = nil
        }
    }
}
