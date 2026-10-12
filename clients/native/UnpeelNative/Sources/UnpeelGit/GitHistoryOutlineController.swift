import AppKit

/// Drives Git History's `NSOutlineView` from the view model: one row per
/// commit, the commit menu (Copy SHA, Copy Subject), ⌘C, and loading the
/// next page as the list nears its end.
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
    /// Start loading the next page once fewer than this many rows remain
    /// below the visible area.
    private static let loadMoreRowThreshold: CGFloat = 8

    let viewModel: GitHistoryViewModel
    var palette: GitHistoryPalette
    var pasteboard: NSPasteboard = .general
    /// The clock relative dates are measured against; injectable for tests.
    var now: () -> Date = Date.init
    private(set) weak var outlineView: GitHistoryNSOutlineView?

    private var commits: [GitCommit] = []
    private var commitsBySHA: [String: GitCommit] = [:]
    private var items: [GitHistoryItem.Role: GitHistoryItem] = [:]
    /// True while this controller changes the outline itself.
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
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.onCopy = { [weak self] in self?.copySelection() ?? false }
    }

    // MARK: - Applying

    func apply(commits next: [GitCommit]) {
        isApplying = true
        defer { isApplying = false }
        let previous = commits
        let selectedSHA = selectedCommitSHA()
        commits = next
        commitsBySHA = Dictionary(next.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
        guard let outlineView else { return }
        if previous.map(\.sha) == next.map(\.sha) {
            reloadVisibleCommitRows()
        } else if next.count > previous.count, Array(next.prefix(previous.count)).map(\.sha) == previous.map(\.sha) {
            // A page appended: insert below, and redraw the old last row,
            // whose lane now continues downwards.
            outlineView.insertItems(at: IndexSet(previous.count..<next.count), inParent: nil, withAnimation: [])
            if !previous.isEmpty { outlineView.reloadItem(item(for: .commit(sha: previous[previous.count - 1].sha))) }
        } else {
            outlineView.reloadData()
            restoreSelection(selectedSHA)
        }
        dropStaleItems()
    }

    private func reloadVisibleCommitRows() {
        guard let outlineView else { return }
        let rows = outlineView.rows(in: outlineView.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            outlineView.reloadItem(outlineView.item(atRow: row))
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

    // MARK: - NSOutlineViewDataSource

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? commits.count : 0
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem _: Any?) -> Any {
        item(for: .commit(sha: commits[index].sha))
    }

    func outlineView(_: NSOutlineView, isItemExpandable _: Any) -> Bool {
        false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? GitHistoryItem, case .commit(let sha) = item.role,
              let commit = commitsBySHA[sha]
        else { return nil }
        let cell = (outlineView.makeView(withIdentifier: Self.commitCellIdentifier, owner: self) as? GitCommitCellView)
            ?? makeCommitCell()
        let index = commits.firstIndex { $0.sha == sha } ?? 0
        cell.configure(
            commit: commit,
            lineAbove: index > 0,
            lineBelow: hasLaneBelow(index),
            palette: palette,
            now: now()
        )
        return cell
    }

    /// The lane continues below a commit unless it is a root commit, or the
    /// last one listed with nothing older left to load.
    private func hasLaneBelow(_ index: Int) -> Bool {
        guard commits.indices.contains(index), !commits[index].parents.isEmpty else { return false }
        return index < commits.count - 1 || viewModel.hasMore
    }

    func outlineView(_: NSOutlineView, heightOfRowByItem _: Any) -> CGFloat {
        GitHistoryRowMetrics.commitRowHeight
    }

    private func makeCommitCell() -> GitCommitCellView {
        let cell = GitCommitCellView(frame: .zero)
        cell.identifier = Self.commitCellIdentifier
        return cell
    }

    // MARK: - Menu and copying

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuItems(menu, forCommit: clickedCommitSHA())
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

    /// ⌘C on a selected commit copies its SHA.
    func copySelection() -> Bool {
        guard let sha = selectedCommitSHA() else { return false }
        perform(.copySHA, on: sha)
        return true
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func clickedCommitSHA() -> String? {
        guard let outlineView, outlineView.clickedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.clickedRow) as? GitHistoryItem)?.sha
    }

    private func selectedCommitSHA() -> String? {
        guard let outlineView, outlineView.selectedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.selectedRow) as? GitHistoryItem)?.sha
    }
}
