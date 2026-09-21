import XCTest
@testable import UnpeelExplorer

final class DirectoryLoaderTests: XCTestCase {
    func testFoldersFirstThenNaturalNameOrder() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("b.txt"); try tree.file("a10.txt"); try tree.file("a2.txt")
        try tree.dir("zeta"); try tree.dir("Alpha")

        let listing = try DirectoryLoader().load(directory: tree.root, root: tree.root)

        XCTAssertEqual(listing.entries.map(\.name), ["Alpha", "zeta", "a2.txt", "a10.txt", "b.txt"])
        XCTAssertEqual(listing.entries.map(\.kind), [.directory, .directory, .file, .file, .file])
        XCTAssertEqual(listing.truncatedCount, 0)
        XCTAssertEqual(listing.entries[2].path, tree.path("a2.txt"))
    }

    func testDotfilesAreMarkedHiddenAndNothingIsIgnoredByTheLoader() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file(".env"); try tree.file("shown.txt")

        let byName = Dictionary(
            uniqueKeysWithValues: try DirectoryLoader()
                .load(directory: tree.root, root: tree.root).entries.map { ($0.name, $0) }
        )

        XCTAssertEqual(byName[".env"]?.isHidden, true)
        XCTAssertEqual(byName["shown.txt"]?.isHidden, false)
        XCTAssertEqual(byName[".env"]?.isIgnored, false)
    }

    func testSymlinkedDirectoryInsideRootIsExpandable() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("real")
        try tree.symlink("link", to: tree.path("real"))

        let link = try XCTUnwrap(
            DirectoryLoader().load(directory: tree.root, root: tree.root)
                .entries.first { $0.name == "link" }
        )

        XCTAssertTrue(link.isSymlink)
        XCTAssertEqual(link.kind, .directory)
        XCTAssertTrue(link.isExpandable)
    }

    func testSymlinkedDirectoryOutsideRootIsNotExpandable() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let outside = try TempTree(); defer { outside.remove() }
        try tree.symlink("escape", to: outside.root)

        let link = try XCTUnwrap(
            DirectoryLoader().load(directory: tree.root, root: tree.root)
                .entries.first { $0.name == "escape" }
        )

        XCTAssertEqual(link.kind, .directory)
        XCTAssertFalse(link.isExpandable)
    }

    func testBrokenSymlinkIsAFile() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.symlink("dangling", to: tree.path("missing"))

        let link = try XCTUnwrap(
            DirectoryLoader().load(directory: tree.root, root: tree.root).entries.first
        )

        XCTAssertEqual(link.kind, .file)
        XCTAssertFalse(link.isExpandable)
    }

    func testLoadingADirectoryOutsideTheRootThrows() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let outside = try TempTree(); defer { outside.remove() }

        XCTAssertThrowsError(try DirectoryLoader().load(directory: outside.root, root: tree.root)) { error in
            XCTAssertEqual(error as? ExplorerError, .outsideRoot(outside.root))
        }
    }

    func testUnreadableDirectoryThrows() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let locked = try tree.dir("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        XCTAssertThrowsError(try DirectoryLoader().load(directory: locked, root: tree.root))
    }

    func testListingIsCappedAndReportsTheRemainder() throws {
        let tree = try TempTree(); defer { tree.remove() }
        for index in 0..<5 { try tree.file("f\(index).txt") }

        let listing = try DirectoryLoader(maxEntries: 3).load(directory: tree.root, root: tree.root)

        XCTAssertEqual(listing.entries.map(\.name), ["f0.txt", "f1.txt", "f2.txt"])
        XCTAssertEqual(listing.truncatedCount, 2)
    }

    func testCanonicalPathIsInsideRejectsSiblingPrefix() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let inner = try tree.dir("proj")
        let sibling = try tree.dir("proj-other")

        XCTAssertTrue(CanonicalPath.isInside(inner, root: inner))
        XCTAssertFalse(CanonicalPath.isInside(sibling, root: inner))
    }
}
