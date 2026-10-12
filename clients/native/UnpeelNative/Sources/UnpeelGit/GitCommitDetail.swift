import Foundation

/// One file a commit changed. Paths are relative to the repository's work
/// tree; a rename or copy keeps its source in `oldPath`.
public struct GitChangedFile: Hashable, Sendable {
    public let kind: GitChangeKind
    public let path: String
    public let oldPath: String?

    public init(kind: GitChangeKind, path: String, oldPath: String? = nil) {
        self.kind = kind
        self.path = path
        self.oldPath = oldPath
    }

    /// Parses `git diff-tree -r -z --name-status`: a status field, then one
    /// path, or two (source, destination) for a rename or copy.
    static func parse(nameStatus data: Data) -> [GitChangedFile] {
        let fields = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var files: [GitChangedFile] = []
        var index = 0
        while index < fields.count {
            let status = fields[index][...]
            index += 1
            guard let kind = GitChangeKind(nameStatus: status) else { continue }
            if kind == .renamed || kind == .copied {
                guard index + 1 < fields.count else { break }
                files.append(GitChangedFile(kind: kind, path: fields[index + 1], oldPath: fields[index]))
                index += 2
            } else {
                guard index < fields.count else { break }
                files.append(GitChangedFile(kind: kind, path: fields[index]))
                index += 1
            }
        }
        return files
    }
}

/// What an expanded commit shows: its full message and changed files.
public struct GitCommitDetail: Equatable, Sendable {
    public let sha: String
    public let message: String
    public let files: [GitChangedFile]

    public init(sha: String, message: String, files: [GitChangedFile]) {
        self.sha = sha
        self.message = message
        self.files = files
    }
}

/// Where a repository lives on disk, all absolute. For a linked worktree
/// `gitDirectory` is the worktree's own (its HEAD and index) and
/// `commonDirectory` the main repository's (refs, packed-refs).
public struct GitRepositoryLocation: Equatable, Sendable {
    public let workTree: String
    public let gitDirectory: String
    public let commonDirectory: String

    public init(workTree: String, gitDirectory: String, commonDirectory: String) {
        self.workTree = workTree
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
    }
}

/// The one commit Git History has expanded, and how far its detail got.
public struct GitExpandedCommit: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case loading
        case loaded(GitCommitDetail)
        case failed(String)
    }

    public let sha: String
    public let state: State

    public init(sha: String, state: State) {
        self.sha = sha
        self.state = state
    }
}
