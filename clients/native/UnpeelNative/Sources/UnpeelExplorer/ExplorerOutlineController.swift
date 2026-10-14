import AppKit
import UnpeelGit

@MainActor
public final class ExplorerOutlineController: NSObject,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate
{
    public enum MenuAction: String, Equatable {
        case open, openInMarkdownEditor, openInEditor, revealInFinder, quickLook, sendToAgent
        case copyPath, copyRelativePath, refresh, collapse
        // Fork-only: explorer operations.
        case newFile, newFolder, rename, trash, cut, copy, paste, duplicate

        var title: String {
            switch self {
            case .open: return "Open"
            case .openInMarkdownEditor: return "Open in Markdown Editor"
            case .openInEditor: return "Open in Editor"
            case .revealInFinder: return "Reveal in Finder"
            case .quickLook: return "Quick Look"
            case .sendToAgent: return "Send Path to Agent"
            case .copyPath: return "Copy Path"
            case .copyRelativePath: return "Copy Relative Path"
            case .refresh: return "Refresh"
            case .collapse: return "Collapse"
            case .newFile: return "New File…"
            case .newFolder: return "New Folder…"
            case .rename: return "Rename…"
            case .trash: return "Move to Trash"
            case .cut: return "Cut"
            case .copy: return "Copy"
            case .paste: return "Paste"
            case .duplicate: return "Duplicate"
            }
        }
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("unpeel.explorer.cell")
    private static let noteSuffix = "/\u{0}note"
    /// Fork-only: git support. A folder's decoration: VS Code marks a
    /// folder holding changes with a dot in their colour, not a letter.
    static let folderDecoration = "•"

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
    private(set) var items: [String: ExplorerItem] = [:]
    private var childCache: [String: [ExplorerItem]] = [:]
    private(set) var applied: FileTreeModel?
    /// What the OUTLINE VIEW currently has expanded, maintained from its
    /// expand/collapse notifications (which AppKit posts for programmatic
    /// changes as well as user ones). Paths whose rows a reload dropped are
    /// never notified about, so entries can go stale; `syncExpansion`
    /// re-checks each one against the view before acting on it.
    private var expandedPaths: Set<String> = []
    /// Paths a menu Quick Look targeted when they differ from the current
    /// selection. Previewing must not double as a selection change — the
    /// folders of a mixed selection would visibly deselect — so the preview
    /// reads this instead while it is set, and the next selection change
    /// clears it.
    private var quickLookOverridePaths: [String]?
    private var appliedFilter = VisibilityFilter()
    /// Fork-only: git support.
    private var appliedDecorations = GitDecorations.none
    private var appliedRestoreToken = 0
    /// Fork-only: explorer operations.
    private var appliedRevealToken: Int
    /// True while this controller changes the outline view itself, so its
    /// delegate callbacks are not echoed back into the view model.
    private var isApplying = false
    /// Fork-only: explorer operations. The name field being edited (a
    /// rename or a Draft Row), the folder whose rows it sits among, and
    /// that folder's reloads held back until it finishes — reloading the
    /// folder would replace the row and end the edit.
    var nameEditor: ExplorerNameEditor?
    var nameEditingFolder: String?
    var deferredReloads: Set<String> = []
    /// The Draft Row the outline shows.
    var appliedDraft: ExplorerDraft?
    /// Items cut and not yet pasted, and the pasteboard change whose cut
    /// was pasted already (pasted once only).
    var cutState: CutState?
    var consumedChangeCount: Int?
    /// Answers name collisions; nil asks with a sheet on the tree's window.
    public var collisionPrompt: (any CollisionPrompting)?
    /// A transfer still waiting on the Collision Prompt.
    var pendingTransfer: Task<Void, Never>?
    /// Written once in `attach`, read only in `deinit`.
    private nonisolated(unsafe) var appActivation: NSObjectProtocol?

    deinit {
        if let appActivation { NotificationCenter.default.removeObserver(appActivation) }
    }

    public init(viewModel: ExplorerViewModel, palette: ExplorerPalette) {
        self.viewModel = viewModel
        self.palette = palette
        appliedRevealToken = viewModel.revealToken
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
        outlineView.previewPaths = { [weak self] in self?.previewPaths() ?? [] }
        // Fork-only: explorer operations.
        outlineView.editTarget = self
        outlineView.dropHoverEnded = { [weak self] in self?.endDropHover() }
        appActivation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropStaleCut() }
        }
    }

    // MARK: - Applying model changes

    public func apply(
        model: FileTreeModel?, filter: VisibilityFilter, selection: [String], decorations: GitDecorations = .none,
        draft: ExplorerDraft? = nil
    ) {
        isApplying = true
        defer { isApplying = false }
        let previous = applied
        let previousFilter = appliedFilter
        let decorationsChanged = decorations != appliedDecorations
        applied = model
        appliedFilter = filter
        appliedDecorations = decorations
        guard let model else {
            appliedDraft = nil
            discardNameEditing()
            items = [:]
            childCache = [:]
            expandedPaths = []
            outlineView?.reloadData()
            return
        }
        reloadRows(from: previous, to: model, filterChanged: previousFilter != filter)
        syncExpansion(model)
        syncSelection(selection)
        if decorationsChanged { reconfigureLoadedRows() }
        // Fork-only: explorer operations.
        applyDraft(draft)
    }

    /// Reloads what changed between two models: everything for a new root
    /// or filter, otherwise only the directories whose contents changed.
    private func reloadRows(from previous: FileTreeModel?, to model: FileTreeModel, filterChanged: Bool) {
        let rootChanged = previous?.root != model.root
        // Item identity is path-based and filter-independent (a filter only
        // changes which paths are children, never what a given path's item
        // is) — clearing `items` here too would make `syncExpansion` and
        // `syncSelection` depend on `reloadData()` having already
        // re-queried the data source synchronously to repopulate it, which
        // AppKit does not guarantee, and could silently drop expansion and
        // selection until the next reload.
        if rootChanged {
            items = [:]
            expandedPaths = []
        }
        if rootChanged || filterChanged {
            // The rows are rebuilt; a Draft Row comes back with a new field.
            discardNameEditing()
            childCache = [:]
            outlineView?.reloadData()
            if let draft = appliedDraft {
                DispatchQueue.main.async { [weak self] in self?.beginDraftEditing(draft) }
            }
            return
        }
        guard let previous else { return }
        let changed = Set(previous.directories.keys).union(model.directories.keys)
            .filter { previous.directories[$0] != model.directories[$0] }
            .sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
        for directory in changed {
            reloadRowsUnlessEditing(directory)
        }
    }

    /// Fork-only: explorer operations. Reloading the edited folder or any
    /// folder above it rebuilds the edited row and ends the edit, so those
    /// wait until the field closes; while a drag is over the tree, every
    /// reload waits for it to leave.
    func reloadRowsUnlessEditing(_ directory: String) {
        if outlineView?.isDropTarget == true {
            deferredReloads.insert(directory)
        } else if let editing = nameEditingFolder, editing == directory || editing.hasPrefix(directory + "/") {
            deferredReloads.insert(directory)
        } else {
            reloadRows(of: directory)
        }
    }

    /// Fork-only: explorer operations. The reloads held back while a field
    /// was open, run once it closes — outside an update pass, so the
    /// selection AppKit drops on the reload is not published as the user's
    /// and the view model's selection and expansion are put back.
    func reloadHeldBack(_ folders: [String]) {
        let wasApplying = isApplying
        isApplying = true
        defer { isApplying = wasApplying }
        for folder in folders { reloadRows(of: folder) }
        guard !wasApplying, let applied else { return }
        syncExpansion(applied)
        syncSelection(viewModel.selection)
    }

    func reloadRows(of directory: String) {
        childCache[directory] = nil
        if directory == applied?.root {
            outlineView?.reloadItem(nil, reloadChildren: true)
        } else if let item = items[directory] {
            outlineView?.reloadItem(item, reloadChildren: true)
        }
    }

    /// Fork-only: git support. Rows AppKit already holds views for — on
    /// screen or prepared just off it — are not asked for again, so new
    /// decorations are applied to them in place.
    private func reconfigureLoadedRows() {
        outlineView?.enumerateAvailableRowViews { rowView, row in
            guard let item = self.outlineView?.item(atRow: row) as? ExplorerItem,
                  let cell = rowView.view(atColumn: 0) as? ExplorerRowCellView,
                  cell.textField !== self.nameEditor?.field
            else { return }
            self.configure(cell, for: item)
        }
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

    /// Fork-only: explorer operations. Scrolls the revealed selection's
    /// first row into view, once per reveal.
    public func applyRevealIfNeeded() {
        guard viewModel.revealToken != appliedRevealToken, let outlineView else { return }
        appliedRevealToken = viewModel.revealToken
        let rows = viewModel.selection.compactMap { items[$0] }.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 }
        guard let first = rows.min() else { return }
        outlineView.scrollRowToVisible(first)
    }

    public func noteScrolled(to offset: Double) {
        guard !isApplying else { return }
        viewModel.scrollOffset = offset
    }

    /// Scales with the number of EXPANDED folders, not with the number of
    /// rows: walking every row to ask `isItemExpanded` makes AppKit load
    /// each row's lazy info, which calls back into `isItemExpandable` —
    /// one full pass per `apply`, and `apply` runs on every published
    /// change. `expandedPaths` tracks what the outline itself reports as
    /// expanded (the notifications fire for programmatic changes too), so
    /// only those need checking against the model.
    private func syncExpansion(_ model: FileTreeModel) {
        guard let outlineView else { return }
        let shallowFirst = model.expanded.sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
        for path in shallowFirst {
            guard let item = items[path], outlineView.row(forItem: item) >= 0,
                  !outlineView.isItemExpanded(item)
            else { continue }
            outlineView.expandItem(item)
        }
        let stale = expandedPaths.subtracting(model.expanded)
            .sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
        for path in stale {
            guard let item = items[path], outlineView.row(forItem: item) >= 0,
                  outlineView.isItemExpanded(item)
            else { continue }
            outlineView.collapseItem(item)
        }
    }

    /// Paths whose rows are hidden under a collapsed parent are left in
    /// `viewModel.selection` by design: they have no row to select here, so
    /// they are simply not represented in `rows`, and re-expanding the
    /// parent brings them back. Reconciling the view model down to what is
    /// visible is Phase 2's multi-select work.
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
        let built = withDraftRow(entries, in: directory) + noteRows(for: directory)
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

    func item(for path: String, role: ExplorerItem.Role) -> ExplorerItem {
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
        let cell = (outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? ExplorerRowCellView)
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
    /// The label's truncation mode is set in BOTH branches for the same
    /// reason: the two roles want different modes.
    func configure(_ cell: ExplorerRowCellView, for item: ExplorerItem) {
        cell.textField?.font = palette.rowFont
        cell.decorationField?.font = palette.rowFont
        cell.decorationField?.stringValue = ""
        cell.toolTip = nil
        cell.alphaValue = 1
        cell.imageView?.image = nil
        switch item.role {
        case .draft:
            configureDraft(cell)
        case .note:
            let directory = String(item.path.dropLast(Self.noteSuffix.count))
            cell.textField?.stringValue = noteText(forDirectory: directory) ?? ""
            cell.restingTextColor = palette.secondaryText
            // A sentence, not a filename: middle truncation would render
            // "… 50 more items not shown" as "… 50…ot shown" at the panel's
            // 180 pt minimum width.
            cell.textField?.lineBreakMode = .byTruncatingTail
        case .entry:
            let entry = applied?.entry(at: item.path)
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            cell.imageView?.image = entry.map(icons.icon(for:))
            cell.textField?.stringValue = entry?.name ?? (item.path as NSString).lastPathComponent
            let decoration = entry.flatMap(decoration(for:))
            cell.restingTextColor = decoration?.color ?? palette.text
            cell.decorationField?.stringValue = decoration.map {
                entry?.kind == .directory ? Self.folderDecoration : $0.letter
            } ?? ""
            cell.alphaValue = (entry?.isIgnored == true || entry?.isHidden == true || isCut(item.path)) ? 0.5 : 1
            cell.toolTip = entry?.isSymlink == true && entry?.isExpandable == false && entry?.kind == .directory
                ? "This link points outside the project folder."
                : nil
        }
    }

    /// Fork-only: git support. An ignored entry has no git state to show;
    /// it stays dimmed as before.
    private func decoration(for entry: FileEntry) -> GitChangeKind? {
        entry.isIgnored ? nil : appliedDecorations.kind(at: entry.path)
    }

    public func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? ExplorerItem)?.role == .entry
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
        expandedPaths.insert(item.path)
        guard !isApplying else { return }
        viewModel.expand(item.path)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
        expandedPaths.remove(item.path)
        guard !isApplying else { return }
        viewModel.collapse(item.path)
    }

    public func outlineViewSelectionDidChange(_: Notification) {
        quickLookOverridePaths = nil
        guard !isApplying else { return }
        viewModel.selection = selectedPaths()
        outlineView?.reloadQuickLookIfVisible()
    }

    private static func makeCell() -> ExplorerRowCellView {
        let cell = ExplorerRowCellView()
        cell.identifier = cellIdentifier
        let image = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        // Fork-only: git support. The decoration keeps its width; a long
        // name truncates instead.
        let decoration = NSTextField(labelWithString: "")
        decoration.alignment = .right
        decoration.setContentHuggingPriority(.required, for: .horizontal)
        decoration.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        decoration.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        cell.addSubview(decoration)
        cell.imageView = image
        cell.textField = label
        cell.decorationField = decoration
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: decoration.leadingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            decoration.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            decoration.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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

    private func previewPaths() -> [String] {
        quickLookOverridePaths ?? selectedFilePaths()
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
              let entry = entry(for: outlineView.item(atRow: outlineView.clickedRow))
        else { return }
        doubleClick(onPath: entry.path)
    }

    /// Double-click on a file opens it through the app's open-with rules
    /// (`openFile`), never the editor directly. Directories do nothing here:
    /// a single click already toggles them. Internal so tests can drive it —
    /// `NSOutlineView.clickedRow` is read-only and needs a real click.
    func doubleClick(onPath path: String) {
        guard let entry = applied?.entry(at: path), entry.kind == .file else { return }
        actionHandler?.openFile(path: path)
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
    /// offer "Open"/"Open in Editor"/"Quick Look" (there's a file) AND
    /// "Collapse" (there's an expanded directory), regardless of which one
    /// is first or was clicked.
    public func menuActions(forTargets paths: [String]) -> [MenuAction?] {
        let resolved = resolvedEntries(for: paths)
        guard !resolved.isEmpty else { return creationActions + [.paste, nil, .refresh] }
        let hasFile = resolved.contains(where: { $0.entry.kind == .file })
        let hasExpandedDirectory = resolved.contains(where: {
            $0.entry.kind == .directory && applied?.expanded.contains($0.path) == true
        })
        let send: [MenuAction?] = actionHandler?.canSendToAgent == true ? [.sendToAgent, nil] : []
        let copy: [MenuAction?] = [.copyPath, .copyRelativePath, nil]
        // Fork-only: markdown preview pane — the plugin verb only when EVERY
        // target is a markdown file (a directory or other file hides it).
        let markdownOnly = resolved.allSatisfy {
            $0.entry.kind == .file && MarkdownFileTypes.isMarkdown($0.path)
        }
        var actions: [MenuAction?] = hasFile
            ? (markdownOnly
                ? [.open, .openInMarkdownEditor, .openInEditor, .revealInFinder, .quickLook, nil]
                : [.open, .openInEditor, .revealInFinder, .quickLook, nil])
            : [.revealInFinder, nil]
        actions += creationActions
        actions += send
        actions += clipboardActions
        actions += copy
        actions += operationActions(forTargetCount: resolved.count)
        actions.append(.refresh)
        if hasExpandedDirectory {
            actions.append(.collapse)
        }
        return actions
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        dropStaleCut()
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
    final class MenuActionPayload: NSObject {
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
        case .open:
            filesOnly(paths).forEach { actionHandler?.openFile(path: $0) }
        case .openInMarkdownEditor:
            filesOnly(paths).filter(MarkdownFileTypes.isMarkdown).forEach { actionHandler?.openMarkdownEditor(path: $0) }
        case .openInEditor:
            filesOnly(paths).forEach { actionHandler?.openInEditor(path: $0) }
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        case .quickLook:
            let files = filesOnly(paths)
            guard !files.isEmpty else { return }
            quickLookOverridePaths = files == selectedFilePaths() ? nil : files
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
        case .newFile, .newFolder:
            if let folder = viewModel.draftFolder(for: paths) {
                viewModel.beginDraft(action == .newFile ? .file : .folder, in: folder)
            }
        case .rename:
            if paths.count == 1 { beginRename(paths[0]) }
        case .trash:
            trash(paths)
        case .cut, .copy:
            copyItems(paths, cutting: action == .cut)
        case .paste:
            paste(into: paths)
        case .duplicate:
            duplicate(paths)
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

    /// Resolves every target path to its `FileEntry`, preserving the order
    /// of `paths` and dropping the ones that no longer exist.
    private func resolvedEntries(for paths: [String]) -> [(path: String, entry: FileEntry)] {
        paths.compactMap { path in applied?.entry(at: path).map { (path, $0) } }
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
                    actionHandler?.openFile(path: path)
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
        case .trash:
            perform(.trash, on: selection)
        case .rename:
            return selection.count == 1 && beginRename(selection[0])
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
