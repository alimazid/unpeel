import AppKit
import XCTest
@testable import UnpeelExplorer

/// Guards the cost of the two lookups every row goes through. A 10,000-entry
/// folder is the loader's cap, so these are the sizes the panel must stay
/// usable at — wall time, not `measure {}`, because the failure mode is a
/// main-thread hang of minutes rather than a few percent of drift.
@MainActor
final class ExplorerLargeDirectoryTests: XCTestCase {
    private let root = "/r"
    private static let entryCount = 10_000

    private func hugeListing(directoryCount: Int = 8) -> DirectoryListing {
        let directories = (0..<directoryCount).map {
            FileEntry(path: "/r/d\($0)", name: "d\($0)", kind: .directory)
        }
        let files = (directoryCount..<Self.entryCount).map {
            FileEntry(path: "/r/f\($0).swift", name: "f\($0).swift", kind: .file)
        }
        return DirectoryListing(entries: directories + files)
    }

    private func hugeModel(expandedDirectories: Int = 4, childSuffix: String = "a") -> FileTreeModel {
        var model = FileTreeModel(root: root).settingContents(.loaded(hugeListing()), for: root)
        for index in 0..<expandedDirectories {
            let directory = "/r/d\(index)"
            model = model
                .settingContents(
                    .loaded(DirectoryListing(entries: (0..<5).map {
                        FileEntry(path: "\(directory)/\(childSuffix)\($0).swift", name: "\(childSuffix)\($0).swift", kind: .file)
                    })),
                    for: directory
                )
                .expanding(directory)
        }
        return model
    }

    /// `FileTreeModel.entry(at:)` is called once per row by `viewFor:`, by
    /// `isItemExpandable` and by every menu and key command, so a linear
    /// scan of the parent listing makes each of those O(directory size).
    func testEntryLookupIsFastOnATenThousandEntryListing() {
        let model = FileTreeModel(root: root).settingContents(.loaded(hugeListing()), for: root)
        let paths = (8..<Self.entryCount).map { "/r/f\($0).swift" }

        let started = Date()
        var found = 0
        for path in paths where model.entry(at: path) != nil { found += 1 }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(found, paths.count)
        XCTAssertLessThan(elapsed, 1, "\(paths.count) lookups took \(String(format: "%.2f", elapsed))s")
    }

    /// `apply` runs on every published change, and AppKit asks
    /// `isItemExpandable` for each row it touches while `syncExpansion`
    /// walks the outline — so the whole pass must not scale with rows ×
    /// directory size.
    func testApplyIsFastOnATenThousandRowOutline() {
        let suite = "unpeel.explorer.largedir.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let viewModel = ExplorerViewModel(
            services: ExplorerServices(scan: { _, _ in DirectoryListing(entries: []) }, makeWatcher: { _, _ in nil }),
            stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!)
        )
        let controller = ExplorerOutlineController(viewModel: viewModel, palette: .system)
        let outline = ExplorerOutlineView.makeOutlineView()
        controller.attach(to: outline)
        // In a scroll view, as in the app: only the visible rows get views,
        // so this measures `apply` rather than AppKit building 10,000 cells.
        let scroll = ExplorerOutlineView.makeScrollView(documentView: outline)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        scroll.frame = window.contentView!.bounds
        window.contentView?.addSubview(scroll)
        defer { window.orderOut(nil) }

        let first = Date()
        controller.apply(model: hugeModel(), filter: VisibilityFilter(), selection: [])
        let firstElapsed = Date().timeIntervalSince(first)
        XCTAssertGreaterThan(outline.numberOfRows, Self.entryCount, "the outline never built its rows")
        XCTAssertLessThan(firstElapsed, 1, "first apply took \(String(format: "%.2f", firstElapsed))s")

        // One changed sibling directory: the nested-reload path.
        let second = Date()
        controller.apply(model: hugeModel(childSuffix: "b"), filter: VisibilityFilter(), selection: [])
        let secondElapsed = Date().timeIntervalSince(second)
        XCTAssertLessThan(secondElapsed, 1, "second apply took \(String(format: "%.2f", secondElapsed))s")
    }
}
