import AppKit

@MainActor
public final class ExplorerOutlineController: NSObject,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate
{
    public enum MenuAction: String, Equatable {
        case openInEditor, revealInFinder, quickLook, sendToAgent
        case copyPath, copyRelativePath, refresh, collapse

        var title: String {
            switch self {
            case .openInEditor: return "Open in Editor"
            case .revealInFinder: return "Reveal in Finder"
            case .quickLook: return "Quick Look"
            case .sendToAgent: return "Send Path to Agent"
            case .copyPath: return "Copy Path"
            case .copyRelativePath: return "Copy Relative Path"
            case .refresh: return "Refresh"
            case .collapse: return "Collapse"
            }
        }
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("unpeel.explorer.cell")
    private static let noteSuffix = "/\u{0}note"

    public let viewModel: ExplorerViewModel
    public weak var actionHandler: (any ExplorerActionHandler)?
    public var palette: ExplorerPalette
    public var pasteboard: NSPasteboard = .general
    public private(set) weak var outlineView: ExplorerNSOutlineView?

    /// Routes the "Quick Look" key command and menu action through
    /// overridable hooks — rather than calling `outlineView?.toggleQuickLook()`
    /// / `.showQuickLook()` directly — so a test can observe which one the
    /// controller requests without touching the real, process-wide
    /// `QLPreviewPanel`. Defaulted in `init` to the real outline view calls.
    var toggleQuickLookHook: () -> Void = {}
    var showQuickLookHook: () -> Void = {}

    private let icons = FileIconProvider()
    private var items: [String: ExplorerItem] = [:]
    private var childCache: [String: [ExplorerItem]] = [:]
    private var applied: FileTreeModel?
    private var appliedFilter = VisibilityFilter()
    private var appliedRestoreToken = 0
    /// True while this controller changes the outline view itself, so its
    /// delegate callbacks are not echoed back into the view model.
    private var isApplying = false

    public init(viewModel: ExplorerViewModel, palette: ExplorerPalette) {
        self.viewModel = viewModel
        self.palette = palette
        super.init()
        toggleQuickLookHook = { [weak self] in self?.outlineView?.toggleQuickLook() }
        showQuickLookHook = { [weak self] in self?.outlineView?.showQuickLook() }
    }

    public func attach(to outlineView: ExplorerNSOutlineView) {
        self.outlineView = outlineView
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleClick)
        outlineView.doubleAction = #selector(handleDoubleClick)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.keyCommandHandler = { [weak self] in self?.handleKeyCommand($0) ?? false }
        outlineView.previewPaths = { [weak self] in self?.selectedFilePaths() ?? [] }
    }

    // MARK: - Applying model changes

    public func apply(model: FileTreeModel?, filter: VisibilityFilter, selection: [String]) {
        isApplying = true
        defer { isApplying = false }
        let previous = applied
        let previousFilter = appliedFilter
        applied = model
        appliedFilter = filter
        guard let model else {
            items = [:]
            childCache = [:]
            outlineView?.reloadData()
            return
        }
        let rootChanged = previous?.root != model.root
        let filterChanged = previousFilter != filter
        // Item identity is path-based and filter-independent (a filter only
        // changes which paths are children, never what a given path's item
        // is) — clearing `items` here too would make `syncExpansion` and
        // `syncSelection` below depend on `reloadData()` having already
        // re-queried the data source synchronously to repopulate it, which
        // AppKit does not guarantee, and could silently drop expansion and
        // selection until the next reload.
        if rootChanged {
            items = [:]
        }
        if rootChanged || filterChanged {
            childCache = [:]
            outlineView?.reloadData()
        } else if let previous {
            let changed = Set(previous.directories.keys).union(model.directories.keys)
                .filter { previous.directories[$0] != model.directories[$0] }
                .sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
            for directory in changed {
                childCache[directory] = nil
                if directory == model.root {
                    outlineView?.reloadItem(nil, reloadChildren: true)
                } else if let item = items[directory] {
                    outlineView?.reloadItem(item, reloadChildren: true)
                }
            }
        }
        syncExpansion(model)
        syncSelection(selection)
    }

    /// Scrolls to the view model's restored offset once per restore.
    public func applyRestoredScrollIfNeeded() {
        guard viewModel.restoreToken != appliedRestoreToken,
              let clipView = outlineView?.enclosingScrollView?.contentView
        else { return }
        appliedRestoreToken = viewModel.restoreToken
        clipView.scroll(to: NSPoint(x: 0, y: viewModel.scrollOffset))
        outlineView?.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    public func noteScrolled(to offset: Double) {
        guard !isApplying else { return }
        viewModel.scrollOffset = offset
    }

    private func syncExpansion(_ model: FileTreeModel) {
        guard let outlineView else { return }
        let shallowFirst = model.expanded.sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
        for path in shallowFirst {
            guard let item = items[path], outlineView.row(forItem: item) >= 0,
                  !outlineView.isItemExpanded(item)
            else { continue }
            outlineView.expandItem(item)
        }
        var row = 0
        while row < outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? ExplorerItem,
               outlineView.isItemExpanded(item), !model.expanded.contains(item.path) {
                outlineView.collapseItem(item)
            }
            row += 1
        }
    }

    private func syncSelection(_ selection: [String]) {
        guard let outlineView else { return }
        let rows = IndexSet(
            selection.compactMap { items[$0] }.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 }
        )
        guard rows != outlineView.selectedRowIndexes else { return }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: - Rows

    public func children(of directory: String) -> [ExplorerItem] {
        if let cached = childCache[directory] { return cached }
        guard let model = applied else { return [] }
        let entries = model.visibleChildren(of: directory, filter: appliedFilter)
            .map { item(for: $0.path, role: .entry) }
        let built = entries + noteRows(for: directory)
        childCache[directory] = built
        return built
    }

    private func noteRows(for directory: String) -> [ExplorerItem] {
        guard noteText(forDirectory: directory) != nil else { return [] }
        return [item(for: directory + Self.noteSuffix, role: .note)]
    }

    /// The live text for a directory's note row (a load failure, or a
    /// truncated-count message), looked up by directory rather than stored
    /// on the (identity-only) `.note` item — so the row's identity stays
    /// stable across reloads even as this text changes.
    func noteText(forDirectory directory: String) -> String? {
        guard let applied else { return nil }
        if case .failed(let message)? = applied.directories[directory] {
            return message
        }
        let hidden = applied.truncatedCount(of: directory)
        guard hidden > 0 else { return nil }
        return "… \(hidden) more items not shown"
    }

    private func item(for path: String, role: ExplorerItem.Role) -> ExplorerItem {
        if let existing = items[path], existing.role == role { return existing }
        let created = ExplorerItem(path: path, role: role)
        items[path] = created
        return created
    }

    private func directoryPath(of item: Any?) -> String {
        (item as? ExplorerItem)?.path ?? applied?.root ?? ""
    }

    private func entry(for item: Any?) -> FileEntry? {
        guard let item = item as? ExplorerItem, item.role == .entry else { return nil }
        return applied?.entry(at: item.path)
    }

    // MARK: - NSOutlineViewDataSource

    public func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: directoryPath(of: item)).count
    }

    public func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: directoryPath(of: item))[index]
    }

    public func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        entry(for: item)?.isExpandable ?? false
    }

    public func outlineView(_: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let entry = entry(for: item) else { return nil }
        return NSURL(fileURLWithPath: entry.path)
    }

    // MARK: - NSOutlineViewDelegate

    public func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? ExplorerItem else { return nil }
        let cell = (outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView)
            ?? Self.makeCell()
        configure(cell, for: item)
        return cell
    }

    /// Populates a (possibly reused) cell from scratch. `makeView` may hand
    /// back a cell AppKit recycled from a different row's item, so every
    /// attribute one role can set — `toolTip`, dimmed `alphaValue`, the
    /// icon — is reset up front rather than only touched by the branch that
    /// happens to need it; otherwise a value set for an entry (e.g. a
    /// broken-symlink tooltip) can leak into a note row reusing that view.
    func configure(_ cell: NSTableCellView, for item: ExplorerItem) {
        cell.textField?.font = palette.rowFont
        cell.toolTip = nil
        cell.alphaValue = 1
        cell.imageView?.image = nil
        switch item.role {
        case .note:
            let directory = String(item.path.dropLast(Self.noteSuffix.count))
            cell.textField?.stringValue = noteText(forDirectory: directory) ?? ""
            cell.textField?.textColor = palette.secondaryText
        case .entry:
            let entry = applied?.entry(at: item.path)
            cell.imageView?.image = entry.map(icons.icon(for:))
            cell.textField?.stringValue = entry?.name ?? (item.path as NSString).lastPathComponent
            cell.textField?.textColor = palette.text
            cell.alphaValue = (entry?.isIgnored == true || entry?.isHidden == true) ? 0.5 : 1
            cell.toolTip = entry?.isSymlink == true && entry?.isExpandable == false && entry?.kind == .directory
                ? "This link points outside the project folder."
                : nil
        }
    }

    public func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? ExplorerItem)?.role == .entry
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplying, let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
        viewModel.expand(item.path)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplying, let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
        viewModel.collapse(item.path)
    }

    public func outlineViewSelectionDidChange(_: Notification) {
        guard !isApplying else { return }
        viewModel.selection = selectedPaths()
        outlineView?.reloadQuickLookIfVisible()
    }

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellIdentifier
        let image = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Selection helpers

    private func selectedPaths() -> [String] {
        guard let outlineView else { return viewModel.selection }
        return outlineView.selectedRowIndexes.compactMap {
            (outlineView.item(atRow: $0) as? ExplorerItem)?.path
        }
    }

    private func selectedFilePaths() -> [String] {
        viewModel.selection.filter { applied?.entry(at: $0)?.kind == .file }
    }

    private func menuTargetPaths() -> [String] {
        let clickedPath: String?
        if let outlineView, outlineView.clickedRow >= 0,
           let clicked = outlineView.item(atRow: outlineView.clickedRow) as? ExplorerItem,
           clicked.role == .entry {
            clickedPath = clicked.path
        } else {
            clickedPath = nil
        }
        return Self.targetPaths(clicked: clickedPath, selection: selectedPaths())
    }

    /// The clicked item if it's outside the selection, else the whole
    /// selection (in selection order). Pure so it's testable without
    /// faking `NSOutlineView.clickedRow`, which has no public setter.
    static func targetPaths(clicked: String?, selection: [String]) -> [String] {
        guard let clicked else { return [] }
        return selection.contains(clicked) ? selection : [clicked]
    }

    // MARK: - Clicks

    @objc private func handleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let item = outlineView.item(atRow: outlineView.clickedRow) as? ExplorerItem,
              entry(for: item)?.isExpandable == true
        else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        guard modifiers.intersection([.command, .shift]).isEmpty else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    @objc private func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let entry = entry(for: outlineView.item(atRow: outlineView.clickedRow)),
              entry.kind == .file
        else { return }
        actionHandler?.openInEditor(path: entry.path)
    }

    // MARK: - Context menu

    /// Menu actions for a single path, expressed in terms of
    /// `menuActions(forTargets:)` so the two can never disagree: `nil` (no
    /// path under the cursor / no selection) is the same as an empty
    /// target set.
    public func menuActions(for path: String?) -> [MenuAction?] {
        menuActions(forTargets: path.map { [$0] } ?? [])
    }

    /// Menu actions for the WHOLE target set, not just one representative
    /// path — a mixed selection (a file and an expanded directory) must
    /// offer "Open in Editor"/"Quick Look" (there's a file) AND "Collapse"
    /// (there's an expanded directory), regardless of which one is first or
    /// was clicked.
    public func menuActions(forTargets paths: [String]) -> [MenuAction?] {
        let resolved = resolvedEntries(for: paths)
        guard !resolved.isEmpty else { return [.refresh] }
        let hasFile = resolved.contains(where: { $0.entry.kind == .file })
        let hasExpandedDirectory = resolved.contains(where: {
            $0.entry.kind == .directory && applied?.expanded.contains($0.path) == true
        })
        let send: [MenuAction?] = actionHandler?.canSendToAgent == true ? [.sendToAgent, nil] : []
        let copy: [MenuAction?] = [.copyPath, .copyRelativePath, nil]
        var actions: [MenuAction?] = hasFile
            ? [.openInEditor, .revealInFinder, .quickLook, nil]
            : [.revealInFinder, nil]
        actions += send + copy + [.refresh]
        if hasExpandedDirectory {
            actions.append(.collapse)
        }
        return actions
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(menu, forTargets: menuTargetPaths())
    }

    /// Builds the context menu for an explicit target set, captured once so
    /// `performMenuItem` never re-reads `clickedRow` — which may have
    /// changed, or reset to -1, by the time the user actually chooses an
    /// item, well after `menuNeedsUpdate` ran. Internal so tests can drive
    /// it directly, without faking a real AppKit click to set `clickedRow`.
    func rebuildMenuItems(_ menu: NSMenu, forTargets paths: [String]) {
        menu.removeAllItems()
        for action in menuActions(forTargets: paths) {
            guard let action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: action.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuActionPayload(action: action, paths: paths)
            menu.addItem(item)
        }
    }

    /// Captures a menu item's action and its target paths together, so the
    /// paths acted on are exactly the ones the menu was built for.
    private final class MenuActionPayload: NSObject {
        let action: MenuAction
        let paths: [String]

        init(action: MenuAction, paths: [String]) {
            self.action = action
            self.paths = paths
        }
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuActionPayload else { return }
        perform(payload.action, on: payload.paths)
    }

    public func perform(_ action: MenuAction, on paths: [String]) {
        switch action {
        case .openInEditor:
            filesOnly(paths).forEach { actionHandler?.openInEditor(path: $0) }
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        case .quickLook:
            let files = filesOnly(paths)
            guard !files.isEmpty else { return }
            viewModel.selection = files
            showQuickLookHook()
        case .sendToAgent:
            paths.forEach { actionHandler?.sendPathToAgent(path: $0) }
        case .copyPath:
            copyToPasteboard(paths)
        case .copyRelativePath:
            let root = applied?.root ?? ""
            copyToPasteboard(paths.map { ExplorerPaths.relative($0, to: root) })
        case .refresh:
            viewModel.refresh()
        case .collapse:
            for path in expandedDirectoriesOnly(paths) {
                // If the outline already has this item expanded, collapsing
                // it there is enough — `outlineViewItemDidCollapse` updates
                // the view model. Writing `viewModel.collapse` as well
                // would persist state twice for one user action.
                if let outlineView, let item = items[path], outlineView.isItemExpanded(item) {
                    outlineView.collapseItem(item)
                } else {
                    viewModel.collapse(path)
                }
            }
        }
    }

    private func filesOnly(_ paths: [String]) -> [String] {
        resolvedEntries(for: paths).filter { $0.entry.kind == .file }.map(\.path)
    }

    private func expandedDirectoriesOnly(_ paths: [String]) -> [String] {
        resolvedEntries(for: paths)
            .filter { $0.entry.kind == .directory && applied?.expanded.contains($0.path) == true }
            .map(\.path)
    }

    /// Resolves every target path to its `FileEntry`, indexing each
    /// distinct parent directory's listing once (`FileTreeModel.entry(at:)`
    /// linearly scans the parent's listing per call, so resolving a large
    /// target set one path at a time — e.g. ⌘A in a 10,000-entry folder,
    /// then right-click — is O(target count × directory size)). Order of
    /// `paths` is preserved; unresolvable paths are dropped.
    private func resolvedEntries(for paths: [String]) -> [(path: String, entry: FileEntry)] {
        guard let applied else { return [] }
        var indexByParent: [String: [String: FileEntry]] = [:]
        var resolved: [(path: String, entry: FileEntry)] = []
        resolved.reserveCapacity(paths.count)
        for path in paths {
            let parent = FileTreeModel.parent(of: path)
            let index: [String: FileEntry]
            if let cached = indexByParent[parent] {
                index = cached
            } else if case .loaded(let listing)? = applied.directories[parent] {
                index = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.path, $0) })
                indexByParent[parent] = index
            } else {
                index = [:]
                indexByParent[parent] = index
            }
            if let entry = index[path] {
                resolved.append((path, entry))
            }
        }
        return resolved
    }

    private func copyToPasteboard(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Keyboard

    public func handleKeyCommand(_ command: ExplorerKeyCommand) -> Bool {
        let selection = viewModel.selection
        guard !selection.isEmpty else { return false }
        switch command {
        case .quickLook:
            // Space must be able to CLOSE an already-open panel (Finder,
            // Xcode and VS Code all do this) — toggle, not show.
            guard !selectedFilePaths().isEmpty else { return false }
            toggleQuickLookHook()
        case .open:
            for path in selection {
                guard let entry = applied?.entry(at: path) else { continue }
                if entry.kind == .file {
                    actionHandler?.openInEditor(path: path)
                } else if let item = items[path] {
                    outlineView?.expandItem(item)
                }
            }
        case .expandOrDescend:
            return expandOrDescend(selection)
        case .collapseOrAscend:
            return collapseOrAscend(selection)
        case .copyPath:
            perform(.copyPath, on: selection)
        case .copyRelativePath:
            perform(.copyRelativePath, on: selection)
        case .revealInFinder:
            perform(.revealInFinder, on: selection)
        }
        return true
    }

    private func expandOrDescend(_ selection: [String]) -> Bool {
        guard let outlineView, selection.count == 1, let item = items[selection[0]],
              entry(for: item)?.isExpandable == true
        else { return false }
        if !outlineView.isItemExpanded(item) {
            outlineView.expandItem(item)
        } else if let first = children(of: item.path).first, first.role == .entry {
            select(first)
        }
        return true
    }

    private func collapseOrAscend(_ selection: [String]) -> Bool {
        guard let outlineView, selection.count == 1, let item = items[selection[0]] else { return false }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else if let parent = outlineView.parent(forItem: item) as? ExplorerItem {
            select(parent)
        }
        return true
    }

    private func select(_ item: ExplorerItem) {
        guard let outlineView else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }
}
