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
        if previous?.root != model.root || previousFilter != filter {
            items = [:]
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
        let built = entries + noteRows(for: directory, in: model)
        childCache[directory] = built
        return built
    }

    private func noteRows(for directory: String, in model: FileTreeModel) -> [ExplorerItem] {
        if case .failed(let message)? = model.directories[directory] {
            return [item(for: directory + Self.noteSuffix, role: .note(message))]
        }
        let hidden = model.truncatedCount(of: directory)
        guard hidden > 0 else { return [] }
        return [item(for: directory + Self.noteSuffix, role: .note("… \(hidden) more items not shown"))]
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
        cell.textField?.font = palette.rowFont
        switch item.role {
        case .note(let text):
            cell.imageView?.image = nil
            cell.textField?.stringValue = text
            cell.textField?.textColor = palette.secondaryText
            cell.alphaValue = 1
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
        return cell
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

    /// The clicked row if it is outside the selection, else the selection.
    private func menuTargetPaths() -> [String] {
        guard let outlineView, outlineView.clickedRow >= 0,
              let clicked = outlineView.item(atRow: outlineView.clickedRow) as? ExplorerItem,
              clicked.role == .entry
        else { return [] }
        let selection = selectedPaths()
        return selection.contains(clicked.path) ? selection : [clicked.path]
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

    public func menuActions(for path: String?) -> [MenuAction?] {
        guard let path, let entry = applied?.entry(at: path) else { return [.refresh] }
        let send: [MenuAction?] = actionHandler?.canSendToAgent == true ? [.sendToAgent, nil] : []
        let copy: [MenuAction?] = [.copyPath, .copyRelativePath, nil]
        if entry.kind == .file {
            return [.openInEditor, .revealInFinder, .quickLook, nil] + send + copy + [.refresh]
        }
        let collapse: [MenuAction?] = applied?.expanded.contains(path) == true ? [.collapse] : []
        return [.revealInFinder, nil] + send + copy + [.refresh] + collapse
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for action in menuActions(for: menuTargetPaths().first) {
            guard let action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: action.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MenuAction(rawValue: raw) else { return }
        perform(action, on: menuTargetPaths())
    }

    public func perform(_ action: MenuAction, on paths: [String]) {
        switch action {
        case .openInEditor:
            paths.forEach { actionHandler?.openInEditor(path: $0) }
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        case .quickLook:
            viewModel.selection = paths
            outlineView?.toggleQuickLook()
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
            paths.forEach { path in
                if let item = items[path] { outlineView?.collapseItem(item) }
                viewModel.collapse(path)
            }
        }
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
            outlineView?.toggleQuickLook()
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
