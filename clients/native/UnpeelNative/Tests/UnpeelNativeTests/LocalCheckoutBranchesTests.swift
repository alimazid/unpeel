import Foundation
import XCTest
import UnpeelShared
@testable import UnpeelNative

/// Fork-only (#57): what the sidebar's branch mark reads on this Mac. The pool
/// reads HEAD files off the main thread when a local workspace's project list
/// changes, and `git symbolic-ref`'s answers land in the same place, so the
/// pooled page and the live label can't disagree.
@MainActor
final class LocalCheckoutBranchesTests: XCTestCase {
    private var head: ScriptedHead!
    private var pool: WorkspacePool!
    private let repo = "/fixture/repo"
    private let localKey = WorkspaceListOrder.localKey(home: "/fixture/home")

    override func setUp() async throws {
        let head = ScriptedHead()
        self.head = head
        pool = WorkspacePool(readCheckedOutBranch: { head.read($0) })
        pool.start(targetsProvider: { [] }, excludedKeys: { [] }, foregroundKey: { nil })
    }

    override func tearDown() async throws {
        pool.stop()
        pool = nil
    }

    private func snapshot(
        projects: [RemoteProjectSummary],
        sessionTitle: String = "shell",
        capturedAt: Int64 = 1
    ) -> RemoteBootstrapSnapshot {
        RemoteBootstrapSnapshot(
            folders: [],
            projects: projects,
            presets: [],
            sessions: [RemoteSessionSummary(
                id: "s1",
                projectID: projects[0].id,
                title: sessionTitle,
                command: "zsh",
                createdAtUnixMs: 1,
                status: .running,
                activity: .idle,
                unread: false,
                pinned: false
            )],
            capturedAtUnixMs: capturedAt
        )
    }

    private func project(gitBranch: String? = nil) -> RemoteProjectSummary {
        RemoteProjectSummary(id: "p", name: "p", path: repo, gitBranch: gitBranch, sortOrder: 0)
    }

    /// Every read already asked for has landed once this returns: reads run in
    /// order on one queue and land in order on main. The marker's read names
    /// nothing, so it moves no generation.
    private func readsLanded() async {
        let marker = "/fixture/landed"
        let before = head.reads(of: marker)
        pool.checkouts.refresh(paths: [marker])
        await waitUntil { self.head.reads(of: marker) > before }
        await withCheckedContinuation { landed in
            DispatchQueue.main.async { landed.resume() }
        }
    }

    private func read(_ name: String?) async {
        head.names[repo] = name
        pool.checkouts.refresh(paths: [repo])
        await readsLanded()
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: When the pool reads

    func testAWorkspaceOnThisMacIsReadOffTheMainThread() async {
        head.names[repo] = "feature-branch"

        pool.noteExternalSnapshot(snapshot(projects: [project()]), forKey: localKey, name: "Local")
        await readsLanded()

        XCTAssertEqual(pool.checkouts.branch(atPath: repo), "feature-branch")
        XCTAssertEqual(head.reads(of: repo), 1)
        XCTAssertFalse(head.readOnMain, "the swipe's path never touches the disk")
    }

    func testARemoteHostsPathsAreNeverRead() async {
        head.names[repo] = "not-on-this-mac"

        pool.noteExternalSnapshot(
            snapshot(projects: [project()]), forKey: WorkspaceListOrder.pairedKey(hostID: "h"), name: "Paired"
        )
        pool.noteExternalSnapshot(
            snapshot(projects: [project()]), forKey: WorkspaceListOrder.sshKey(id: "s"), name: "SSH"
        )
        await readsLanded()

        XCTAssertEqual(head.reads(of: repo), 0)
        XCTAssertNil(pool.checkouts.branch(atPath: repo))
    }

    /// Session churn leaves the project list alone; a checkout changes it,
    /// because `gitBranch` is in it.
    func testOnlyAChangedProjectListIsReadAgain() async {
        pool.noteExternalSnapshot(snapshot(projects: [project(gitBranch: "a")]), forKey: localKey, name: "Local")
        await readsLanded()
        XCTAssertEqual(head.reads(of: repo), 1)

        pool.noteExternalSnapshot(
            snapshot(projects: [project(gitBranch: "a")], sessionTitle: "busy", capturedAt: 2),
            forKey: localKey,
            name: "Local"
        )
        await readsLanded()
        XCTAssertEqual(head.reads(of: repo), 1, "a Session changed; no project did")

        pool.noteExternalSnapshot(
            snapshot(projects: [project(gitBranch: "b")], capturedAt: 3), forKey: localKey, name: "Local"
        )
        await readsLanded()
        XCTAssertEqual(head.reads(of: repo), 2, "a checkout changed gitBranch")
    }

    func testAWorktreesPathIsNotRead() async {
        let worktree = RemoteProjectSummary(
            id: "w", name: "w", path: "/fixture/worktree", worktreeBranch: "feature", sortOrder: 1
        )

        pool.noteExternalSnapshot(snapshot(projects: [project(), worktree]), forKey: localKey, name: "Local")
        await readsLanded()

        XCTAssertEqual(head.reads(of: repo), 1)
        XCTAssertEqual(head.reads(of: "/fixture/worktree"), 0, "a worktree's row already carries its branch")
    }

    // MARK: Which answer stays

    /// A reftable repo: HEAD is a stub, so only `git` can name the branch.
    func testAReadWithNoNameKeepsTheNameGitGave() async {
        pool.checkouts.noteGitAnswer("rt-branch", atPath: repo)

        await read(nil)

        XCTAssertEqual(pool.checkouts.branch(atPath: repo), "rt-branch")
    }

    /// The checkout went detached: nothing but a read has named this path.
    func testAReadWithNoNameClearsTheNameAnEarlierReadGave() async {
        await read("feature-branch")

        await read(nil)

        XCTAssertNil(pool.checkouts.branch(atPath: repo))
    }

    func testGitAnsweringNoNameClearsTheName() async {
        await read("feature-branch")

        pool.checkouts.noteGitAnswer(nil, atPath: repo)

        XCTAssertNil(pool.checkouts.branch(atPath: repo))
    }

    func testAReadThatStartedBeforeGitAnsweredDoesNotOverwriteIt() async {
        head.names[repo] = "older"
        let gate = head.hold(repo)
        pool.checkouts.refresh(paths: [repo])
        await waitUntil { self.head.reads(of: self.repo) == 1 }

        pool.checkouts.noteGitAnswer("newer", atPath: repo)
        gate.signal()
        await readsLanded()

        XCTAssertEqual(pool.checkouts.branch(atPath: repo), "newer")
    }

    func testAReadThatStartedAfterGitAnsweredWins() async {
        pool.checkouts.noteGitAnswer("older", atPath: repo)

        await read("newer")

        XCTAssertEqual(pool.checkouts.branch(atPath: repo), "newer")
    }

    // MARK: What a write costs

    func testOnlyAChangedNameMovesTheGeneration() async {
        await read("feature-branch")
        let generation = pool.checkouts.nameGeneration

        await read("feature-branch")
        pool.checkouts.noteGitAnswer("feature-branch", atPath: repo)
        XCTAssertEqual(pool.checkouts.nameGeneration, generation, "the same name again costs nothing")

        pool.checkouts.noteGitAnswer("moved-on", atPath: repo)
        XCTAssertNotEqual(pool.checkouts.nameGeneration, generation)
    }
}

/// HEAD files as a script: a name per path, with a count of each read, and a
/// gate that holds one path's read for as long as a test needs.
private final class ScriptedHead: @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String: String] = [:]
    private var counts: [String: Int] = [:]
    private var gates: [String: DispatchSemaphore] = [:]
    private var sawMain = false

    var names: [String: String] {
        get { lock.withLock { scripted } }
        set { lock.withLock { scripted = newValue } }
    }

    var readOnMain: Bool { lock.withLock { sawMain } }

    func reads(of path: String) -> Int {
        lock.withLock { counts[path, default: 0] }
    }

    func hold(_ path: String) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock { gates[path] = gate }
        return gate
    }

    func read(_ path: String) -> String? {
        let (name, gate) = lock.withLock {
            counts[path, default: 0] += 1
            sawMain = sawMain || Thread.isMainThread
            return (scripted[path], gates.removeValue(forKey: path))
        }
        gate?.wait()
        return name
    }
}
