import XCTest
@testable import UnpeelGit

/// Scripted snapshot reads per root, counted, with an optional delay.
final class FakeRepositoryReads: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: GitReadResult<GitRepositorySnapshot>] = [:]
    private var delays: [String: TimeInterval] = [:]
    private var reads: [String] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func set(_ result: GitReadResult<GitRepositorySnapshot>, for root: String, delay: TimeInterval? = nil) {
        locked {
            results[root] = result
            delays[root] = delay
        }
    }

    func setHead(_ head: GitHead, for root: String, entries: [GitStatusEntry] = []) {
        set(.success(snapshot(root: root, head: head, entries: entries)), for: root)
    }

    var readRoots: [String] { locked { reads } }

    func read(_ root: String) -> GitReadResult<GitRepositorySnapshot> {
        if let delay = locked({ delays[root] }) { Thread.sleep(forTimeInterval: delay) }
        return locked {
            reads.append(root)
            return results[root] ?? .failure(.notARepository)
        }
    }
}

func snapshot(root: String, head: GitHead = GitHead(oid: "c-0", branch: "main"), entries: [GitStatusEntry] = []) -> GitRepositorySnapshot {
    GitRepositorySnapshot(
        location: GitRepositoryLocation(workTree: root, gitDirectory: root + "/.git", commonDirectory: root + "/.git"),
        status: GitStatus(head: head, entries: entries)
    )
}

@MainActor
final class GitRepositoryHubTests: XCTestCase {
    private func hub(_ reads: FakeRepositoryReads) -> GitRepositoryHub {
        GitRepositoryHub(services: GitRepositoryHubServices(read: { reads.read($0) }))
    }

    func testViewsAskingAtOnceShareOneRead() async {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/repo")), for: "/repo", delay: 0.1)
        let hub = hub(reads)
        let subscription = hub.subscribe(root: "/repo")
        defer { subscription.cancel() }

        async let first = hub.status(root: "/repo")
        async let second = hub.status(root: "/repo")
        let results = await [first, second]

        XCTAssertEqual(reads.readRoots, ["/repo"])
        XCTAssertEqual(results.map { try? $0.get() }, [snapshot(root: "/repo"), snapshot(root: "/repo")])
    }

    func testAReadIsReusedUntilTheWorkingTreeChanges() async {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/repo")), for: "/repo")
        let hub = hub(reads)
        let subscription = hub.subscribe(root: "/repo")
        defer { subscription.cancel() }

        _ = await hub.status(root: "/repo")
        _ = await hub.status(root: "/repo")
        XCTAssertEqual(reads.readRoots.count, 1)

        let edited = snapshot(root: "/repo", entries: [GitStatusEntry(path: "a.txt", kind: .modified)])
        reads.set(.success(edited), for: "/repo")
        hub.workingTreeDidChange(root: "/repo")

        let fresh = await hub.status(root: "/repo")
        XCTAssertEqual(try? fresh.get(), edited)
        XCTAssertEqual(reads.readRoots.count, 2)
    }

    /// A read that started before a change describes the tree before it,
    /// so a caller asking after the change gets a read of its own.
    func testAReadFromBeforeAChangeIsNotServedAfterIt() async throws {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/repo")), for: "/repo", delay: 0.2)
        let hub = hub(reads)
        let subscription = hub.subscribe(root: "/repo")
        defer { subscription.cancel() }

        let before = Task { await hub.status(root: "/repo") }
        try await Task.sleep(nanoseconds: 50_000_000)
        hub.workingTreeDidChange(root: "/repo")
        let after = await hub.status(root: "/repo")
        _ = await before.value

        XCTAssertEqual(reads.readRoots.count, 2)
        XCTAssertNotNil(try? after.get())
    }

    func testRootsAreReadSeparately() async {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/a")), for: "/a")
        let hub = hub(reads)
        let subscriptions = [hub.subscribe(root: "/a"), hub.subscribe(root: "/b")]
        defer { subscriptions.forEach { $0.cancel() } }

        let a = await hub.status(root: "/a")
        let b = await hub.status(root: "/b")
        XCTAssertEqual(try? a.get(), snapshot(root: "/a"))
        XCTAssertEqual(b, .failure(.notARepository))
        XCTAssertEqual(reads.readRoots, ["/a", "/b"])
    }

    /// Nothing is kept for a root nobody follows: once the last view lets
    /// go, the next read is fresh.
    func testTheLastSubscriberLettingGoForgetsTheRoot() async {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/repo")), for: "/repo")
        let hub = hub(reads)
        let first = hub.subscribe(root: "/repo")
        let second = hub.subscribe(root: "/repo")
        _ = await hub.status(root: "/repo")

        first.cancel()
        _ = await hub.status(root: "/repo")
        XCTAssertEqual(reads.readRoots.count, 1)

        second.cancel()
        _ = await hub.status(root: "/repo")
        _ = await hub.status(root: "/repo")
        XCTAssertEqual(reads.readRoots.count, 3)
    }

    // MARK: - The repository-change signal (#5)

    private func watchingHub(_ reads: FakeRepositoryReads, _ monitors: FakeMonitors) -> GitRepositoryHub {
        GitRepositoryHub(services: GitRepositoryHubServices(
            read: { reads.read($0) },
            makeMonitor: { monitors.make($0, $1) },
            makeFolderMonitor: { monitors.makeFolder($0, $1) }
        ))
    }

    /// A signal hops to the main actor before anyone hears it.
    private func fire(_ monitor: FakeMonitors.Monitor?) async {
        monitor?.handler()
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func testAFollowedRepositoryIsWatchedOnceForAllItsViews() async {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/repo")), for: "/repo")
        let monitors = FakeMonitors()
        let hub = watchingHub(reads, monitors)
        let first = hub.subscribe(root: "/repo")
        let second = hub.subscribe(root: "/repo")
        _ = await hub.status(root: "/repo")
        _ = await hub.status(root: "/repo")

        XCTAssertEqual(monitors.active.map(\.location?.gitDirectory), ["/repo/.git"])

        first.cancel()
        XCTAssertEqual(monitors.active.count, 1)
        second.cancel()
        XCTAssertTrue(monitors.active.isEmpty, "the watch ends with the last view")
    }

    /// One signal reaches every view, and the next status call reads again.
    func testASignalRereadsAndNotifiesEveryView() async {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/repo")), for: "/repo")
        let monitors = FakeMonitors()
        let hub = watchingHub(reads, monitors)
        var heard: [String] = []
        let explorer = hub.subscribe(root: "/repo") { heard.append("explorer") }
        let history = hub.subscribe(root: "/repo") { heard.append("history") }
        defer { explorer.cancel(); history.cancel() }
        _ = await hub.status(root: "/repo")

        await fire(monitors.active.first)
        _ = await hub.status(root: "/repo")
        _ = await hub.status(root: "/repo")

        XCTAssertEqual(heard.sorted(), ["explorer", "history"])
        XCTAssertEqual(reads.readRoots.count, 2)
    }

    /// A folder that is not a repository is watched for a `.git` to appear;
    /// once one has, its repository is watched instead.
    func testAFolderBecomingARepositoryIsNoticed() async {
        let reads = FakeRepositoryReads()
        let monitors = FakeMonitors()
        let hub = watchingHub(reads, monitors)
        var heard = 0
        let subscription = hub.subscribe(root: "/plain") { heard += 1 }
        defer { subscription.cancel() }
        _ = await hub.status(root: "/plain")
        XCTAssertEqual(monitors.active.map(\.folder), ["/plain"])

        reads.set(.success(snapshot(root: "/plain")), for: "/plain")
        await fire(monitors.active.first)
        XCTAssertEqual(heard, 1)
        let status = await hub.status(root: "/plain")

        XCTAssertNotNil(try? status.get())
        XCTAssertEqual(monitors.active.map(\.location?.gitDirectory), ["/plain/.git"])
    }

    func testARepositoryThatGoesAwayIsWatchedForANewOne() async {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/repo")), for: "/repo")
        let monitors = FakeMonitors()
        let hub = watchingHub(reads, monitors)
        let subscription = hub.subscribe(root: "/repo")
        defer { subscription.cancel() }
        _ = await hub.status(root: "/repo")

        reads.set(.failure(.notARepository), for: "/repo")
        await fire(monitors.active.first)
        _ = await hub.status(root: "/repo")

        XCTAssertEqual(monitors.active.map(\.folder), ["/repo"])
    }

    func testWithoutGitNothingIsWatched() async {
        let reads = FakeRepositoryReads()
        reads.set(.failure(.gitUnavailable), for: "/repo")
        let monitors = FakeMonitors()
        let hub = watchingHub(reads, monitors)
        let subscription = hub.subscribe(root: "/repo")
        defer { subscription.cancel() }

        _ = await hub.status(root: "/repo")

        XCTAssertTrue(monitors.all.isEmpty)
    }

    /// A monitor that was replaced, or whose root nobody follows any more,
    /// is not heard.
    func testSignalsFromAReplacedOrReleasedWatchAreIgnored() async {
        let reads = FakeRepositoryReads()
        let monitors = FakeMonitors()
        let hub = watchingHub(reads, monitors)
        var heard = 0
        let subscription = hub.subscribe(root: "/plain") { heard += 1 }
        _ = await hub.status(root: "/plain")
        let folderWatch = monitors.active.first
        reads.set(.success(snapshot(root: "/plain")), for: "/plain")
        hub.repositoryDidChange(root: "/plain")
        _ = await hub.status(root: "/plain")
        let repositoryWatch = monitors.active.first
        heard = 0

        await fire(folderWatch)
        XCTAssertEqual(heard, 0, "the folder watch was replaced")

        subscription.cancel()
        await fire(repositoryWatch)
        XCTAssertEqual(heard, 0, "nobody follows the root any more")
    }

    func testCancellingTwiceOrDroppingASubscriptionIsSafe() async {
        let reads = FakeRepositoryReads()
        reads.set(.success(snapshot(root: "/repo")), for: "/repo")
        let hub = hub(reads)
        let kept = hub.subscribe(root: "/repo")
        var dropped: GitRepositorySubscription? = hub.subscribe(root: "/repo")
        _ = await hub.status(root: "/repo")

        dropped?.cancel()
        dropped?.cancel()
        dropped = nil
        _ = await hub.status(root: "/repo")

        XCTAssertEqual(reads.readRoots.count, 1, "the kept subscription still holds the root")
        kept.cancel()
    }
}
