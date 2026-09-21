import AppKit
import SwiftUI
import XCTest
@testable import UnpeelExplorer

/// Windowed reproduction of the row-rendering defects: an offscreen window
/// hosting the REAL `ExplorerOutlineView` configuration, so the geometry
/// measured here is the geometry the panel produces.
@MainActor
final class ExplorerRowRenderingTests: XCTestCase {
    private let root = "/r"

    // MARK: - Harness

    @MainActor
    private final class Harness {
        let window: NSWindow
        let scroll: NSScrollView
        let outline: ExplorerNSOutlineView
        let controller: ExplorerOutlineController
        let suite: String

        /// Sized by Auto Layout against the window's content view, the way
        /// SwiftUI sizes an `NSViewRepresentable`'s view — the column only
        /// ever reaches its correct width through a frame CHANGE, so a
        /// harness that assigns `scroll.frame` up front hides the defect.
        init(width: CGFloat, appearance: NSAppearance.Name) {
            suite = "unpeel.explorer.rendertests.\(UUID().uuidString)"
            let viewModel = ExplorerViewModel(
                services: ExplorerServices(
                    scan: { _, _ in DirectoryListing(entries: []) },
                    makeWatcher: { _, _ in nil }
                ),
                stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!)
            )
            controller = ExplorerOutlineController(viewModel: viewModel, palette: .system)
            outline = ExplorerOutlineView.makeOutlineView()
            controller.attach(to: outline)
            scroll = ExplorerOutlineView.makeScrollView(documentView: outline)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearance)
            let content = window.contentView!
            scroll.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: content.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        func resize(to width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 400))
            layout()
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            outline.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }

        var clipWidth: CGFloat { scroll.contentView.bounds.width }
        var columnWidth: CGFloat { outline.tableColumns[0].width }

        var cells: [(row: Int, path: String, role: ExplorerItem.Role?, cell: NSTableCellView)] {
            (0..<outline.numberOfRows).compactMap { row in
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
                else { return nil }
                let item = outline.item(atRow: row) as? ExplorerItem
                return (row, item?.path ?? "?", item?.role, cell)
            }
        }

        func teardown() {
            window.orderOut(nil)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    private func model(extraRoots: [FileEntry] = [], srcChildren: Int = 1) -> FileTreeModel {
        FileTreeModel(root: root)
            .settingContents(
                .loaded(DirectoryListing(entries: [
                    FileEntry(path: "/r/src", name: "src", kind: .directory),
                    FileEntry(path: "/r/README.md", name: "README.md", kind: .file),
                ] + extraRoots)),
                for: root
            )
            .settingContents(
                .loaded(DirectoryListing(entries: (0..<srcChildren).map {
                    FileEntry(path: "/r/src/f\($0).swift", name: "f\($0).swift", kind: .file)
                })),
                for: "/r/src"
            )
            .expanding("/r/src")
    }

    // MARK: - Assertions

    /// The single column must fill the scroll view's visible width (bar the
    /// table's own trailing inset) at every moment — that width is what
    /// `frameOfCell` hands each cell, and a starved cell cannot satisfy the
    /// row's Auto Layout.
    private func assertColumnFillsClip(_ harness: Harness, _ stage: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(
            harness.columnWidth, harness.clipWidth - 20,
            "\(stage): column \(harness.columnWidth) does not fill clip \(harness.clipWidth)",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(harness.columnWidth, harness.clipWidth, "\(stage): column overflows clip", file: file, line: line)
    }

    /// Every visible row must show a full-size icon with its label to the
    /// right of it, at a width that can actually render text.
    private func assertRowsRenderable(_ harness: Harness, _ stage: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(harness.cells.count, 0, "\(stage): no rows", file: file, line: line)
        for (row, path, role, cell) in harness.cells {
            let image = cell.imageView?.frame ?? .zero
            let label = cell.textField?.frame ?? .zero
            let where_ = "\(stage) row \(row) \(path)"
            // Entry rows always carry an icon (`FileIconProvider` never
            // returns nil), so the geometry below must not be skippable —
            // a missing icon is itself the regression.
            if role == .entry {
                XCTAssertNotNil(cell.imageView?.image, "\(where_): entry row has no icon", file: file, line: line)
            }
            if cell.imageView?.image != nil {
                XCTAssertEqual(image.width, 16, accuracy: 0.5, "\(where_): icon width \(image.width)", file: file, line: line)
                XCTAssertEqual(image.height, 16, accuracy: 0.5, "\(where_): icon height \(image.height)", file: file, line: line)
                XCTAssertGreaterThanOrEqual(
                    label.minX, image.maxX,
                    "\(where_): label at \(label.minX) overlaps icon ending at \(image.maxX)",
                    file: file, line: line
                )
            }
            XCTAssertGreaterThan(label.width, 40, "\(where_): label width \(label.width)", file: file, line: line)
            XCTAssertGreaterThan(label.height, 0, "\(where_): label height \(label.height)", file: file, line: line)
        }
    }

    private func check(_ harness: Harness, _ stage: String) {
        assertColumnFillsClip(harness, stage)
        assertRowsRenderable(harness, stage)
    }

    // MARK: - Geometry regressions

    /// The panel's whole lifecycle: mount at its real width, then each of
    /// the three reload paths `apply` uses, then a live width drag, then a
    /// hide/show (width collapses to zero and comes back).
    func testRowGeometrySurvivesEveryReloadPath() {
        let harness = Harness(width: 260, appearance: .darkAqua)
        defer { harness.teardown() }

        harness.controller.apply(model: model(), filter: VisibilityFilter(), selection: [])
        harness.layout()
        check(harness, "first load")

        // Root reload: `reloadItem(nil, reloadChildren: true)`.
        harness.controller.apply(
            model: model(extraRoots: [FileEntry(path: "/r/new.txt", name: "new.txt", kind: .file)]),
            filter: VisibilityFilter(),
            selection: []
        )
        harness.layout()
        check(harness, "root reload")

        // Nested reload: `reloadItem(item, reloadChildren: true)`.
        harness.controller.apply(
            model: model(extraRoots: [FileEntry(path: "/r/new.txt", name: "new.txt", kind: .file)], srcChildren: 3),
            filter: VisibilityFilter(),
            selection: []
        )
        harness.layout()
        check(harness, "nested reload")

        // Filter change: `reloadData()`.
        harness.controller.apply(
            model: model(extraRoots: [FileEntry(path: "/r/new.txt", name: "new.txt", kind: .file)], srcChildren: 3),
            filter: VisibilityFilter(showHidden: true),
            selection: []
        )
        harness.layout()
        check(harness, "filter change")

        harness.resize(to: 180)
        check(harness, "narrowed to the minimum width")

        harness.resize(to: 520)
        check(harness, "widened to the maximum width")

        // Panel hidden, then shown again.
        harness.resize(to: 0)
        harness.resize(to: 260)
        check(harness, "after hide and show")
    }

    /// The panel mounts at zero width (it is hidden on first run and
    /// animates open), which is where the column's degenerate width comes
    /// from: it must recover as soon as the panel has a real width, and
    /// must not fall back to it on the next reload.
    func testRowGeometryRecoversFromAZeroWidthMount() {
        let harness = Harness(width: 0, appearance: .darkAqua)
        defer { harness.teardown() }

        harness.controller.apply(model: model(), filter: VisibilityFilter(), selection: [])
        harness.layout()

        harness.resize(to: 260)
        check(harness, "grown from a zero-width mount")

        harness.controller.apply(
            model: model(extraRoots: [FileEntry(path: "/r/new.txt", name: "new.txt", kind: .file)]),
            filter: VisibilityFilter(),
            selection: []
        )
        harness.layout()
        check(harness, "root reload after a zero-width mount")
    }

    /// The end-to-end path, through SwiftUI and a real scanned tree: this is
    /// the configuration that produced the reported screenshots (labels
    /// 4 pt wide at x = -3, behind the icon; root icons 3 pt after a reload).
    func testRowGeometryThroughSwiftUIHosting() async throws {
        let tree = try TempTree()
        defer { tree.remove() }
        try tree.dir("src")
        try tree.file("src/main.swift")
        try tree.file("src/other.swift")
        try tree.file("README.md")

        let suite = "unpeel.explorer.rendertests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let viewModel = ExplorerViewModel(stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(
            rootView: ExplorerPanelView(viewModel: viewModel, palette: .system, actionHandler: nil)
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await pump()

        await viewModel.setContext(.local(root: tree.root, projectRoot: tree.root)).value
        await pump()
        assertHostedRowsRenderable(hosting, "hosted first load")

        await viewModel.expand(tree.path("src")).value
        await pump()
        assertHostedRowsRenderable(hosting, "hosted after expand")

        try tree.file("new.txt")
        await viewModel.refresh().value
        await pump()
        assertHostedRowsRenderable(hosting, "hosted after root reload")

        viewModel.setFilter(VisibilityFilter(showHidden: true))
        await pump()
        assertHostedRowsRenderable(hosting, "hosted after filter change")
    }

    private func assertHostedRowsRenderable(_ host: NSView, _ stage: String, file: StaticString = #filePath, line: UInt = #line) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let outline = firstOutline(in: host), let clip = outline.enclosingScrollView?.contentView else {
            return XCTFail("\(stage): no outline view", file: file, line: line)
        }
        XCTAssertGreaterThan(outline.numberOfRows, 0, "\(stage): no rows", file: file, line: line)
        XCTAssertGreaterThan(
            outline.tableColumns[0].width, clip.bounds.width - 20,
            "\(stage): column \(outline.tableColumns[0].width) does not fill clip \(clip.bounds.width)",
            file: file, line: line
        )
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
            else { continue }
            let image = cell.imageView?.frame ?? .zero
            let label = cell.textField?.frame ?? .zero
            let where_ = "\(stage) row \(row) '\(cell.textField?.stringValue ?? "")'"
            if (outline.item(atRow: row) as? ExplorerItem)?.role == .entry {
                XCTAssertNotNil(cell.imageView?.image, "\(where_): entry row has no icon", file: file, line: line)
            }
            if cell.imageView?.image != nil {
                XCTAssertEqual(image.width, 16, accuracy: 0.5, "\(where_): icon width \(image.width)", file: file, line: line)
                XCTAssertGreaterThanOrEqual(label.minX, image.maxX, "\(where_): label left of icon", file: file, line: line)
            }
            XCTAssertGreaterThan(label.width, 40, "\(where_): label width \(label.width)", file: file, line: line)
        }
    }

    private func firstOutline(in view: NSView) -> ExplorerNSOutlineView? {
        if let outline = view as? ExplorerNSOutlineView { return outline }
        for subview in view.subviews {
            if let found = firstOutline(in: subview) { return found }
        }
        return nil
    }

    private func pump() async {
        for _ in 0..<8 {
            spinRunLoop()
            await Task.yield()
        }
    }

    private nonisolated func spinRunLoop() {
        CFRunLoopRunInMode(.defaultMode, 0.02, false)
    }
}
