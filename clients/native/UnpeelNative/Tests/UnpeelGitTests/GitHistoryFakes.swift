import Foundation
@testable import UnpeelGit

/// Scripted reader results per root, with optional per-root delays, so a
/// test controls exactly what each read returns and when. Every read is
/// recorded in order. HEAD and the location are served as the shared
/// hub's status read (`hubServices`), the way the app shares them.
final class FakeGitHistory: @unchecked Sendable {
    struct LogCall: Equatable {
        let root: String
        let scope: GitLogScope
        let offset: Int
    }

    private let lock = NSLock()
    private var heads: [String: GitReadResult<GitHead>] = [:]
    private var logs: [String: [GitLogScope: [GitCommit]]] = [:]
    private var logFailures: [String: GitReadFailure] = [:]
    private var branchLists: [String: GitReadResult<[GitRef]>] = [:]
    private var locations: [String: GitRepositoryLocation] = [:]
    private var details: [String: GitReadResult<GitCommitDetail>] = [:]
    private var detailDelays: [String: TimeInterval] = [:]
    private var detailReads: [String] = []
    private var delays: [String: TimeInterval] = [:]
    private var logDelays: [String: TimeInterval] = [:]
    private var statusReads: [String] = []
    private var logReads: [LogCall] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func setHead(_ result: GitReadResult<GitHead>, for root: String) {
        locked { heads[root] = result }
    }

    func setCommits(_ commits: [GitCommit], for root: String, scope: GitLogScope = .head) {
        locked { logs[root, default: [:]][scope] = commits }
    }

    func setBranches(_ refs: [GitRef], for root: String) {
        locked { branchLists[root] = .success(refs) }
    }

    func setBranchFailure(_ failure: GitReadFailure, for root: String) {
        locked { branchLists[root] = .failure(failure) }
    }

    func setLocation(_ location: GitRepositoryLocation, for root: String) {
        locked { locations[root] = location }
    }

    func setDetail(_ result: GitReadResult<GitCommitDetail>, for sha: String, delay: TimeInterval? = nil) {
        locked {
            details[sha] = result
            detailDelays[sha] = delay
        }
    }

    var detailReadSHAs: [String] { locked { detailReads } }

    func setLogFailure(_ failure: GitReadFailure?, for root: String) {
        locked { logFailures[root] = failure }
    }

    /// Delays every read for `root`.
    func setDelay(_ delay: TimeInterval?, for root: String) {
        locked { delays[root] = delay }
    }

    /// Delays only log reads for `root` (e.g. a slow load-more).
    func setLogDelay(_ delay: TimeInterval?, for root: String) {
        locked { logDelays[root] = delay }
    }

    /// Every status read the hub made, by root.
    var statusReadRoots: [String] { locked { statusReads } }
    var logCalls: [LogCall] { locked { logReads } }

    private func pause(_ delay: TimeInterval?) {
        if let delay { Thread.sleep(forTimeInterval: delay) }
    }

    func snapshot(_ root: String) -> GitReadResult<GitRepositorySnapshot> {
        pause(locked { delays[root] })
        return locked {
            statusReads.append(root)
            let location = locations[root] ?? GitRepositoryLocation(
                workTree: root, gitDirectory: root + "/.git", commonDirectory: root + "/.git"
            )
            return (heads[root] ?? .failure(.notARepository)).map {
                GitRepositorySnapshot(location: location, status: GitStatus(head: $0, entries: []))
            }
        }
    }

    func branches(_ root: String) -> GitReadResult<[GitRef]> {
        pause(locked { delays[root] })
        return locked { branchLists[root] ?? .success([]) }
    }

    func detail(_ root: String, _ commit: GitCommit) -> GitReadResult<GitCommitDetail> {
        pause(locked { detailDelays[commit.sha] })
        return locked {
            detailReads.append(commit.sha)
            return details[commit.sha] ?? .success(GitCommitDetail(sha: commit.sha, message: commit.subject, files: []))
        }
    }

    func logPage(_ root: String, _ scope: GitLogScope, _ offset: Int, _ limit: Int) -> GitReadResult<GitLogPage> {
        pause(locked { delays[root] ?? logDelays[root] })
        return locked {
            logReads.append(LogCall(root: root, scope: scope, offset: offset))
            if let failure = logFailures[root] { return .failure(failure) }
            let all = logs[root]?[scope] ?? []
            let page = Array(all.dropFirst(offset).prefix(limit))
            return .success(GitLogPage(commits: page, hasMore: offset + limit < all.count))
        }
    }

    /// Monitors handed out by `services`, in creation order.
    let monitors = FakeMonitors()

    /// The hub's reads and watches, served by this fake.
    var hubServices: GitRepositoryHubServices {
        GitRepositoryHubServices(
            read: { [self] root in snapshot(root) },
            makeMonitor: { [monitors] location, handler in monitors.make(location, handler) },
            makeFolderMonitor: { [monitors] folder, handler in monitors.makeFolder(folder, handler) }
        )
    }

    /// Services with a hub of their own.
    var services: GitHistoryServices {
        services(sharing: GitRepositoryHub(services: hubServices))
    }

    func services(sharing repositories: GitRepositoryHub, roots: GitRepositoryRoots? = nil) -> GitHistoryServices {
        GitHistoryServices(
            branches: { [self] root in branches(root) },
            logPage: { [self] root, scope, offset, limit in logPage(root, scope, offset, limit) },
            commitDetail: { [self] root, commit in detail(root, commit) },
            repositories: repositories,
            repositoryRoots: roots
        )
    }
}

final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []

    func record(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(value)
    }

    var values: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

/// `count` fake commits, newest first, SHAs `<prefix>-<n>` counting down.
func fakeCommits(_ count: Int, prefix: String = "c") -> [GitCommit] {
    (0..<count).reversed().map { index in
        GitCommit(
            sha: "\(prefix)-\(index)",
            parents: index == 0 ? [] : ["\(prefix)-\(index - 1)"],
            author: "Author",
            date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 60)),
            subject: "subject \(index)",
            refs: []
        )
    }
}

func localBranch(_ name: String) -> GitRef {
    GitRef(kind: .localBranch, name: name, fullName: "refs/heads/\(name)")
}

func remoteBranch(_ name: String) -> GitRef {
    GitRef(kind: .remoteBranch, name: name, fullName: "refs/remotes/\(name)")
}

/// Records every repository monitor the view model asks for, so a test can
/// fire a change and check that monitors are released.
final class FakeMonitors: @unchecked Sendable {
    final class Monitor: GitChangeMonitoring, @unchecked Sendable {
        /// The repository watched, or nil for a folder watched for a `.git`.
        let location: GitRepositoryLocation?
        let folder: String?
        let handler: @Sendable () -> Void
        private(set) var isStopped = false

        init(location: GitRepositoryLocation?, folder: String? = nil, handler: @escaping @Sendable () -> Void) {
            self.location = location
            self.folder = folder
            self.handler = handler
        }

        func stop() {
            isStopped = true
        }
    }

    private let lock = NSLock()
    private var created: [Monitor] = []

    func make(_ location: GitRepositoryLocation, _ handler: @escaping @Sendable () -> Void) -> Monitor {
        record(Monitor(location: location, handler: handler))
    }

    func makeFolder(_ folder: String, _ handler: @escaping @Sendable () -> Void) -> Monitor {
        record(Monitor(location: nil, folder: folder, handler: handler))
    }

    private func record(_ monitor: Monitor) -> Monitor {
        lock.lock(); defer { lock.unlock() }
        created.append(monitor)
        return monitor
    }

    var all: [Monitor] {
        lock.lock(); defer { lock.unlock() }
        return created
    }

    var active: [Monitor] { all.filter { !$0.isStopped } }
}

/// Scripted nested repositories per folder; every folder named in one
/// of them counts as a repository.
final class FakeNestedFinder: @unchecked Sendable {
    private let lock = NSLock()
    private var nested: [String: [String]] = [:]
    private var extraRepositories: Set<String> = []
    private var searches: [String] = []
    private var searchDelay: TimeInterval?

    /// Delays every search.
    func setSearchDelay(_ delay: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        searchDelay = delay
    }

    func set(_ repositories: [String], in folder: String) {
        lock.lock(); defer { lock.unlock() }
        nested[folder] = repositories
    }

    func addRepository(_ folder: String) {
        lock.lock(); defer { lock.unlock() }
        extraRepositories.insert(folder)
    }

    func repositories(in folder: String) -> [String] {
        if let delay = lockedSearchDelay { Thread.sleep(forTimeInterval: delay) }
        lock.lock(); defer { lock.unlock() }
        searches.append(folder)
        return nested[folder] ?? []
    }

    private var lockedSearchDelay: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return searchDelay
    }

    func isRepository(_ folder: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return extraRepositories.contains(folder) || nested.values.contains { $0.contains(folder) }
    }

    /// Resolver services served by this fake; paths are taken as real.
    var services: GitRepositoryRootsServices {
        GitRepositoryRootsServices(
            findNested: { [self] in repositories(in: $0) },
            isRepository: { [self] in isRepository($0) },
            canonical: { $0 }
        )
    }

    var searchedFolders: [String] {
        lock.lock(); defer { lock.unlock() }
        return searches
    }
}
