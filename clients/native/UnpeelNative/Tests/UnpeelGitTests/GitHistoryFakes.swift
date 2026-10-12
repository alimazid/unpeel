import Foundation
@testable import UnpeelGit

/// Scripted reader results per root, with optional per-root delays, so a
/// test controls exactly what each read returns and when. Every read is
/// recorded in order.
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
    private var branchLists: [String: [GitRef]] = [:]
    private var locations: [String: GitRepositoryLocation] = [:]
    private var details: [String: GitReadResult<GitCommitDetail>] = [:]
    private var detailDelays: [String: TimeInterval] = [:]
    private var detailReads: [String] = []
    private var delays: [String: TimeInterval] = [:]
    private var logDelays: [String: TimeInterval] = [:]
    private var headReads: [String] = []
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
        locked { branchLists[root] = refs }
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

    var headReadRoots: [String] { locked { headReads } }
    var logCalls: [LogCall] { locked { logReads } }

    private func pause(_ delay: TimeInterval?) {
        if let delay { Thread.sleep(forTimeInterval: delay) }
    }

    func head(_ root: String) -> GitReadResult<GitHead> {
        pause(locked { delays[root] })
        return locked {
            headReads.append(root)
            return heads[root] ?? .failure(.notARepository)
        }
    }

    func branches(_ root: String) -> GitReadResult<[GitRef]> {
        pause(locked { delays[root] })
        return locked { .success(branchLists[root] ?? []) }
    }

    func repository(_ root: String) -> GitReadResult<GitRepositoryLocation> {
        locked {
            .success(locations[root] ?? GitRepositoryLocation(
                workTree: root, gitDirectory: root + "/.git", commonDirectory: root + "/.git"
            ))
        }
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

    var services: GitHistoryServices {
        GitHistoryServices(
            head: { [self] root in head(root) },
            branches: { [self] root in branches(root) },
            repository: { [self] root in repository(root) },
            logPage: { [self] root, scope, offset, limit in logPage(root, scope, offset, limit) },
            commitDetail: { [self] root, commit in detail(root, commit) }
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
