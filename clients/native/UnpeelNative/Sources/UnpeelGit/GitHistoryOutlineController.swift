import AppKit

/// What Git History cannot do on its own; implemented by the app.
@MainActor
public protocol GitHistoryActionHandler: AnyObject {
    /// Reveal `path` in the EXPLORER and open it with the open-with rules.
    /// Only called for a file that exists in the working tree.
    func openChangedFile(path: String)
}

/// Drives Git History's `NSOutlineView` from the view model: one row per
/// commit; under the one expanded commit, its message and changed files.
/// Also the commit menu (Copy SHA, Copy Subject), ⌘C, Return, clicks, and
/// loading the next page as the list nears its end.
@MainActor
final class GitHistoryOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    enum MenuAction: Equatable {
        case copySHA, copySubject

        var title: String {
            switch self {
            case .copySHA: return "Copy SHA"
            case .copySubject: return "Copy Subject"
            }
        }
    }

    private static let commitCellIdentifier = NSUserInterfaceItemIdentifier("unpeel.git.commit")
    private static let messageCellIdentifier = NSUserInterfaceItemIdentifier("unpeel.git.message")
    private static let fileCellIdentifier = NSUserInterfaceItemIdentifier("unpeel.git.file")
    /// Start loading the next page once fewer than this many rows remain
    /// below the visible area.
    private static let loadMoreRowThreshold: CGFloat = 8

    let viewModel: GitHistoryViewModel
    var palette: GitHistoryPalette
    weak var actionHandler: (any GitHistoryActionHandler)?
    var pasteboard: NSPasteboard = .general
    /// The clock relative dates are measured against; injectable for tests.
    var now: () -> Date = Date.init
    private(set) weak var outlineView: GitHistoryNSOutlineView?

    private var commits: [GitCommit] = []
    private var commitsBySHA: [String: GitCommit] = [:]
    private var commitIndex: [String: Int] = [:]
    private var expanded: GitExpandedCommit?
    private var items: [GitHistoryItem.Role: GitHistoryItem] = [:]
    /// True while this controller changes the outline itself, so its
    /// delegate callbacks are not echoed back into the view model.
    private var isApplying = false

    init(viewModel: GitHistoryViewModel, palette: GitHistoryPalette) {
        self.viewModel = viewModel
        self.palette = palette
        super.init()
    }

    func attach(to outlineView: GitHistoryNSOutlineView) {
        self.outlineView = outlineView
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleClick)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.onCopy = { [weak self] in self?.copySelection() ?? false }
        outlineView.onToggle = { [weak self] in self?.activateSelection() ?? false }
        outlineView.onColumnResize = { [weak self] in self?.noteMessageHeightChanged() }
    }

    // MARK: - Applying

    func apply(commits next: [GitCommit], expanded nextExpanded: GitExpandedCommit? = nil) {
        isApplying = true
        defer { isApplying = false }
        let previous = commits
        let previousExpanded = expanded
        let selectedSHA = selectedSHA()
        commits = next
        commitsBySHA = Dictionary(next.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
        commitIndex = Dictionary(next.enumerated().map { ($0.element.sha, $0.offset) }, uniquingKeysWith: { first, _ in first })
        expanded = nextExpanded
        guard let outlineView else { return }
        if previous.map(\.sha) == next.map(\.sha) {
            reloadVisibleCommitRows()
        } else if next.count > previous.count, Array(next.prefix(previous.count)).map(\.sha) == previous.map(\.sha) {
            // A page appended: insert below, and redraw the old last row,
            // whose lane now continues downwards.
            outlineView.insertItems(at: IndexSet(previous.count..<next.count), inParent: nil, withAnimation: [])
            if let last = previous.last { outlineView.reloadItem(item(for: .commit(sha: last.sha))) }
        } else {
            outlineView.reloadData()
            restoreSelection(selectedSHA)
        }
        syncExpansion(from: previousExpanded)
        dropStaleItems()
    }

    /// Makes the outline's expansion match the view model's one expanded
    /// commit, reloading its rows when its detail changed.
    private func syncExpansion(from previous: GitExpandedCommit?) {
        guard let outlineView else { return }
        if let previous, previous.sha != expanded?.sha, let old = items[.commit(sha: previous.sha)],
           outlineView.isItemExpanded(old) {
            outlineView.collapseItem(old)
        }
        guard let expanded, commitsBySHA[expanded.sha] != nil else { return }
        let item = item(for: .commit(sha: expanded.sha))
        guard outlineView.row(forItem: item) >= 0 else { return }
        if previous != expanded {
            outlineView.reloadItem(item, reloadChildren: true)
        }
        if !outlineView.isItemExpanded(item) {
            outlineView.expandItem(item)
        }
    }

    private func reloadVisibleCommitRows() {
        guard let outlineView else { return }
        let rows = outlineView.rows(in: outlineView.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard let item = outlineView.item(atRow: row) as? GitHistoryItem, case .commit = item.role else { continue }
            outlineView.reloadItem(item)
        }
    }

    private func restoreSelection(_ sha: String?) {
        guard let outlineView else { return }
        guard let sha, commitsBySHA[sha] != nil else {
            outlineView.deselectAll(nil)
            return
        }
        let row = outlineView.row(forItem: item(for: .commit(sha: sha)))
        if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    private func dropStaleItems() {
        items = items.filter { commitsBySHA[$0.value.sha] != nil }
    }

    private func item(for role: GitHistoryItem.Role) -> GitHistoryItem {
        if let existing = items[role] { return existing }
        let created = GitHistoryItem(role)
        items[role] = created
        return created
    }

    /// The expanded commit's rows: its message (or a loading / failure
    /// line), then one row per changed file.
    private func detailRows(of sha: String) -> [GitHistoryItem] {
        guard let expanded, expanded.sha == sha else { return [] }
        let message = item(for: .message(sha: sha))
        guard case .loaded(let detail) = expanded.state else { return [message] }
        return [message] + detail.files.indices.map { item(for: .file(sha: sha, index: $0)) }
    }

    private func loadedDetail(_ sha: String) -> GitCommitDetail? {
        guard let expanded, expanded.sha == sha, case .loaded(let detail) = expanded.state else { return nil }
        return detail
    }

    private func messageText(_ sha: String) -> String {
        guard let expanded, expanded.sha == sha else { return "" }
        switch expanded.state {
        case .loading: return "Loading…"
        case .loaded(let detail): return detail.message
        case .failed(let message): return message
        }
    }

    // MARK: - Scrolling

    /// Called as the list scrolls; loads the next page when the visible
    /// area nears the end. Returns the load, if one started.
    @discardableResult
    func noteScrolled(visibleMaxY: CGFloat) -> Task<Void, Never>? {
        guard viewModel.hasMore, let outlineView, outlineView.numberOfRows > 0 else { return nil }
        let contentHeight = outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY
        let threshold = Self.loadMoreRowThreshold * GitHistoryRowMetrics.commitRowHeight
        guard visibleMaxY >= contentHeight - threshold else { return nil }
        return viewModel.loadMore()
    }

    private func noteMessageHeightChanged() {
        guard let outlineView, let sha = expanded?.sha, let message = items[.message(sha: sha)] else { return }
        let row = outlineView.row(forItem: message)
        guard row >= 0 else { return }
        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? GitHistoryItem else { return commits.count }
        guard case .commit(let sha) = item.role else { return 0 }
        return detailRows(of: sha).count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? GitHistoryItem, case .commit(let sha) = item.role else {
            return self.item(for: .commit(sha: commits[index].sha))
        }
        return detailRows(of: sha)[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? GitHistoryItem, case .commit = item.role else { return false }
        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? GitHistoryItem, let index = commitIndex[item.sha] else { return nil }
        let lane = hasLaneBelow(index)
        switch item.role {
        case .commit(let sha):
            guard let commit = commitsBySHA[sha] else { return nil }
            let cell: GitCommitCellView = reuse(outlineView, Self.commitCellIdentifier) { GitCommitCellView(frame: .zero) }
            cell.configure(commit: commit, lineAbove: index > 0, lineBelow: lane, palette: palette, now: now())
            return cell
        case .message(let sha):
            let cell: GitMessageCellView = reuse(outlineView, Self.messageCellIdentifier) { GitMessageCellView(frame: .zero) }
            cell.configure(message: messageText(sha), lane: lane, palette: palette)
            return cell
        case .file(let sha, let fileIndex):
            guard let detail = loadedDetail(sha), detail.files.indices.contains(fileIndex) else { return nil }
            let cell: GitChangedFileCellView = reuse(outlineView, Self.fileCellIdentifier) { GitChangedFileCellView(frame: .zero) }
            cell.configure(file: detail.files[fileIndex], lane: lane, palette: palette)
            return cell
        }
    }

    private func reuse<Cell: NSTableCellView>(
        _ outlineView: NSOutlineView,
        _ identifier: NSUserInterfaceItemIdentifier,
        make: () -> Cell
    ) -> Cell {
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? Cell { return cell }
        let cell = make()
        cell.identifier = identifier
        return cell
    }

    /// The lane continues below a commit unless it is a root commit, or the
    /// last one listed with nothing older left to load.
    private func hasLaneBelow(_ index: Int) -> Bool {
        guard commits.indices.contains(index), !commits[index].parents.isEmpty else { return false }
        return index < commits.count - 1 || viewModel.hasMore
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? GitHistoryItem else { return GitHistoryRowMetrics.commitRowHeight }
        switch item.role {
        case .commit: return GitHistoryRowMetrics.commitRowHeight
        case .file: return GitHistoryRowMetrics.fileRowHeight
        case .message(let sha):
            let width = outlineView.tableColumns.last?.width ?? outlineView.bounds.width
            return GitMessageCellView.height(for: messageText(sha), width: width, palette: palette)
        }
    }

    func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? GitHistoryItem, case .message = item.role else { return true }
        return false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplying, let item = notification.userInfo?["NSObject"] as? GitHistoryItem,
              case .commit(let sha) = item.role, viewModel.expanded?.sha != sha
        else { return }
        viewModel.expand(sha)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplying, let item = notification.userInfo?["NSObject"] as? GitHistoryItem,
              case .commit(let sha) = item.role, viewModel.expanded?.sha == sha
        else { return }
        viewModel.collapse()
    }

    // MARK: - Clicks and keys

    @objc private func handleClick() {
        guard let outlineView, outlineView.clickedRow >= 0 else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        guard modifiers.intersection([.command, .shift]).isEmpty else { return }
        activate(row: outlineView.clickedRow)
    }

    /// A click (or Return) on a row: a commit expands or collapses; a
    /// changed file that still exists is revealed and opened; anything
    /// else does nothing. Internal so tests can drive it — `clickedRow` is
    /// read-only and needs a real click.
    @discardableResult
    func activate(row: Int) -> Task<Void, Never>? {
        guard let outlineView, let item = outlineView.item(atRow: row) as? GitHistoryItem else { return nil }
        switch item.role {
        case .commit(let sha):
            return viewModel.toggleExpanded(sha)
        case .file(let sha, let index):
            guard let detail = loadedDetail(sha), detail.files.indices.contains(index),
                  let path = viewModel.workTreePath(for: detail.files[index])
            else { return nil }
            actionHandler?.openChangedFile(path: path)
            return nil
        case .message:
            return nil
        }
    }

    private func activateSelection() -> Bool {
        guard let outlineView, outlineView.selectedRow >= 0 else { return false }
        activate(row: outlineView.selectedRow)
        return true
    }

    // MARK: - Menu and copying

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(menu, forRow: outlineView?.clickedRow ?? -1)
    }

    /// Every row of a commit (its detail rows too) offers the commit's menu.
    func rebuildMenuItems(_ menu: NSMenu, forRow row: Int) {
        let sha = row >= 0 ? (outlineView?.item(atRow: row) as? GitHistoryItem)?.sha : nil
        rebuildMenuItems(menu, forCommit: sha)
    }

    /// Captures the target commit once, so the action acts on the commit
    /// the menu was opened for even if the click state changes meanwhile.
    func rebuildMenuItems(_ menu: NSMenu, forCommit sha: String?) {
        menu.removeAllItems()
        guard let sha, commitsBySHA[sha] != nil else { return }
        for action in [MenuAction.copySHA, .copySubject] {
            let item = NSMenuItem(title: action.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuPayload(action: action, sha: sha)
            menu.addItem(item)
        }
    }

    private final class MenuPayload: NSObject {
        let action: MenuAction
        let sha: String

        init(action: MenuAction, sha: String) {
            self.action = action
            self.sha = sha
        }
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? MenuPayload else { return }
        perform(payload.action, on: payload.sha)
    }

    func perform(_ action: MenuAction, on sha: String) {
        guard let commit = commitsBySHA[sha] else { return }
        switch action {
        case .copySHA: copy(commit.sha)
        case .copySubject: copy(commit.subject)
        }
    }

    /// ⌘C on a selected row copies its commit's SHA.
    func copySelection() -> Bool {
        guard let sha = selectedSHA() else { return false }
        perform(.copySHA, on: sha)
        return true
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func selectedSHA() -> String? {
        guard let outlineView, outlineView.selectedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.selectedRow) as? GitHistoryItem)?.sha
    }
}
