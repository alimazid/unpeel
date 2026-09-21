import CoreServices
import XCTest
@testable import UnpeelExplorer

/// Reference wrapper so a handler closure (created before the watcher it
/// controls exists, or that needs to reach a second watcher) can hold a
/// mutable reference without capturing a local `var`, which `@Sendable`
/// closures reject.
private final class WatcherBox: @unchecked Sendable {
    var watcher: FileSystemWatcher?
}

/// Thread-safe counter for handlers that run on a watcher's private queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A one-shot, thread-safe latch for "have we already done the one-time
/// thing" checks inside a handler, without capturing a local `var`.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Returns true the first time it is called, false every time after.
    func trySet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}

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

    /// Under an event storm the kernel coalesces or drops events and flags
    /// the surviving one; every descendant of that path is then stale, so
    /// the change must ask for a full rescan rather than a targeted reload.
    func testDroppedOrCoalescedEventFlagsRequestAFullRescan() {
        let flags = [
            kFSEventStreamEventFlagMustScanSubDirs,
            kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagRootChanged,
        ]
        for flag in flags {
            let change = FileSystemChange.from(eventPaths: ["/r/src"], eventFlags: [UInt32(flag)])
            XCTAssertTrue(change.needsFullRescan, "flag \(flag) must request a full rescan")
            XCTAssertEqual(change.directories, ["/r", "/r/src"], "flag \(flag): paths still map as before")
        }
    }

    func testOrdinaryEventFlagsDoNotRequestAFullRescan() {
        let change = FileSystemChange.from(
            eventPaths: ["/r/src/a.swift"],
            eventFlags: [UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)]
        )

        XCTAssertFalse(change.needsFullRescan)
        XCTAssertEqual(change.directories, ["/r/src", "/r/src/a.swift"])
    }

    /// Flags are OR'ed across the batch: one dropped event invalidates the
    /// whole delivery, not just its own path.
    func testAFullRescanFlagAnywhereInTheBatchCounts() {
        let change = FileSystemChange.from(
            eventPaths: ["/r/a.txt", "/r/src"],
            eventFlags: [UInt32(kFSEventStreamEventFlagItemCreated), UInt32(kFSEventStreamEventFlagKernelDropped)]
        )

        XCTAssertTrue(change.needsFullRescan)
    }

    func testPathOnlyMappingNeverRequestsAFullRescan() {
        XCTAssertFalse(FileSystemChange.from(eventPaths: ["/r/docs"]).needsFullRescan)
        XCTAssertFalse(FileSystemChange.from(eventPaths: ["/r/src"], eventFlags: []).needsFullRescan)
    }

    func testCreatingAFileReportsItsDirectory() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let sub = try tree.dir("sub")
        let reported = expectation(description: "change under sub reported")
        reported.assertForOverFulfill = false
        let watcher = FileSystemWatcher(root: tree.root, latency: 0.05) { change in
            if change.directories.contains(sub) { reported.fulfill() }
        }
        XCTAssertTrue(watcher.start(), "start() must report that the stream is running")
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
        stopped.assertForOverFulfill = false

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

    /// `start()` called from inside the handler must not deadlock either
    /// (same reentrant-queue hazard as `stop()`), and restarting must resume
    /// real delivery: a change made after the restart is still reported.
    func testStartAfterStopFromInsideHandlerRedeliversLater() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let restarted = expectation(description: "handler stopped and restarted the watcher")
        let redelivered = expectation(description: "a later change is delivered after restart")
        redelivered.assertForOverFulfill = false

        let box = WatcherBox()
        let didRestart = Flag()
        box.watcher = FileSystemWatcher(root: tree.root, latency: 0.05) { _ in
            if didRestart.trySet() {
                box.watcher?.stop()
                box.watcher?.start()
                restarted.fulfill()
            } else {
                redelivered.fulfill()
            }
        }
        box.watcher?.start()
        defer { box.watcher?.stop() }

        try tree.file("first.txt")
        wait(for: [restarted], timeout: 10)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            _ = try? tree.file("second.txt", "later")
        }

        wait(for: [redelivered], timeout: 10)
    }

    /// Dropping the only reference to a watcher without calling `stop()`
    /// while events are actively flowing must not race or use-after-free:
    /// the FSEvents callback only ever touches a heap box the watcher owns,
    /// never the watcher itself, and `deinit` tears the stream down
    /// synchronously — on any thread — before returning. The baseline is
    /// taken immediately after `watcher = nil` returns (not after further
    /// work), so a post-release delivery would actually move the count the
    /// assertion checks.
    func testReleasingWithoutStopWhileEventsFlowIsSafe() throws {
        let tree = try TempTree(); defer { tree.remove() }

        let counter = Counter()
        let firstDelivery = expectation(description: "watcher delivered at least one change before release")
        firstDelivery.assertForOverFulfill = false

        var watcher: FileSystemWatcher? = FileSystemWatcher(root: tree.root, latency: 0.01) { _ in
            counter.increment()
            firstDelivery.fulfill()
        }
        watcher?.start()

        // A single background loop (not many concurrently-dispatched blocks)
        // so the test is not sensitive to a loaded machine's thread limit.
        let burstQueue = DispatchQueue(label: "burst")
        let burstSize = 200
        burstQueue.async {
            for i in 0..<burstSize {
                _ = try? tree.file("burst-\(i).txt", "x")
            }
        }

        wait(for: [firstDelivery], timeout: 10)
        XCTAssertGreaterThan(counter.current, 0, "handler must have run before release for this test to be meaningful")

        watcher = nil // release without stop(); deinit tears the stream down synchronously.
        let snapshot = counter.current // nothing may run after `deinit` above returns

        // Keep creating files briefly after release; none of these should
        // reach a handler, and the process must stay alive (no use-after-free).
        burstQueue.async {
            for i in burstSize..<(burstSize + 20) {
                _ = try? tree.file("burst-\(i).txt", "x")
            }
        }

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(
            counter.current, snapshot,
            "handler must not fire after the watcher is released without stop()"
        )
    }

    /// A second watcher's queue must not be mistaken for "my own queue": if
    /// A's handler stops B, that must go through `queue.sync` onto B's own
    /// queue (not run inline on A's queue), or B's stream/box would be
    /// mutated off B's queue while B's own callback could be running.
    func testStoppingAnotherWatcherFromADifferentWatchersHandlerIsSafe() throws {
        let treeA = try TempTree(); defer { treeA.remove() }
        let treeB = try TempTree(); defer { treeB.remove() }

        let bCounter = Counter()
        let firstBDelivery = expectation(description: "B delivered at least one change before being stopped")
        firstBDelivery.assertForOverFulfill = false

        let boxB = WatcherBox()
        boxB.watcher = FileSystemWatcher(root: treeB.root, latency: 0.01) { _ in
            bCounter.increment()
            firstBDelivery.fulfill()
        }
        boxB.watcher?.start()
        defer { boxB.watcher?.stop() }

        let burstQueue = DispatchQueue(label: "burst-b")
        burstQueue.async {
            for i in 0..<200 {
                _ = try? treeB.file("burst-\(i).txt", "x")
            }
        }

        wait(for: [firstBDelivery], timeout: 10)
        XCTAssertGreaterThan(bCounter.current, 0)

        let stoppedFromA = expectation(description: "A's handler stopped B")
        let didStop = Flag()
        let boxA = WatcherBox()
        boxA.watcher = FileSystemWatcher(root: treeA.root, latency: 0.01) { _ in
            if didStop.trySet() {
                boxB.watcher?.stop()
                stoppedFromA.fulfill()
            }
        }
        boxA.watcher?.start()
        defer { boxA.watcher?.stop() }

        try treeA.file("trigger.txt")
        wait(for: [stoppedFromA], timeout: 10)

        let countAtStop = bCounter.current
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(bCounter.current, countAtStop, "B must not deliver after being stopped from A's handler")
    }

    /// Same hazard as above, but A drops the last reference to B instead of
    /// calling `stop()` on it — exercising `deinit`'s cross-queue path.
    func testReleasingAnotherWatcherFromADifferentWatchersHandlerIsSafe() throws {
        let treeA = try TempTree(); defer { treeA.remove() }
        let treeB = try TempTree(); defer { treeB.remove() }

        let bCounter = Counter()
        let firstBDelivery = expectation(description: "B delivered at least one change before being released")
        firstBDelivery.assertForOverFulfill = false

        let boxB = WatcherBox()
        boxB.watcher = FileSystemWatcher(root: treeB.root, latency: 0.01) { _ in
            bCounter.increment()
            firstBDelivery.fulfill()
        }
        boxB.watcher?.start()

        let burstQueue = DispatchQueue(label: "burst-b2")
        burstQueue.async {
            for i in 0..<200 {
                _ = try? treeB.file("burst-\(i).txt", "x")
            }
        }

        wait(for: [firstBDelivery], timeout: 10)
        XCTAssertGreaterThan(bCounter.current, 0)

        let releasedFromA = expectation(description: "A's handler released B")
        let didRelease = Flag()
        let boxA = WatcherBox()
        boxA.watcher = FileSystemWatcher(root: treeA.root, latency: 0.01) { _ in
            if didRelease.trySet() {
                boxB.watcher = nil // drop the only reference to B
                releasedFromA.fulfill()
            }
        }
        boxA.watcher?.start()
        defer { boxA.watcher?.stop() }

        try treeA.file("trigger.txt")
        wait(for: [releasedFromA], timeout: 10)

        let countAtRelease = bCounter.current
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(bCounter.current, countAtRelease, "B must not deliver after being released from A's handler")
    }

    /// Deterministic, unit-level check of the on-own-queue detection itself:
    /// true only from inside that watcher's own handler, false from another
    /// watcher's handler and false from the main thread.
    func testIsOnOwnQueueIdentifiesOnlyThatWatchersQueue() throws {
        let treeA = try TempTree(); defer { treeA.remove() }
        let treeB = try TempTree(); defer { treeB.remove() }

        let boxA = WatcherBox()
        let boxB = WatcherBox()
        let checked = expectation(description: "checked isOnOwnQueue from A's own queue")

        boxA.watcher = FileSystemWatcher(root: treeA.root, latency: 0.01) { _ in
            XCTAssertTrue(boxA.watcher?.isOnOwnQueue ?? false)
            XCTAssertFalse(boxB.watcher?.isOnOwnQueue ?? true)
            checked.fulfill()
        }
        boxB.watcher = FileSystemWatcher(root: treeB.root, latency: 0.01) { _ in }

        boxA.watcher?.start()
        boxB.watcher?.start()
        defer { boxA.watcher?.stop(); boxB.watcher?.stop() }

        XCTAssertFalse(boxA.watcher?.isOnOwnQueue ?? true)
        XCTAssertFalse(boxB.watcher?.isOnOwnQueue ?? true)

        try treeA.file("trigger.txt")
        wait(for: [checked], timeout: 10)
    }
}
