import UnpeelGit
import XCTest
@testable import UnpeelExplorer

/// Holds the hub's repository-change handler so a test fires the signal
/// itself, exactly once.
private final class SignalBox: GitChangeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func capture(_ handler: @escaping @Sendable () -> Void) -> SignalBox {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        return self
    }

    func fire() {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?()
    }

    func stop() {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Fork-only: git support (#10). The EXPLORER's decorations and Git
/// History follow one root through one hub: a repository change costs one
/// status read and one log-head read, not one per view.
@MainActor
final class SharedRepositoryReadTests: XCTestCase {
    func testOneRepositoryChangeIsOneStatusReadAndOneLogReadAcrossBothViews() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "a"); try tree.initRepository()
        try tree.file("a.txt", "edited")
        let suite = "unpeel.explorer.sharedreads.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let reader = GitReader()
        let statusReads = SnapshotReadLog()
        let logReads = Counter()
        let signal = SignalBox()
        let hub = GitRepositoryHub(services: GitRepositoryHubServices(
            read: { root in
                _ = statusReads.record(root)
                return reader.snapshot(at: root)
            },
            makeMonitor: { _, handler in signal.capture(handler) }
        ))
        let explorer = ExplorerViewModel(
            services: ExplorerServices(
                scan: { directory, root in
                    try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
                },
                makeWatcher: { _, _ in nil },
                repositories: hub
            ),
            stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!),
            decorationDebounce: 0
        )
        let history = GitHistoryViewModel(
            services: GitHistoryServices(
                branches: { reader.branches(at: $0) },
                logPage: { root, scope, offset, limit in
                    logReads.increment()
                    return reader.logPage(at: root, scope: scope, offset: offset, limit: limit)
                },
                commitDetail: { reader.commitDetail(at: $0, commit: $1) },
                repositories: hub
            ),
            changeDebounce: 0
        )
        let context = ExplorerContext.local(root: tree.root, projectRoot: tree.root)
        await explorer.setContext(context).value
        await history.setContext(context).value
        XCTAssertEqual(explorer.decorations.kind(at: tree.path("a.txt")), .modified)
        XCTAssertEqual(history.commits.map(\.subject), ["first"])
        let statusBefore = statusReads.roots.count
        let logBefore = logReads.value

        try tree.git("commit", "-q", "-am", "agent commit")
        signal.fire()
        let deadline = Date().addingTimeInterval(5)
        while history.commits.first?.subject != "agent commit" || !explorer.decorations.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(history.commits.map(\.subject), ["agent commit", "first"])
        XCTAssertTrue(explorer.decorations.isEmpty)
        XCTAssertEqual(statusReads.roots.count - statusBefore, 1, "one status read for both views")
        XCTAssertEqual(logReads.value - logBefore, 1, "one log-head read")
    }
}
