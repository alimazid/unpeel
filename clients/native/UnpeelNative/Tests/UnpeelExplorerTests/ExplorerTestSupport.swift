import UnpeelGit
import XCTest
@testable import UnpeelExplorer

final class ScanLog: @unchecked Sendable {
    private let lock = NSLock()
    private var scanned: [String] = []

    func record(_ directory: String) {
        lock.lock(); defer { lock.unlock() }
        scanned.append(directory)
    }

    var directories: [String] {
        lock.lock(); defer { lock.unlock() }
        return scanned
    }
}

/// Counts scan invocations per directory, so a test can make exactly one
/// call (identified by its position in the sequence) slow while every other
/// call to the same directory stays fast.
final class ScanCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func next(for directory: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        counts[directory, default: 0] += 1
        return counts[directory]!
    }
}

/// Counts the hub's snapshot reads per root, with optional per-root delays.
final class SnapshotReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String] = []
    private var delays: [String: TimeInterval] = [:]

    func setDelay(_ delay: TimeInterval, for root: String) {
        lock.lock(); defer { lock.unlock() }
        delays[root] = delay
    }

    func record(_ root: String) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        reads.append(root)
        return delays[root]
    }

    var roots: [String] {
        lock.lock(); defer { lock.unlock() }
        return reads
    }
}

/// Shared setup for the view-model suites: throwaway defaults (removed
/// after each test), scan services without git, view models, contexts.
@MainActor
class ExplorerViewModelTestCase: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }

    func makeDefaults() -> UserDefaults {
        let suite = "unpeel.explorer.vmtests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    /// Real scans (no ignore checking) with no watcher; `repositories`
    /// turns on Git Status Decorations, `roots` nested repositories.
    func services(
        log: ScanLog? = nil, delay: [String: TimeInterval] = [:], repositories: GitRepositoryHub? = nil,
        roots: GitRepositoryRoots? = nil
    ) -> ExplorerServices {
        ExplorerServices(
            scan: { directory, root in
                log?.record(directory)
                if let pause = delay[directory] { Thread.sleep(forTimeInterval: pause) }
                return try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { _, _ in nil },
            repositories: repositories,
            repositoryRoots: roots
        )
    }

    func makeViewModel(
        _ services: ExplorerServices? = nil,
        defaults: UserDefaults? = nil,
        decorationDebounce: TimeInterval = 0
    ) -> ExplorerViewModel {
        ExplorerViewModel(
            services: services ?? self.services(),
            stateStore: ExplorerStateStore(defaults: defaults ?? makeDefaults()),
            decorationDebounce: decorationDebounce
        )
    }

    func local(_ tree: TempTree) -> ExplorerContext {
        local(tree.root)
    }

    func local(_ root: String) -> ExplorerContext {
        .local(root: root, projectRoot: root)
    }

    let everything = VisibilityFilter(showHidden: true, showIgnored: true)
}

/// Polls `condition` until it holds or `timeout` passes, for changes that
/// arrive through real FSEvents. A free function: as a method of an
/// `XCTestCase` subclass, its Objective-C thunk cannot take the closure.
@MainActor
func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}
