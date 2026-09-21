import XCTest
@testable import UnpeelExplorer

final class FileSystemWatcherTests: XCTestCase {
    func testEventPathsMapToTheirParentDirectories() {
        let change = FileSystemChange.from(eventPaths: ["/r/src/a.swift", "/r/src/b.swift", "/r/docs"])

        XCTAssertEqual(change.directories, ["/r/src", "/r/src/a.swift", "/r/src/b.swift", "/r", "/r/docs"])
        XCTAssertFalse(change.touchedGitignore)
    }

    func testGitignoreEventsAreFlagged() {
        XCTAssertTrue(FileSystemChange.from(eventPaths: ["/r/sub/.gitignore"]).touchedGitignore)
    }

    func testTrailingSlashesAreNormalised() {
        XCTAssertEqual(FileSystemChange.from(eventPaths: ["/r/docs/"]).directories, ["/r", "/r/docs"])
    }

    func testCreatingAFileReportsItsDirectory() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let sub = try tree.dir("sub")
        let reported = expectation(description: "change under sub reported")
        reported.assertForOverFulfill = false
        let watcher = FileSystemWatcher(root: tree.root, latency: 0.05) { change in
            if change.directories.contains(sub) { reported.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            _ = try? tree.file("sub/new.txt", "hello")
        }

        wait(for: [reported], timeout: 10)
    }

    func testStopIsIdempotentAndStopsDelivery() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let unexpected = expectation(description: "no delivery after stop")
        unexpected.isInverted = true
        let watcher = FileSystemWatcher(root: tree.root, latency: 0.05) { _ in unexpected.fulfill() }
        watcher.start()
        watcher.stop()
        watcher.stop()

        try tree.file("late.txt")

        wait(for: [unexpected], timeout: 1)
    }
}
