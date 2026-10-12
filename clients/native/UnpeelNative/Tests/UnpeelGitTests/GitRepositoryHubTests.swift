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
