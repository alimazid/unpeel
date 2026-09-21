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

    /// `stop()` called from inside the handler must not deadlock: the handler
    /// runs on the watcher's private queue, so `stop()` cannot block waiting
    /// for that same queue to go idle.
    func testStopFromInsideTheHandlerDoesNotDeadlock() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let stopped = expectation(description: "stop from inside handler completes")

        final class WatcherBox: @unchecked Sendable { var watcher: FileSystemWatcher? }
        let box = WatcherBox()
        box.watcher = FileSystemWatcher(root: tree.root, latency: 0.05) { _ in
            box.watcher?.stop()
            stopped.fulfill()
        }
        box.watcher?.start()
        defer { box.watcher?.stop() }

        try tree.file("trigger.txt")

        wait(for: [stopped], timeout: 10)
    }

    /// Dropping the only reference to a watcher without calling `stop()`
    /// while events are actively flowing must not race or use-after-free:
    /// the FSEvents callback only ever touches a heap box the stream itself
    /// owns, never the watcher, and `deinit` tears the stream down
    /// synchronously before returning.
    func testReleasingWithoutStopWhileEventsFlowIsSafe() throws {
        let tree = try TempTree(); defer { tree.remove() }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var current: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let counter = Counter()

        var watcher: FileSystemWatcher? = FileSystemWatcher(root: tree.root, latency: 0.01) { _ in
            counter.increment()
        }
        watcher?.start()

        let burst = DispatchQueue(label: "burst", attributes: .concurrent)
        let group = DispatchGroup()
        for i in 0..<200 {
            group.enter()
            burst.async {
                defer { group.leave() }
                _ = try? tree.file("burst-\(i).txt", "x")
            }
        }

        // Let some events start flowing, then release mid-burst without stop().
        Thread.sleep(forTimeInterval: 0.05)
        watcher = nil

        // Keep creating files briefly after release; none of these should
        // reach a handler, and the process must stay alive (no use-after-free).
        for i in 200..<220 {
            group.enter()
            burst.async {
                defer { group.leave() }
                _ = try? tree.file("burst-\(i).txt", "x")
            }
        }
        group.wait()

        let countRightAfterRelease = counter.current
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(
            counter.current, countRightAfterRelease,
            "handler must not fire after the watcher is released without stop()"
        )
    }
}
