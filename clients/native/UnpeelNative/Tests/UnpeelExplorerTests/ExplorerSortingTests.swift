import AppKit
import XCTest
@testable import UnpeelExplorer

/// Fork-only: date modified column. Sorting by name or by date modified,
/// from the loader's dates through the model, the store, the view model
/// and the outline's rows.
@MainActor
final class ExplorerSortingTests: ExplorerViewModelTestCase {
    private let day: TimeInterval = 86_400
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ name: String, _ kind: FileKind = .file, daysAgo: Double?) -> FileEntry {
        FileEntry(
            path: "/r/" + name, name: name, kind: kind,
            modifiedAt: daysAgo.map { base.addingTimeInterval(-$0 * day) }
        )
    }

    // MARK: - Loader

    func testEntriesCarryTheirModificationDate() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let file = try tree.file("a.txt")
        let folder = try tree.dir("src")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file)
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(60)], ofItemAtPath: folder)

        let listing = try DirectoryLoader().load(directory: tree.root, root: tree.root)

        XCTAssertEqual(listing.entry(at: file)?.modifiedAt, stamp)
        XCTAssertEqual(listing.entry(at: folder)?.modifiedAt, stamp.addingTimeInterval(60))
    }

    func testIgnoredCopyKeepsTheDate() {
        let dated = entry("a.txt", daysAgo: 1)
        XCTAssertEqual(dated.with(isIgnored: true).modifiedAt, dated.modifiedAt)
    }

    // MARK: - Order

    func testNameOrderKeepsTheLoaderOrder() {
        let entries = [entry("src", .directory, daysAgo: 9), entry("a2.txt", daysAgo: 1), entry("a10.txt", daysAgo: 5)]
        XCTAssertEqual(ExplorerSortOrder.name.sorted(entries), entries)
    }

    func testDateOrderIsNewestFirstWithFoldersOnTop() {
        let entries = [
            entry("old", .directory, daysAgo: 30), entry("new", .directory, daysAgo: 2),
            entry("a.txt", daysAgo: 10), entry("b.txt", daysAgo: 1), entry("c.txt", daysAgo: 5),
        ]

        XCTAssertEqual(
            ExplorerSortOrder.dateModified.sorted(entries).map(\.name),
            ["new", "old", "b.txt", "c.txt", "a.txt"]
        )
    }

    /// A checkout stamps many files with the same time; ties fall back to
    /// the natural name order, and an entry whose date could not be read
    /// goes last.
    func testDateTiesFallBackToNameOrderAndUndatedEntriesGoLast() {
        let entries = [
            entry("undated.txt", daysAgo: nil), entry("a10.txt", daysAgo: 3),
            entry("a2.txt", daysAgo: 3), entry("newest.txt", daysAgo: 0),
        ]

        XCTAssertEqual(
            ExplorerSortOrder.dateModified.sorted(entries).map(\.name),
            ["newest.txt", "a2.txt", "a10.txt", "undated.txt"]
        )
    }

    func testModelAppliesTheSortAfterTheFilter() {
        let model = FileTreeModel(root: "/r").settingContents(
            .loaded(DirectoryListing(entries: [
                entry("a.txt", daysAgo: 4),
                FileEntry(path: "/r/.hidden", name: ".hidden", kind: .file, isHidden: true, modifiedAt: base),
                entry("b.txt", daysAgo: 2),
            ])),
            for: "/r"
        )

        XCTAssertEqual(model.visibleChildren(of: "/r", filter: VisibilityFilter()).map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(
            model.visibleChildren(of: "/r", filter: VisibilityFilter(), sort: .dateModified).map(\.name),
            ["b.txt", "a.txt"]
        )
    }

    // MARK: - Persistence

    func testSortOrderDefaultsToNameAndPersists() {
        let defaults = makeDefaults()
        let store = ExplorerStateStore(defaults: defaults)
        XCTAssertEqual(store.sortOrder, .name)

        store.sortOrder = .dateModified

        XCTAssertEqual(ExplorerStateStore(defaults: defaults).sortOrder, .dateModified)
    }

    func testUnknownStoredSortOrderFallsBackToName() {
        let defaults = makeDefaults()
        defaults.set("size", forKey: "unpeel.explorer.sortOrder")
        XCTAssertEqual(ExplorerStateStore(defaults: defaults).sortOrder, .name)
    }

    func testViewModelPublishesAndPersistsTheSortOrder() {
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults)
        XCTAssertEqual(viewModel.sortOrder, .name)

        viewModel.setSortOrder(.dateModified)

        XCTAssertEqual(viewModel.sortOrder, .dateModified)
        XCTAssertEqual(makeViewModel(defaults: defaults).sortOrder, .dateModified)
    }

    // MARK: - Rows

    private func makeController() -> ExplorerOutlineController {
        let controller = ExplorerOutlineController(viewModel: makeViewModel(), palette: .system)
        controller.pasteboard = NSPasteboard.withUniqueName()
        return controller
    }

    private func datedModel() -> FileTreeModel {
        FileTreeModel(root: "/r").settingContents(
            .loaded(DirectoryListing(entries: [
                entry("src", .directory, daysAgo: 8), entry("a.txt", daysAgo: 6), entry("b.txt", daysAgo: 0.1),
            ], truncatedCount: 3)),
            for: "/r"
        )
    }

    func testSortChangeReordersRowsAndKeepsTheirIdentity() {
        let controller = makeController()
        controller.apply(model: datedModel(), filter: VisibilityFilter(), selection: [])
        let byName = controller.children(of: "/r")
        XCTAssertEqual(byName.map(\.path), ["/r/src", "/r/a.txt", "/r/b.txt", "/r/\u{0}note"])

        controller.apply(model: datedModel(), filter: VisibilityFilter(), selection: [], sortOrder: .dateModified)

        let byDate = controller.children(of: "/r")
        XCTAssertEqual(byDate.map(\.path), ["/r/src", "/r/b.txt", "/r/a.txt", "/r/\u{0}note"])
        XCTAssertTrue(byName[1] === byDate[2], "a row keeps its item across a sort change")
    }

    func testEntryRowsShowTheirDateAndOtherRowsShowNone() {
        let controller = makeController()
        controller.dateText = ExplorerDateText(calendar: utcCalendar, locale: Locale(identifier: "en_US"), timeZone: utcCalendar.timeZone)
        controller.now = { self.base }
        controller.apply(model: datedModel(), filter: VisibilityFilter(), selection: [])
        let cell = ExplorerRowCellView.make()
        let rows = controller.children(of: "/r")

        controller.configure(cell, for: rows[1])
        XCTAssertEqual(cell.dateField?.stringValue, controller.dateText.string(for: base.addingTimeInterval(-6 * day), now: base))
        XCTAssertFalse(cell.dateField?.stringValue.isEmpty ?? true)
        XCTAssertNotNil(cell.dateField?.toolTip)

        controller.configure(cell, for: rows[3])
        XCTAssertEqual(rows[3].role, .note)
        XCTAssertEqual(cell.dateField?.stringValue, "")
        XCTAssertNil(cell.dateField?.toolTip)
    }

    /// "Today" text must not outlive the day: rows on screen are re-read
    /// when the calendar day changes.
    func testCalendarDayChangeRefreshesTheDatesOnScreen() {
        let controller = makeController()
        let outline = ExplorerOutlineView.makeOutlineView()
        controller.attach(to: outline)
        let scroll = ExplorerOutlineView.makeScrollView(documentView: outline)
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        controller.dateText = ExplorerDateText(calendar: utcCalendar, locale: Locale(identifier: "en_US"), timeZone: utcCalendar.timeZone)
        controller.now = { self.base }
        controller.apply(model: datedModel(), filter: VisibilityFilter(), selection: [])
        scroll.layoutSubtreeIfNeeded()
        let row = outline.row(forItem: controller.children(of: "/r")[2])
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ExplorerRowCellView
        let before = cell?.dateField?.stringValue

        controller.now = { self.base.addingTimeInterval(self.day) }
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)

        XCTAssertNotEqual(cell?.dateField?.stringValue, before)
        XCTAssertEqual(cell?.dateField?.stringValue, "Yesterday")
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
