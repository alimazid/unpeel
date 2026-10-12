import UnpeelGit
import XCTest
@testable import UnpeelExplorer

final class GitIgnoreCheckerTests: XCTestCase {
    /// A Mac without git: the checker answers "nothing ignored" and the
    /// shared runner never looks git up again, so a scan spawns nothing.
    func testUnavailableGitIgnoresNothingWithoutRetrying() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("debug.log")
        let lookups = LookupCounter()
        let checker = GitIgnoreChecker(runner: GitRunner(resolver: GitExecutableResolver {
            lookups.record()
            return nil
        }))

        XCTAssertTrue(checker.ignoredPaths(among: [tree.path("debug.log")], root: tree.root).isEmpty)
        XCTAssertTrue(checker.ignoredPaths(among: [tree.path("debug.log")], root: tree.root).isEmpty)
        XCTAssertEqual(lookups.count, 1)
    }
}

private final class LookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock(); defer { lock.unlock() }
        calls += 1
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}
