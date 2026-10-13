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

    override func tearDown() async throws {
        trash.remove()
        try await super.tearDown()
    }

    func operationServices(trasher: (any Trasher)? = nil) -> ExplorerServices {
        let trasher = trasher ?? trash!
        return ExplorerServices(
            scan: { directory, root in try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root) },
            makeWatcher: { _, _ in nil },
            makeOperations: { FileOperations(root: $0, trasher: trasher) }
        )
    }

    func opened(_ tree: TempTree, trasher: (any Trasher)? = nil) async -> ExplorerViewModel {
        let viewModel = makeViewModel(operationServices(trasher: trasher))
        await viewModel.setContext(local(tree)).value
        return viewModel
    }

    /// The controller on a headless outline, kept alive by the outline.
    func attach(_ viewModel: ExplorerViewModel) -> (ExplorerOutlineController, ExplorerNSOutlineView) {
        let controller = ExplorerOutlineController(viewModel: viewModel, palette: .system)
        let outline = ExplorerOutlineView.makeOutlineView()
        controller.attach(to: outline)
        objc_setAssociatedObject(outline, "controller", controller, .OBJC_ASSOCIATION_RETAIN)
        sync(controller, viewModel)
        return (controller, outline)
    }

    /// What SwiftUI's `updateNSView` does after every published change.
    func sync(_ controller: ExplorerOutlineController, _ viewModel: ExplorerViewModel) {
        controller.apply(
            model: viewModel.model, filter: viewModel.filter, selection: viewModel.selection,
            decorations: viewModel.decorations
        )
    }

    /// Waits for every operation asked for so far, then syncs the outline.
    func settle(_ controller: ExplorerOutlineController, _ viewModel: ExplorerViewModel) async {
        await viewModel.operationTail?.value
        sync(controller, viewModel)
    }

    func names(_ viewModel: ExplorerViewModel, _ directory: String) -> [String] {
        viewModel.model?.visibleChildren(of: directory, filter: everything).map(\.name) ?? []
    }
}
