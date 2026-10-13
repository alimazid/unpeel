import XCTest
@testable import UnpeelExplorer

final class FileTreeModelTests: XCTestCase {
    private let root = "/r"

    private func dir(_ path: String) -> FileEntry {
        FileEntry(path: path, name: (path as NSString).lastPathComponent, kind: .directory)
    }

    private func file(_ path: String, hidden: Bool = false, ignored: Bool = false) -> FileEntry {
        FileEntry(
            path: path, name: (path as NSString).lastPathComponent, kind: .file,
            isHidden: hidden, isIgnored: ignored
        )
    }

    private func loaded(_ entries: [FileEntry], truncated: Int = 0) -> DirectoryContents {
        .loaded(DirectoryListing(entries: entries, truncatedCount: truncated))
    }

    func testReducersReturnNewValuesAndLeaveTheInputUntouched() {
        let original = FileTreeModel(root: root)
        let snapshot = original

        let changed = original
            .settingContents(loaded([dir("/r/src")]), for: root)
            .expanding("/r/src")

        XCTAssertEqual(original, snapshot)
        XCTAssertTrue(original.directories.isEmpty)
        XCTAssertEqual(changed.expanded, ["/r/src"])
        XCTAssertEqual(changed.loadedDirectories, [root])
    }

    func testCollapsingKeepsDescendantExpansionForReExpand() {
        let model = FileTreeModel(root: root)
            .expanding("/r/src").expanding("/r/src/views")
            .collapsing("/r/src")

        XCTAssertEqual(model.expanded, ["/r/src/views"])
    }

    /// Only folders whose rows are on screen count: the root, and expanded
    /// folders whose every ancestor is expanded too. A folder that keeps its
    /// expansion under a collapsed parent is not shown.
    func testShownDirectoriesAreTheRootAndExpandedFoldersUnderExpandedParents() {
        let model = FileTreeModel(root: root)
            .expanding("/r/a").expanding("/r/a/b")
            .expanding("/r/c").expanding("/r/c/d")
            .collapsing("/r/c")

        XCTAssertTrue(model.isShown(root))
        XCTAssertTrue(model.isShown("/r/a"))
        XCTAssertTrue(model.isShown("/r/a/b"))
        XCTAssertFalse(model.isShown("/r/c/d"))
        XCTAssertFalse(model.isShown("/r/c"))
    }

    func testCollapsingAllClearsExpansion() {
        let model = FileTreeModel(root: root).expanding("/r/a").expanding("/r/b").collapsingAll()
        XCTAssertTrue(model.expanded.isEmpty)
    }

    func testReloadingAParentDropsSubtreesOfVanishedFolders() {
        let model = FileTreeModel(root: root)
            .settingContents(loaded([dir("/r/gone"), dir("/r/kept")]), for: root)
            .settingContents(loaded([dir("/r/gone/deep")]), for: "/r/gone")
            .settingContents(loaded([]), for: "/r/gone/deep")
            .settingContents(loaded([]), for: "/r/kept")
            .expanding("/r/gone").expanding("/r/gone/deep").expanding("/r/kept")

        let reloaded = model.settingContents(loaded([dir("/r/kept")]), for: root)

        XCTAssertEqual(reloaded.loadedDirectories, [root, "/r/kept"])
        XCTAssertEqual(reloaded.expanded, ["/r/kept"])
    }

    func testRemovingADirectoryDropsItAndItsDescendants() {
        let model = FileTreeModel(root: root)
            .settingContents(loaded([dir("/r/a")]), for: root)
            .settingContents(loaded([dir("/r/a/b")]), for: "/r/a")
            .settingContents(loaded([]), for: "/r/a/b")
            .expanding("/r/a").expanding("/r/a/b")
            .removingDirectory("/r/a")

        XCTAssertEqual(model.loadedDirectories, [root])
        XCTAssertTrue(model.expanded.isEmpty)
    }

    func testSiblingWithSharedPrefixSurvivesRemoval() {
        let model = FileTreeModel(root: root)
            .settingContents(loaded([]), for: "/r/app")
            .settingContents(loaded([]), for: "/r/app-old")
            .removingDirectory("/r/app")

        XCTAssertEqual(model.loadedDirectories, ["/r/app-old"])
    }

    func testVisibleChildrenHonourTheFilterAndAlwaysHideDotGit() {
        let model = FileTreeModel(root: root).settingContents(
            loaded([
                dir("/r/.git"),
                file("/r/.env", hidden: true),
                file("/r/out.log", ignored: true),
                file("/r/main.swift"),
            ]),
            for: root
        )

        let names: (VisibilityFilter) -> [String] = { model.visibleChildren(of: self.root, filter: $0).map(\.name) }

        XCTAssertEqual(names(VisibilityFilter(showHidden: false, showIgnored: false)), ["main.swift"])
        XCTAssertEqual(names(VisibilityFilter(showHidden: true, showIgnored: false)), [".env", "main.swift"])
        XCTAssertEqual(names(VisibilityFilter(showHidden: false, showIgnored: true)), ["out.log", "main.swift"])
        XCTAssertEqual(names(VisibilityFilter(showHidden: true, showIgnored: true)), [".env", "out.log", "main.swift"])
    }

    func testChildrenOfUnloadedLoadingOrFailedDirectoriesAreEmpty() {
        let model = FileTreeModel(root: root)
            .settingContents(.loading, for: "/r/a")
            .settingContents(.failed("denied"), for: "/r/b")
        let all = VisibilityFilter(showHidden: true, showIgnored: true)

        XCTAssertTrue(model.visibleChildren(of: "/r/a", filter: all).isEmpty)
        XCTAssertTrue(model.visibleChildren(of: "/r/b", filter: all).isEmpty)
        XCTAssertTrue(model.visibleChildren(of: "/r/never", filter: all).isEmpty)
        XCTAssertTrue(model.loadedDirectories.isEmpty)
    }

    func testEntryLookupAndTruncationCount() {
        let model = FileTreeModel(root: root)
            .settingContents(loaded([file("/r/a.txt")], truncated: 7), for: root)

        XCTAssertEqual(model.entry(at: "/r/a.txt")?.name, "a.txt")
        XCTAssertNil(model.entry(at: "/r/missing.txt"))
        XCTAssertEqual(model.truncatedCount(of: root), 7)
        XCTAssertEqual(FileTreeModel.parent(of: "/r/src/a.txt"), "/r/src")
    }
}

/// Fork-only: explorer operations. A renamed or moved folder keeps its
/// expansion under the new path; its old listings are dropped (their
/// entries name the old paths) so they are rescanned.
final class FileTreeModelRelocationTests: XCTestCase {
    func testRelocatingRewritesTheExpandedSubtreeAndDropsOldListings() {
        let listing = DirectoryListing(entries: [FileEntry(path: "/r/src/a", name: "a", kind: .file)])
        let model = FileTreeModel(
            root: "/r",
            directories: ["/r": .loading, "/r/src": .loaded(listing), "/r/src/sub": .loading, "/r/srcx": .loading],
            expanded: ["/r/src", "/r/src/sub", "/r/srcx"]
        )

        let moved = model.relocating(from: "/r/src", to: "/r/lib")

        XCTAssertEqual(moved.expanded, ["/r/lib", "/r/lib/sub", "/r/srcx"])
        XCTAssertEqual(Set(moved.directories.keys), ["/r", "/r/srcx"])
        XCTAssertEqual(model.expanded, ["/r/src", "/r/src/sub", "/r/srcx"], "the input is unchanged")
    }
}
