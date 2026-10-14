import AppKit
import XCTest
@testable import UnpeelExplorer

/// Fork-only: explorer operations. A view model with real scans, no
/// watcher (so whatever is on screen came from the operation itself) and
/// a folder Trash, plus a headless outline driven by its controller.
@MainActor
class ExplorerOperationTestCase: ExplorerViewModelTestCase {
    var trash: FolderTrash!

    override func setUp() async throws {
        trash = try FolderTrash()
    }

    private var window: NSWindow?
    /// Never the general pasteboard: what the user copied must not leak in.
    let pasteboard = NSPasteboard.withUniqueName()

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        window?.close()
        window = nil
        trash.remove()
        try await super.tearDown()
    }

    /// The outline in a real window, so a name field can become first
    /// responder.
    func windowed(_ tree: TempTree) async -> (ExplorerOutlineController, ExplorerNSOutlineView, ExplorerViewModel) {
        let viewModel = await opened(tree)
        let (controller, outline) = attach(viewModel)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = ExplorerOutlineView.makeScrollView(documentView: outline)
        scroll.frame = window.contentLayoutRect
        window.contentView = scroll
        outline.layoutSubtreeIfNeeded()
        self.window = window
        sync(controller, viewModel)
        return (controller, outline, viewModel)
    }

    func type(_ text: String, into controller: ExplorerOutlineController) {
        guard let editor = controller.nameEditor else { return XCTFail("no name field open") }
        editor.field.currentEditor()?.string = text
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    func press(_ selector: Selector, in controller: ExplorerOutlineController) {
        guard let editor = controller.nameEditor, let text = editor.field.currentEditor() as? NSTextView else {
            return XCTFail("no name field open")
        }
        _ = editor.control(editor.field, textView: text, doCommandBy: selector)
    }

    let returnKey = #selector(NSResponder.insertNewline(_:))
    let escapeKey = #selector(NSResponder.cancelOperation(_:))

    /// Lets the main queue run what an update deferred (a Draft Row's field
    /// takes focus after the pass that inserted the row).
    func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func operationServices(trasher: (any Trasher)? = nil, delay: [String: TimeInterval] = [:]) -> ExplorerServices {
        let trasher = trasher ?? trash!
        return ExplorerServices(
            scan: { directory, root in
                if let pause = delay[directory] { Thread.sleep(forTimeInterval: pause) }
                return try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { _, _ in nil },
            makeOperations: { FileOperations(root: $0, trasher: trasher) }
        )
    }

    func opened(
        _ tree: TempTree, trasher: (any Trasher)? = nil, delay: [String: TimeInterval] = [:]
    ) async -> ExplorerViewModel {
        let viewModel = makeViewModel(operationServices(trasher: trasher, delay: delay))
        await viewModel.setContext(local(tree)).value
        return viewModel
    }

    /// The controller on a headless outline, kept alive by the outline.
    func attach(_ viewModel: ExplorerViewModel) -> (ExplorerOutlineController, ExplorerNSOutlineView) {
        let controller = ExplorerOutlineController(viewModel: viewModel, palette: .system)
        let outline = ExplorerOutlineView.makeOutlineView()
        controller.attach(to: outline)
        controller.pasteboard = pasteboard
        objc_setAssociatedObject(outline, "controller", controller, .OBJC_ASSOCIATION_RETAIN)
        sync(controller, viewModel)
        return (controller, outline)
    }

    /// What SwiftUI's `updateNSView` does after every published change.
    func sync(_ controller: ExplorerOutlineController, _ viewModel: ExplorerViewModel) {
        controller.apply(
            model: viewModel.model, filter: viewModel.filter, selection: viewModel.selection,
            decorations: viewModel.decorations, draft: viewModel.draft
        )
        controller.applyRevealIfNeeded()
    }

    /// Waits for every operation asked for so far, then syncs the outline.
    func settle(_ controller: ExplorerOutlineController, _ viewModel: ExplorerViewModel) async {
        await controller.pendingTransfer?.value
        await viewModel.operationTail?.value
        sync(controller, viewModel)
    }

    func names(_ viewModel: ExplorerViewModel, _ directory: String) -> [String] {
        viewModel.model?.visibleChildren(of: directory, filter: everything).map(\.name) ?? []
    }
}
