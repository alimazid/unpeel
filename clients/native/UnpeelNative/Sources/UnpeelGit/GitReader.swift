import Foundation

/// The git reader: everything Git History and the EXPLORER's Git Status
/// Decorations need from a repository, given an Explorer Root, as typed
/// results. Every read is one or two `GitRunner` processes and blocks, so
/// call it off the main thread. NUL-delimited output is used wherever a
/// path or free text can appear.
public struct GitReader: Sendable {
    private let runner: GitRunner

    public init(runner: GitRunner = .shared) {
        self.runner = runner
    }

    /// Every changed path under `root` and HEAD — the Checked-out Branch
    /// and its upstream counts — from one status read. Only
    /// `root`'s own subtree is read (paths stay relative to the work tree),
    /// and an untracked folder is listed once rather than file by file.
    /// Submodules are reported as `git status` reports them (the user's
    /// `ignoreSubmodules` settings apply), like any other folder content.
    public func status(at root: String) -> GitReadResult<GitStatus> {
        runner.run(
            .status,
            ["--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--", "."],
            in: root
        )
        .readResult()
        .map { GitStatus.parse(porcelainV2: $0.stdout) }
    }

    /// Where `root`'s repository lives and its status, as the repository
    /// views share them (`GitRepositoryHub`).
    public func snapshot(at root: String) -> GitReadResult<GitRepositorySnapshot> {
        repository(at: root).flatMap { location in
            status(at: root).map { GitRepositorySnapshot(location: location, status: $0) }
        }
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

    /// The work tree, git directory and common directory, canonicalised so
    /// they compare equal to paths FSEvents reports.
    public func repository(at root: String) -> GitReadResult<GitRepositoryLocation> {
        runner.run(
            .revParse,
            ["--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
            in: root
        )
        .readResult()
        .flatMap { output in
            let lines = output.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 3 else { return .failure(.failed("git rev-parse gave no repository paths")) }
            return .success(GitRepositoryLocation(
                workTree: Self.canonical(lines[0]),
                gitDirectory: Self.canonical(lines[1]),
                commonDirectory: Self.canonical(lines[2])
            ))
        }
    }

    /// The commit's full message and the files it changed against its
    /// first parent (everything is added in a root commit), with rename and
    /// copy detection.
    public func commitDetail(at root: String, commit: GitCommit) -> GitReadResult<GitCommitDetail> {
        let message = runner.run(.show, ["-s", "--no-show-signature", "--no-color", "--format=%B", commit.sha, "--"], in: root)
            .readResult()
            .map { $0.text.trimmingCharacters(in: .newlines) }
        let against = commit.parents.first.map { [$0, commit.sha] } ?? ["--root", commit.sha]
        let files = runner.run(.diffTree, ["-r", "-z", "--name-status", "-M", "-C", "--no-ext-diff"] + against + ["--"], in: root)
            .readResult()
            .map { GitChangedFile.parse(nameStatus: $0.stdout) }
        return message.flatMap { message in
            files.map { GitCommitDetail(sha: commit.sha, message: message, files: $0) }
        }
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
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
