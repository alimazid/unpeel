import AppKit
import UnpeelGit
import XCTest
@testable import UnpeelExplorer

/// Fork-only: git support. Git Status Decorations on EXPLORER rows: the
/// trailing letter (a dot on a folder) and the label colour, from
/// `GitChangeKind`'s palette — the one Git History uses too.
@MainActor
final class ExplorerDecorationRenderingTests: XCTestCase {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let outline: ExplorerNSOutlineView
        let controller: ExplorerOutlineController
        let suite: String

        init(width: CGFloat = 260) {
            suite = "unpeel.explorer.decorationrender.\(UUID().uuidString)"
            let viewModel = ExplorerViewModel(
                services: ExplorerServices(scan: { _, _ in DirectoryListing(entries: []) }, makeWatcher: { _, _ in nil }),
                stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!)
            )
            controller = ExplorerOutlineController(viewModel: viewModel, palette: .system)
            outline = ExplorerOutlineView.makeOutlineView()
            controller.attach(to: outline)
            let scroll = ExplorerOutlineView.makeScrollView(documentView: outline)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.appearance = NSAppearance(named: .darkAqua)
            scroll.frame = window.contentView!.bounds
            window.contentView?.addSubview(scroll)
            window.makeKeyAndOrderFront(nil)
        }

        func apply(_ model: FileTreeModel, _ decorations: GitDecorations, selection: [String] = []) {
            controller.apply(
                model: model, filter: VisibilityFilter(showHidden: true, showIgnored: true),
                selection: selection, decorations: decorations
            )
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }

        func cell(_ path: String) -> ExplorerRowCellView? {
            for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? ExplorerItem)?.path == path {
                return outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ExplorerRowCellView
            }
            return nil
        }

        func teardown() {
            window.orderOut(nil)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    private func decorations(_ entries: [GitStatusEntry]) -> GitDecorations {
        GitDecorations(snapshot: GitRepositorySnapshot(
            location: GitRepositoryLocation(workTree: "/r", gitDirectory: "/r/.git", commonDirectory: "/r/.git"),
            status: GitStatus(head: GitHead(oid: "x", branch: "main"), entries: entries)
        ))
    }

    private func model(_ entries: [FileEntry], src: [FileEntry] = []) -> FileTreeModel {
        FileTreeModel(root: "/r")
            .settingContents(.loaded(DirectoryListing(entries: entries)), for: "/r")
            .settingContents(.loaded(DirectoryListing(entries: src)), for: "/r/src")
    }

    private func file(_ name: String, hidden: Bool = false, ignored: Bool = false) -> FileEntry {
        FileEntry(path: "/r/" + name, name: name, kind: .file, isHidden: hidden, isIgnored: ignored)
    }

    func testEachStateShowsItsLetterInItsColour() {
        let harness = Harness(); defer { harness.teardown() }
        let kinds = GitChangeKind.allCases
        let files = kinds.map { file("\($0.rawValue).txt") }

        harness.apply(model(files), decorations(kinds.map { GitStatusEntry(path: "\($0.rawValue).txt", kind: $0) }))

        for kind in kinds {
            let cell = harness.cell("/r/\(kind.rawValue).txt")
            XCTAssertEqual(cell?.decorationField?.stringValue, kind.letter, "\(kind)")
            XCTAssertEqual(cell?.textField?.textColor, kind.color, "\(kind) label")
            XCTAssertEqual(cell?.decorationField?.textColor, kind.color, "\(kind) letter")
        }
    }

    func testAFolderShowsADotInTheStrongestColourBeneathIt() {
        let harness = Harness(); defer { harness.teardown() }
        let folder = FileEntry(path: "/r/src", name: "src", kind: .directory)

        harness.apply(model([folder]), decorations([
            GitStatusEntry(path: "src/new.swift", kind: .untracked),
            GitStatusEntry(path: "src/old.swift", kind: .modified),
        ]))

        let cell = harness.cell("/r/src")
        XCTAssertEqual(cell?.decorationField?.stringValue, "•")
        XCTAssertEqual(cell?.textField?.textColor, GitChangeKind.modified.color)
    }

    func testCleanRowsKeepThePaletteColourAndNoLetter() {
        let harness = Harness(); defer { harness.teardown() }

        harness.apply(model([file("clean.txt"), file("edited.txt")]), decorations([GitStatusEntry(path: "edited.txt", kind: .modified)]))

        let cell = harness.cell("/r/clean.txt")
        XCTAssertEqual(cell?.decorationField?.stringValue, "")
        XCTAssertEqual(cell?.textField?.textColor, ExplorerPalette.system.text)
    }

    /// Ignored rows stay dimmed exactly as before and carry no letter, even
    /// inside an untracked folder; a hidden row is dimmed and decorated.
    func testIgnoredRowsStayDimmedWithoutADecoration() {
        let harness = Harness(); defer { harness.teardown() }
        let ignored = FileEntry(path: "/r/src/debug.log", name: "debug.log", kind: .file, isIgnored: true)
        let folder = FileEntry(path: "/r/src", name: "src", kind: .directory)

        harness.apply(
            model([folder, file(".env", hidden: true)], src: [ignored]).expanding("/r/src"),
            decorations([
                GitStatusEntry(path: "src", kind: .untracked, isDirectory: true),
                GitStatusEntry(path: ".env", kind: .modified),
            ])
        )

        let ignoredCell = harness.cell("/r/src/debug.log")
        XCTAssertEqual(ignoredCell?.alphaValue, 0.5)
        XCTAssertEqual(ignoredCell?.decorationField?.stringValue, "")
        XCTAssertEqual(ignoredCell?.textField?.textColor, ExplorerPalette.system.text)
        let hiddenCell = harness.cell("/r/.env")
        XCTAssertEqual(hiddenCell?.alphaValue, 0.5)
        XCTAssertEqual(hiddenCell?.decorationField?.stringValue, "M")
    }

    /// New decorations for an unchanged tree redraw the rows already on
    /// screen, and cleared ones clear them.
    func testRowsOnScreenFollowNewDecorations() {
        let harness = Harness(); defer { harness.teardown() }
        let tree = model([file("a.txt")])
        harness.apply(tree, .none)
        XCTAssertEqual(harness.cell("/r/a.txt")?.decorationField?.stringValue, "")

        harness.apply(tree, decorations([GitStatusEntry(path: "a.txt", kind: .added)]))
        XCTAssertEqual(harness.cell("/r/a.txt")?.decorationField?.stringValue, "A")
        XCTAssertEqual(harness.cell("/r/a.txt")?.textField?.textColor, GitChangeKind.added.color)

        harness.apply(tree, .none)
        XCTAssertEqual(harness.cell("/r/a.txt")?.decorationField?.stringValue, "")
        XCTAssertEqual(harness.cell("/r/a.txt")?.textField?.textColor, ExplorerPalette.system.text)
    }

    func testAnEmphasizedRowDrawsItsLetterInTheSelectionColour() {
        let harness = Harness(); defer { harness.teardown() }

        harness.apply(
            model([file("a.txt"), file("b.txt")]),
            decorations([GitStatusEntry(path: "a.txt", kind: .modified)]),
            selection: ["/r/a.txt"]
        )

        let cell = harness.cell("/r/a.txt")
        XCTAssertEqual(cell?.backgroundStyle, .emphasized)
        XCTAssertEqual(cell?.textField?.textColor, .alternateSelectedControlTextColor)
        XCTAssertEqual(cell?.decorationField?.textColor, .alternateSelectedControlTextColor)
    }

    /// At the panel's minimum width the letter sits at the trailing edge,
    /// clear of a long, truncated name.
    func testTheLetterSitsAfterTheLabelAtTheMinimumWidth() {
        let harness = Harness(width: 180); defer { harness.teardown() }
        let long = file("a-very-long-file-name-that-will-not-fit-in-the-sidebar.swift")

        harness.apply(model([long]), decorations([GitStatusEntry(path: long.name, kind: .modified)]))

        // Text fields' frames overhang their text by a couple of points;
        // their alignment rects are what is drawn.
        let cell = harness.cell(long.path)
        let label = cell?.textField.map { $0.alignmentRect(forFrame: $0.frame) } ?? .zero
        let letter = cell?.decorationField.map { $0.alignmentRect(forFrame: $0.frame) } ?? .zero
        XCTAssertGreaterThan(letter.width, 0)
        XCTAssertLessThanOrEqual(label.maxX, letter.minX)
        XCTAssertLessThanOrEqual(letter.maxX, cell?.bounds.maxX ?? 0)
        XCTAssertGreaterThan(label.width, 40)
    }
}
