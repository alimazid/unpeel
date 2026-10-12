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
            logPage: { [self] root, scope, offset, limit in logPage(root, scope, offset, limit) }
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
