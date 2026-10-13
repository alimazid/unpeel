import AppKit
import XCTest
@testable import UnpeelExplorer

@MainActor
private final class RecordingHandler: ExplorerActionHandler {
    var canSendToAgent = true
    /// Paths passed to `openFile` (open-with rules).
    var openedWithRules: [String] = []
    /// Paths passed to `openInEditor` (explicit editor bypass).
    var opened: [String] = []
    var sent: [String] = []
    /// Paths passed to `openMarkdownEditor` (the "Open in Markdown Editor" menu item).
    var editedInMarkdown: [String] = []
    func openFile(path: String) { openedWithRules.append(path) }
    func openInEditor(path: String) { opened.append(path) }
    func sendPathToAgent(path: String) { sent.append(path) }
    func openMarkdownEditor(path: String) { editedInMarkdown.append(path) }
}

@MainActor
final class ExplorerOutlineControllerTests: XCTestCase {
    private let root = "/r"

    private func makeController() -> (ExplorerOutlineController, ExplorerViewModel, String) {
        let suite = "unpeel.explorer.outlinetests.\(UUID().uuidString)"
        let viewModel = ExplorerViewModel(
            services: ExplorerServices(scan: { _, _ in DirectoryListing(entries: []) }, makeWatcher: { _, _ in nil }),
            stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!)
        )
        return (ExplorerOutlineController(viewModel: viewModel, palette: .system), viewModel, suite)
    }

    private func sampleModel(truncated: Int = 0) -> FileTreeModel {
        FileTreeModel(root: root)
            .settingContents(
                .loaded(DirectoryListing(
                    entries: [
                        FileEntry(path: "/r/src", name: "src", kind: .directory),
                        FileEntry(path: "/r/.env", name: ".env", kind: .file, isHidden: true),
                        FileEntry(path: "/r/README.md", name: "README.md", kind: .file),
                        FileEntry(path: "/r/a.txt", name: "a.txt", kind: .file),
                    ],
                    truncatedCount: truncated
                )),
                for: root
            )
            .settingContents(.failed("Permission denied"), for: "/r/src")
            .expanding("/r/src")
    }

    func testChildrenFollowTheFilter() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        XCTAssertEqual(controller.children(of: root).map(\.path), ["/r/src", "/r/README.md", "/r/a.txt"])

        controller.apply(model: sampleModel(), filter: VisibilityFilter(showHidden: true), selection: [])
        XCTAssertEqual(controller.children(of: root).map(\.path), ["/r/src", "/r/.env", "/r/README.md", "/r/a.txt"])
    }

    func testTruncatedAndFailedDirectoriesGetANoteRow() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        controller.apply(model: sampleModel(truncated: 12), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.children(of: root).last?.role, .note)
        XCTAssertEqual(controller.noteText(forDirectory: root), "… 12 more items not shown")
        XCTAssertEqual(controller.children(of: "/r/src").map(\.role), [.note])
        XCTAssertEqual(controller.noteText(forDirectory: "/r/src"), "Permission denied")
    }

    /// A note row's identity (the `ExplorerItem` instance) must stay stable
    /// even as its text changes (e.g. the truncated count growing), since
    /// the role no longer carries the text itself.
    func testNoteTextUpdatesWhileTheItemIdentityStaysStable() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        controller.apply(model: sampleModel(truncated: 5), filter: VisibilityFilter(), selection: [])
        let before = controller.children(of: root).last
        XCTAssertEqual(controller.noteText(forDirectory: root), "… 5 more items not shown")

        controller.apply(model: sampleModel(truncated: 9), filter: VisibilityFilter(), selection: [])
        let after = controller.children(of: root).last

        XCTAssertTrue(before === after)
        XCTAssertEqual(controller.noteText(forDirectory: root), "… 9 more items not shown")
    }

    func testItemsKeepTheirIdentityAcrossReloads() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        let before = controller.children(of: root).first

        let grown = sampleModel().settingContents(
            .loaded(DirectoryListing(entries: [
                FileEntry(path: "/r/src", name: "src", kind: .directory),
                FileEntry(path: "/r/a.txt", name: "a.txt", kind: .file),
                FileEntry(path: "/r/b.txt", name: "b.txt", kind: .file),
            ])),
            for: root
        )
        controller.apply(model: grown, filter: VisibilityFilter(), selection: [])

        XCTAssertTrue(before === controller.children(of: root).first)
        XCTAssertEqual(controller.children(of: root).count, 3)
    }

    func testDataSourceAnswersForAnAttachedOutlineView() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.attach(to: outline)

        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        // Three visible root entries with the default filter: "src", "README.md", "a.txt".
        XCTAssertEqual(controller.outlineView(outline, numberOfChildrenOfItem: nil), 3)
        let first = controller.outlineView(outline, child: 0, ofItem: nil)
        XCTAssertEqual((first as? ExplorerItem)?.path, "/r/src")
        XCTAssertTrue(controller.outlineView(outline, isItemExpandable: first))
        let second = controller.outlineView(outline, child: 1, ofItem: nil)
        XCTAssertFalse(controller.outlineView(outline, isItemExpandable: second))
    }

    func testMenuActionsDependOnTheTarget() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.menuActions(for: nil), [.newFile, .newFolder, nil, .refresh])
        XCTAssertEqual(
            controller.menuActions(for: "/r/a.txt"),
            [.open, .openInEditor, .revealInFinder, .quickLook, nil, .newFile, .newFolder, nil, .sendToAgent, nil,
             .copyPath, .copyRelativePath, nil, .rename, .trash, nil, .refresh]
        )
        XCTAssertEqual(
            controller.menuActions(for: "/r/src"),
            [.revealInFinder, nil, .newFile, .newFolder, nil, .sendToAgent, nil, .copyPath, .copyRelativePath, nil,
             .rename, .trash, nil, .refresh, .collapse]
        )

        handler.canSendToAgent = false
        XCTAssertFalse(controller.menuActions(for: "/r/a.txt").contains(.sendToAgent))
    }

    func testPerformRoutesToTheHandlerAndPasteboard() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        controller.actionHandler = handler
        controller.pasteboard = pasteboard
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.perform(.openInEditor, on: ["/r/a.txt"])
        controller.perform(.sendToAgent, on: ["/r/a.txt"])
        XCTAssertEqual(handler.opened, ["/r/a.txt"])
        XCTAssertEqual(handler.sent, ["/r/a.txt"])

        controller.perform(.copyPath, on: ["/r/a.txt", "/r/src"])
        XCTAssertEqual(pasteboard.string(forType: .string), "/r/a.txt\n/r/src")

        controller.perform(.copyRelativePath, on: ["/r/a.txt"])
        XCTAssertEqual(pasteboard.string(forType: .string), "a.txt")
    }

    func testOpenKeyCommandOpensSelectedFilesThroughTheRules() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(showHidden: true), selection: [])
        viewModel.selection = ["/r/.env", "/r/a.txt"]

        XCTAssertTrue(controller.handleKeyCommand(.open))
        XCTAssertEqual(handler.openedWithRules, ["/r/.env", "/r/a.txt"])
        XCTAssertEqual(handler.opened, [])
    }

    /// Regression: Space must CLOSE an already-open Quick Look panel (as in
    /// Finder/Xcode/VS Code), so the key command must TOGGLE, while the
    /// context-menu action must always SHOW (open, or refresh if already
    /// open) rather than closing it out from under the user. Uses the
    /// controller's injectable hooks so the real, process-wide
    /// `QLPreviewPanel` is never touched.
    func testQuickLookKeyCommandTogglesWhileMenuActionShows() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        viewModel.selection = ["/r/a.txt"]

        var invoked: [String] = []
        controller.toggleQuickLookHook = { invoked.append("toggle") }
        controller.showQuickLookHook = { invoked.append("show") }

        XCTAssertTrue(controller.handleKeyCommand(.quickLook))
        XCTAssertEqual(invoked, ["toggle"])

        controller.perform(.quickLook, on: ["/r/a.txt"])
        XCTAssertEqual(invoked, ["toggle", "show"])
    }

    // MARK: - Review fix: phase-1 probes (compile against the unfixed source)

    /// Bug: the current `.quickLook` case in `handleKeyCommand` never checks
    /// whether the selection contains a file before calling
    /// `outlineView?.toggleQuickLook()` and returning `true`. For a
    /// directory-only selection this both toggles a Quick Look panel that
    /// has nothing to preview AND swallows the key (returns `true`) so it's
    /// never passed on. Expected: `false` (not consumed) when there is no
    /// file in the selection.
    func testQuickLookKeyCommandRequiresAFileInSelection() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        viewModel.selection = ["/r/src"]

        XCTAssertFalse(controller.handleKeyCommand(.quickLook))
    }

    /// Bug: `perform(.openInEditor, on:)` currently has no kind check and
    /// forwards every path to `openInEditor`, so a mixed selection sends a
    /// directory path to the editor too.
    func testPerformOpenInEditorSkipsDirectories() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.perform(.openInEditor, on: ["/r/a.txt", "/r/src"])

        XCTAssertEqual(handler.opened, ["/r/a.txt"])
    }

    /// Double-click is the primary "open" gesture and must go through the
    /// app's open-with rules (`openFile`), never straight to the editor;
    /// a directory double-click stays a no-op here (expansion is on click).
    func testDoubleClickOpensAFileThroughTheRulesAndIgnoresDirectories() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.doubleClick(onPath: "/r/a.txt")
        controller.doubleClick(onPath: "/r/src")
        controller.doubleClick(onPath: "/r/missing.txt")

        XCTAssertEqual(handler.openedWithRules, ["/r/a.txt"])
        XCTAssertEqual(handler.opened, [])
    }

    /// The two menu items are distinct intents: "Open" → rules, "Open in
    /// Editor" → editor. Each must call only its own handler member, and
    /// both skip directories in a mixed target set.
    func testPerformOpenAndOpenInEditorCallDistinctHandlerMembers() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.perform(.open, on: ["/r/a.txt", "/r/src"])
        XCTAssertEqual(handler.openedWithRules, ["/r/a.txt"])
        XCTAssertEqual(handler.opened, [])

        controller.perform(.openInEditor, on: ["/r/src", "/r/a.txt"])
        XCTAssertEqual(handler.openedWithRules, ["/r/a.txt"])
        XCTAssertEqual(handler.opened, ["/r/a.txt"])
    }

    func testOpenMenuActionTitle() {
        XCTAssertEqual(ExplorerOutlineController.MenuAction.open.title, "Open")
        XCTAssertEqual(ExplorerOutlineController.MenuAction.openInEditor.title, "Open in Editor")
    }

    /// `perform(.collapse, on:)` should only ever act on currently-expanded
    /// directories in the target set; a file included alongside must not
    /// affect the result (and must not crash). Uses a real, filesystem-backed
    /// view model (rather than `makeController()`'s directly-injected
    /// model) so the outline's `collapseItem` → `outlineViewItemDidCollapse`
    /// → `viewModel.collapse` delegate path is genuinely exercised, and a
    /// double write (both the delegate path AND a direct `viewModel.collapse`
    /// call) would be observable as a redundant no-op rather than invisible.
    func testPerformCollapseSkipsFiles() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.dir("src")
        try tree.file("a.txt")

        let suite = "unpeel.explorer.outlinetests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let viewModel = ExplorerViewModel(
            services: ExplorerServices(
                scan: { directory, root in try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root) },
                makeWatcher: { _, _ in nil }
            ),
            stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!)
        )
        let controller = ExplorerOutlineController(viewModel: viewModel, palette: .system)
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.attach(to: outline)

        await viewModel.setContext(.local(root: tree.root, projectRoot: tree.root)).value
        await viewModel.expand(tree.path("src")).value
        controller.apply(model: viewModel.model, filter: viewModel.filter, selection: viewModel.selection)

        let srcPath = tree.path("src")
        let srcItem = controller.children(of: tree.root).first { $0.path == srcPath }!
        XCTAssertTrue(outline.isItemExpanded(srcItem))
        XCTAssertTrue(viewModel.model?.expanded.contains(srcPath) ?? false)

        controller.perform(.collapse, on: [tree.path("a.txt"), srcPath])

        XCTAssertFalse(outline.isItemExpanded(srcItem))
        XCTAssertFalse(viewModel.model?.expanded.contains(srcPath) ?? true)
    }

    /// Bug: `apply()` currently clears the path-keyed `items` identity map
    /// on a FILTER-only change (not just a root change), even though item
    /// identity is path-based and filter-independent. `syncExpansion` and
    /// `syncSelection` then look items up in that map two lines later,
    /// which only works if `reloadData()` happened to re-populate it
    /// synchronously first — expansion/selection can silently be dropped.
    func testFilterChangeKeepsIdentityExpansionAndSelection() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.attach(to: outline)

        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: ["/r/a.txt"])
        let srcItemBefore = controller.children(of: root).first { $0.path == "/r/src" }!
        XCTAssertTrue(outline.isItemExpanded(srcItemBefore))
        XCTAssertEqual(
            outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ExplorerItem)?.path },
            ["/r/a.txt"]
        )

        controller.apply(model: sampleModel(), filter: VisibilityFilter(showHidden: true), selection: ["/r/a.txt"])

        let srcItemAfter = controller.children(of: root).first { $0.path == "/r/src" }!
        XCTAssertTrue(srcItemBefore === srcItemAfter)
        XCTAssertTrue(outline.isItemExpanded(srcItemAfter))
        XCTAssertEqual(
            outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ExplorerItem)?.path },
            ["/r/a.txt"]
        )
    }

    // MARK: - Review fix: phase-2 (new API)

    func testTargetPathsPrefersTheWholeSelectionWhenClickedIsInsideIt() {
        XCTAssertEqual(
            ExplorerOutlineController.targetPaths(clicked: "/r/a.txt", selection: ["/r/src", "/r/a.txt"]),
            ["/r/src", "/r/a.txt"]
        )
        XCTAssertEqual(
            ExplorerOutlineController.targetPaths(clicked: "/r/other", selection: ["/r/a.txt"]),
            ["/r/other"]
        )
        XCTAssertEqual(ExplorerOutlineController.targetPaths(clicked: nil, selection: ["/r/a.txt"]), [])
    }

    /// A mixed target set (a file plus an expanded directory) must offer
    /// the file-only and directory-only actions together, regardless of
    /// which path is first — this is what fixes both "a folder-topmost
    /// mixed selection hides Open in Editor" and the old
    /// `menuActions(for: .first)` design.
    func testMenuActionsForTargetsConsidersTheWholeSet() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        let expected: [ExplorerOutlineController.MenuAction?] = [
            .open, .openInEditor, .revealInFinder, .quickLook, nil,
            .newFile, .newFolder, nil,
            .sendToAgent, nil,
            .copyPath, .copyRelativePath, nil,
            .trash, nil,
            .refresh, .collapse,
        ]
        XCTAssertEqual(controller.menuActions(forTargets: ["/r/a.txt", "/r/src"]), expected)
        XCTAssertEqual(controller.menuActions(forTargets: ["/r/src", "/r/a.txt"]), expected)
        XCTAssertEqual(controller.menuActions(forTargets: []), [.newFile, .newFolder, nil, .refresh])
    }

    /// End-to-end: `menuNeedsUpdate` (via the internal `rebuildMenuItems`
    /// seam) captures the target paths once on the menu item; choosing the
    /// item must act on exactly that captured set, filtered for the
    /// action's own kind requirement (files only, for Open in Editor) —
    /// never re-read `clickedRow` at click time.
    func testMenuItemPayloadCarriesTheCapturedTargetsAndFiltersByKind() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        let menu = NSMenu()
        controller.rebuildMenuItems(menu, forTargets: ["/r/a.txt", "/r/src"])

        guard let openItem = menu.items.first(where: { $0.title == "Open in Editor" }) else {
            return XCTFail("expected an Open in Editor item")
        }
        _ = (openItem.target as? NSObjectProtocol)?.perform(openItem.action, with: openItem)

        XCTAssertEqual(handler.opened, ["/r/a.txt"])
    }

    func testPreviewPathsYieldsOnlyFilesInSelectionOrder() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.attach(to: outline)
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        viewModel.selection = ["/r/src", "/r/a.txt"]

        XCTAssertEqual(outline.previewPaths(), ["/r/a.txt"])
    }

    /// Previewing must not double as a selection change: a menu Quick Look
    /// on a mixed target set previews the files while the folders stay
    /// selected, and a Quick Look on a path outside the selection previews
    /// that path without stealing the selection from the rows the user
    /// actually picked.
    func testMenuQuickLookPreviewsFilesWithoutChangingTheSelection() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.attach(to: outline)
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        viewModel.selection = ["/r/src", "/r/a.txt"]

        controller.perform(.quickLook, on: ["/r/src", "/r/a.txt"])

        XCTAssertEqual(viewModel.selection, ["/r/src", "/r/a.txt"])
        XCTAssertEqual(outline.previewPaths(), ["/r/a.txt"])

        // Right-click Quick Look on a row outside the selection.
        viewModel.selection = ["/r/src"]
        controller.perform(.quickLook, on: ["/r/a.txt"])

        XCTAssertEqual(viewModel.selection, ["/r/src"])
        XCTAssertEqual(outline.previewPaths(), ["/r/a.txt"])

        // The next selection change drops the override.
        controller.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
        XCTAssertEqual(outline.previewPaths(), [])
    }

    /// Note rows ("… 50 more items not shown") must truncate at the TAIL —
    /// middle truncation turns them into "… 50…ot shown" at the panel's
    /// 180 pt minimum width — while entries keep middle truncation so a
    /// long name's extension stays visible. Set on every `configure`, since
    /// AppKit recycles cells between the two roles.
    func testLineBreakModeFollowsTheRowRole() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.apply(model: sampleModel(truncated: 50), filter: VisibilityFilter(), selection: [])

        let cell = ExplorerRowCellView()
        cell.imageView = NSImageView()
        cell.textField = NSTextField(labelWithString: "")

        let noteItem = controller.children(of: root).last!
        XCTAssertEqual(noteItem.role, .note)
        controller.configure(cell, for: noteItem)
        XCTAssertEqual(cell.textField?.lineBreakMode, .byTruncatingTail)

        // The same recycled cell, now reused for an entry row.
        let entryItem = controller.children(of: root).first!
        XCTAssertEqual(entryItem.role, .entry)
        controller.configure(cell, for: entryItem)
        XCTAssertEqual(cell.textField?.lineBreakMode, .byTruncatingMiddle)
    }

    /// A cell AppKit hands back for reuse may carry an entry's `toolTip`
    /// (the "points outside the project folder" message) from a previous
    /// row; the note branch must not leave it in place.
    func testConfigureResetsStateOnAReusedCell() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        let cell = ExplorerRowCellView()
        cell.imageView = NSImageView()
        cell.textField = NSTextField(labelWithString: "")
        cell.toolTip = "stale tooltip from a previous row"
        cell.alphaValue = 0.5
        cell.imageView?.image = NSImage()

        let noteItem = controller.children(of: "/r/src").first!
        controller.configure(cell, for: noteItem)

        XCTAssertNil(cell.toolTip)
        XCTAssertEqual(cell.alphaValue, 1)
        XCTAssertNil(cell.imageView?.image)
    }

    func testPasteboardWriterForItem() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.attach(to: outline)
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        let fileItem = controller.children(of: root).first { $0.path == "/r/a.txt" }!
        let writer = controller.outlineView(outline, pasteboardWriterForItem: fileItem)
        XCTAssertEqual((writer as? NSURL)?.path, "/r/a.txt")

        let noteItem = controller.children(of: "/r/src").first!
        XCTAssertNil(controller.outlineView(outline, pasteboardWriterForItem: noteItem))
    }

    func testShouldSelectItemIsFalseForNoteRows() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        let noteItem = controller.children(of: "/r/src").first!
        XCTAssertFalse(controller.outlineView(outline, shouldSelectItem: noteItem))

        let entryItem = controller.children(of: root).first!
        XCTAssertTrue(controller.outlineView(outline, shouldSelectItem: entryItem))
    }

    func testCopyPathKeyCommands() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        controller.pasteboard = pasteboard
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        viewModel.selection = ["/r/a.txt", "/r/src"]

        XCTAssertTrue(controller.handleKeyCommand(.copyPath))
        XCTAssertEqual(pasteboard.string(forType: .string), "/r/a.txt\n/r/src")

        XCTAssertTrue(controller.handleKeyCommand(.copyRelativePath))
        XCTAssertEqual(pasteboard.string(forType: .string), "a.txt\nsrc")
    }

    /// Only the directory whose own contents changed should have its
    /// `childCache` entry invalidated; an unrelated sibling directory keeps
    /// serving the same cached `ExplorerItem` array.
    func testIncrementalReloadOnlyInvalidatesTheChangedNestedDirectory() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let base = FileTreeModel(root: root)
            .settingContents(.loaded(DirectoryListing(entries: [
                FileEntry(path: "/r/src", name: "src", kind: .directory),
                FileEntry(path: "/r/lib", name: "lib", kind: .directory),
            ])), for: root)
            .settingContents(.loaded(DirectoryListing(entries: [
                FileEntry(path: "/r/src/a.swift", name: "a.swift", kind: .file),
            ])), for: "/r/src")
            .settingContents(.loaded(DirectoryListing(entries: [
                FileEntry(path: "/r/lib/b.swift", name: "b.swift", kind: .file),
            ])), for: "/r/lib")
            .expanding("/r/src")
            .expanding("/r/lib")

        controller.apply(model: base, filter: VisibilityFilter(), selection: [])
        let libChildrenBefore = controller.children(of: "/r/lib")

        let grown = base.settingContents(.loaded(DirectoryListing(entries: [
            FileEntry(path: "/r/src/a.swift", name: "a.swift", kind: .file),
            FileEntry(path: "/r/src/c.swift", name: "c.swift", kind: .file),
        ])), for: "/r/src")
        controller.apply(model: grown, filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.children(of: "/r/src").map(\.path), ["/r/src/a.swift", "/r/src/c.swift"])
        let libChildrenAfter = controller.children(of: "/r/lib")
        XCTAssertEqual(libChildrenAfter.map(\.path), libChildrenBefore.map(\.path))
        XCTAssertTrue(libChildrenAfter.first === libChildrenBefore.first)
    }

    // MARK: - Markdown routing (Fork-only: markdown preview pane)

    func testMenuOffersMarkdownEditorOnlyForMarkdownOnlyFileTargets() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(
            Array(controller.menuActions(for: "/r/README.md").prefix(6)),
            [.open, .openInMarkdownEditor, .openInEditor, .revealInFinder, .quickLook, nil]
        )
        XCTAssertEqual(
            Array(controller.menuActions(for: "/r/a.txt").prefix(5)),
            [.open, .openInEditor, .revealInFinder, .quickLook, nil]
        )
        XCTAssertFalse(controller.menuActions(forTargets: ["/r/README.md", "/r/a.txt"]).contains(.openInMarkdownEditor))
        XCTAssertFalse(controller.menuActions(forTargets: ["/r/README.md", "/r/src"]).contains(.openInMarkdownEditor))
    }

    func testPerformOpenInMarkdownEditorOnlyForwardsMarkdownFiles() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.perform(.openInMarkdownEditor, on: ["/r/README.md", "/r/a.txt", "/r/src"])
        XCTAssertEqual(handler.editedInMarkdown, ["/r/README.md"])
        XCTAssertEqual(handler.openedWithRules, [])
        XCTAssertEqual(handler.opened, [])
        XCTAssertEqual(ExplorerOutlineController.MenuAction.openInMarkdownEditor.title, "Open in Markdown Editor")
    }
}
