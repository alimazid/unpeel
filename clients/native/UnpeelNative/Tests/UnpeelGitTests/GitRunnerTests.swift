import XCTest
@testable import UnpeelGit

/// Counts how many times the runner asked where `git` is.
private final class ResolveCounter: @unchecked Sendable {
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

final class GitRunnerTests: XCTestCase {
    private func systemGit() throws -> URL {
        try XCTUnwrap(GitExecutableResolver.system.resolve(), "these tests need git installed")
    }

    private func systemRunner() throws -> GitRunner {
        let git = try systemGit()
        return GitRunner(resolver: GitExecutableResolver { git })
    }

    func testReadCommandRunsAndReturnsItsOutput() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write("a.txt", "a")
        let sha = try repo.commit("first")
        let runner = try systemRunner()

        guard case .finished(let output) = runner.run(.revParse, ["HEAD"], in: repo.root) else {
            return XCTFail("git was not run")
        }

        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.text.trimmingCharacters(in: .whitespacesAndNewlines), sha)
    }

    func testUnresolvedGitIsUnavailableAndNeverLookedUpTwice() {
        let counter = ResolveCounter()
        let runner = GitRunner(resolver: GitExecutableResolver {
            counter.record()
            return nil
        })

        XCTAssertEqual(runner.run(.status, [], in: "/tmp"), .unavailable)
        XCTAssertEqual(runner.run(.log, [], in: "/tmp"), .unavailable)
        XCTAssertFalse(runner.isAvailable)
        XCTAssertEqual(counter.count, 1)
    }

    func testGitThatCannotLaunchIsRememberedAsUnavailable() {
        let counter = ResolveCounter()
        let runner = GitRunner(resolver: GitExecutableResolver {
            counter.record()
            return URL(fileURLWithPath: "/definitely/not/a/git")
        })

        XCTAssertEqual(runner.run(.status, [], in: "/tmp"), .unavailable)
        XCTAssertEqual(runner.run(.status, [], in: "/tmp"), .unavailable)
        XCTAssertEqual(counter.count, 1)
    }

    func testResolvedOnceAcrossManyCalls() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        let counter = ResolveCounter()
        let git = try systemGit()
        let runner = GitRunner(resolver: GitExecutableResolver {
            counter.record()
            return git
        })

        for _ in 0..<3 {
            _ = runner.run(.revParse, ["--git-dir"], in: repo.root)
        }

        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(runner.isAvailable)
    }

    func testRunnerEnvironmentDisablesOptionalLocksAndPrompts() {
        let environment = GitRunner.environment(base: ["PATH": "/usr/bin", "GIT_DIR": "/elsewhere", "GIT_INDEX_FILE": "x"])

        XCTAssertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        // An inherited repository override would point every read at the
        // wrong repository, whatever `-C` says.
        XCTAssertNil(environment["GIT_DIR"])
        XCTAssertNil(environment["GIT_INDEX_FILE"])
    }

    func testOnlyReadCommandsExist() {
        XCTAssertEqual(
            Set(GitReadCommand.allCases.map(\.rawValue)),
            ["status", "rev-parse", "for-each-ref", "log", "show", "diff-tree", "check-ignore"]
        )
    }

    /// `git status` refreshes stale stat information in the index and, when
    /// it may, writes the index back under `index.lock` — the lock an
    /// agent's own `git commit` needs. The control run proves the fixture
    /// really makes plain git rewrite the index; the runner's run must not.
    func testStatusNeverRewritesTheIndex() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write("tracked.txt", "same")
        try repo.commit("first")
        let index = repo.path(".git/index")
        let runner = try systemRunner()

        func staleStat() throws {
            let past = Date(timeIntervalSinceNow: -3600 * Double.random(in: 1...100))
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: repo.path("tracked.txt"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: index)
        }
        func indexDate() throws -> Date {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date)
        }

        try staleStat()
        try repo.git("status", "--porcelain")
        XCTAssertNotEqual(try indexDate(), Date(timeIntervalSince1970: 1), "control: plain git status rewrites the index")

        try staleStat()
        _ = runner.run(.status, ["--porcelain=v2", "-z"], in: repo.root)
        XCTAssertEqual(try indexDate(), Date(timeIntervalSince1970: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.path(".git/index.lock")))
    }

    func testLargeInputAndOutputDoNotDeadlock() throws {
        let repo = try GitTestRepo(); defer { repo.delete() }
        try repo.write(".gitignore", "*.log\n")
        let paths = (0..<4000).map { repo.path("deeply/nested/folder/name/file-\($0).log") }
        let runner = try systemRunner()
        let input = Data(paths.joined(separator: "\0").utf8) + Data([0])

        guard case .finished(let output) = runner.run(.checkIgnore, ["-z", "--stdin"], in: repo.root, input: input) else {
            return XCTFail("git was not run")
        }

        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.stdout.split(separator: 0).count, 4000)
    }

    func testSystemResolverFindsARunnableGit() throws {
        let git = try systemGit()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: git.path))
        // Never the `/usr/bin/git` shim when a real binary is known: the shim
        // opens the "install developer tools" dialog on a Mac without them.
        XCTAssertNotEqual(git.path, "/usr/bin/git")
    }
}
