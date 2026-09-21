import XCTest
@testable import UnpeelExplorer

final class DirectoryScannerTests: XCTestCase {
    private func git(_ arguments: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testGitIgnoredFilesAndFoldersAreMarked() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try git(["init", "-q"], in: tree.root)
        try tree.file(".gitignore", "build/\n*.log\n")
        try tree.dir("build"); try tree.file("build/out.o")
        try tree.file("debug.log"); try tree.file("keep.txt")

        let listing = try DirectoryScanner(loader: DirectoryLoader(), ignore: GitIgnoreChecker())
            .scan(directory: tree.root, root: tree.root)
        let ignored = Set(listing.entries.filter(\.isIgnored).map(\.name))

        XCTAssertEqual(ignored, ["build", "debug.log"])
    }

    func testNestedDirectoryUsesTheRepositoryRules() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try git(["init", "-q"], in: tree.root)
        try tree.file(".gitignore", "*.tmp\n")
        try tree.file("src/a.tmp"); try tree.file("src/a.swift")

        let listing = try DirectoryScanner(loader: DirectoryLoader(), ignore: GitIgnoreChecker())
            .scan(directory: tree.path("src"), root: tree.root)

        XCTAssertEqual(listing.entries.filter(\.isIgnored).map(\.name), ["a.tmp"])
    }

    func testOutsideARepositoryNothingIsIgnored() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("debug.log")

        let ignored = GitIgnoreChecker().ignoredPaths(among: [tree.path("debug.log")], root: tree.root)

        XCTAssertTrue(ignored.isEmpty)
    }

    func testEmptyInputSkipsGitEntirely() {
        XCTAssertTrue(GitIgnoreChecker().ignoredPaths(among: [], root: "/nonexistent").isEmpty)
    }

    func testManyPathsDoNotDeadlockThePipes() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try git(["init", "-q"], in: tree.root)
        try tree.file(".gitignore", "*.log\n")
        let paths = (0..<4000).map { tree.path("some/deeply/nested/folder/name/file-\($0).log") }

        let ignored = GitIgnoreChecker().ignoredPaths(among: paths, root: tree.root)

        XCTAssertEqual(ignored.count, 4000)
    }

    func testScannerWithNoIgnoreCheckerLeavesEntriesUnmarked() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("debug.log")

        let listing = try DirectoryScanner(loader: DirectoryLoader(), ignore: NoIgnoreChecker())
            .scan(directory: tree.root, root: tree.root)

        XCTAssertEqual(listing.entries.map(\.isIgnored), [false])
    }
}
