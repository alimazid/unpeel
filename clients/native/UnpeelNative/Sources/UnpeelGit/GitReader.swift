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
}
