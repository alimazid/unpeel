import AppKit
import Quartz

@MainActor
public final class ExplorerNSOutlineView: NSOutlineView {
    public var keyCommandHandler: ((ExplorerKeyCommand) -> Bool)?
    public var previewPaths: () -> [String] = { [] }

    public override func keyDown(with event: NSEvent) {
        if let command = ExplorerKeyCommand.from(keyCode: event.keyCode, modifiers: event.modifierFlags),
           keyCommandHandler?(command) == true {
            return
        }
        super.keyDown(with: event)
    }

    public func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
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
