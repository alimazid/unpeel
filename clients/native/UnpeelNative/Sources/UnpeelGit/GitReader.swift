import Foundation

/// The git reader: everything Git History (and later the EXPLORER's
/// decorations) needs from a repository, given an Explorer Root, as typed
/// results. Every read is one or two `GitRunner` processes and blocks, so
/// call it off the main thread. NUL-delimited output is used wherever a
/// path or free text can appear.
public struct GitReader: Sendable {
    private let runner: GitRunner

    public init(runner: GitRunner = .shared) {
        self.runner = runner
    }

    /// The Checked-out Branch and its upstream counts, from the porcelain v2
    /// branch headers. Untracked files are skipped: only the headers are
    /// read here.
    public func head(at root: String) -> GitReadResult<GitHead> {
        runner.run(
            .status,
            ["--porcelain=v2", "--branch", "-z", "--untracked-files=no", "--ignore-submodules=all"],
            in: root
        )
        .readResult()
        .map { GitHead.parse(porcelainV2: $0.stdout) }
    }

    /// Local branches, then remote-tracking branches, each in name order
    /// (sorting full names puts `refs/heads/` before `refs/remotes/`). Ref
    /// names cannot contain a newline, so records are newline-separated.
    public func branches(at root: String) -> GitReadResult<[GitRef]> {
        runner.run(
            .forEachRef,
            ["--sort=refname", "--format=%(refname)%00%(symref)", "refs/heads", "refs/remotes"],
            in: root
        )
        .readResult()
        .map { output in
            output.text.split(separator: "\n").compactMap(GitRef.parse(record:))
        }
    }

    /// Fields of one log record, NUL-separated; `-z` ends each record with
    /// another NUL. The subject is last and never contains a NUL.
    private static let logFormat = "--format=%H%x00%P%x00%aN%x00%at%x00%D%x00%s"
    private static let logFieldCount = 6

    /// Up to `limit` commits of `scope` after skipping `offset`, newest
    /// first. One extra commit is requested so `hasMore` is exact.
    public func logPage(at root: String, scope: GitLogScope, offset: Int, limit: Int) -> GitReadResult<GitLogPage> {
        let revisions: [String]
        switch scope {
        case .head: revisions = ["HEAD"]
        case .ref(let name): revisions = [name]
        case .allBranches: revisions = ["--date-order", "--branches", "--remotes", "HEAD"]
        }
        let arguments = [
            "-z", "--no-color", "--no-show-signature", "--decorate=full", Self.logFormat,
            "--skip=\(max(0, offset))", "--max-count=\(max(0, limit) + 1)",
        ] + revisions + ["--"]
        return runner.run(.log, arguments, in: root)
            .readResult()
            .map { Self.parseLog($0.stdout, limit: limit) }
    }

    static func parseLog(_ data: Data, limit: Int) -> GitLogPage {
        var fields = data
            .split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // The trailing record terminator leaves one empty field behind.
        if fields.count % logFieldCount == 1, fields.last == "" { fields.removeLast() }
        let commits = stride(from: 0, to: fields.count - logFieldCount + 1, by: logFieldCount).map { start in
            let record = fields[start..<(start + logFieldCount)].map { $0 }
            return GitCommit(
                sha: record[0],
                parents: record[1].split(separator: " ").map(String.init),
                author: record[2],
                date: Date(timeIntervalSince1970: TimeInterval(record[3]) ?? 0),
                subject: record[5],
                refs: GitRefLabel.parse(decoration: record[4])
            )
        }
        return GitLogPage(commits: Array(commits.prefix(limit)), hasMore: commits.count > limit)
    }
}
