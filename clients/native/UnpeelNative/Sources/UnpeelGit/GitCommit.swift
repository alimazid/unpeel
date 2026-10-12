import Foundation

/// A ref shown as a label on the commit it points to.
public struct GitRefLabel: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// HEAD itself: on the Checked-out Branch's tip, or a detached commit.
        case head
        case localBranch
        case remoteBranch
        case tag
    }

    public let kind: Kind
    /// The short name: `main`, `origin/main`, `v1.0`, or `HEAD`.
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// Parses `git log --decorate=full --format=%D`: comma-separated full
    /// ref names (`HEAD -> refs/heads/main`, `tag: refs/tags/v1`, …). Ref
    /// names cannot contain spaces, so ", " is a safe separator. A remote's
    /// `HEAD` symref and anything outside branches and tags (stash, notes)
    /// is dropped.
    public static func parse(decoration: String) -> [GitRefLabel] {
        decoration
            .components(separatedBy: ", ")
            .flatMap { token -> [GitRefLabel] in
                if token == "HEAD" { return [GitRefLabel(kind: .head, name: "HEAD")] }
                if token.hasPrefix("HEAD -> ") {
                    return [GitRefLabel(kind: .head, name: "HEAD")]
                        + label(forRef: String(token.dropFirst("HEAD -> ".count)))
                }
                if token.hasPrefix("tag: ") {
                    return label(forRef: String(token.dropFirst("tag: ".count)))
                }
                return label(forRef: token)
            }
    }

    private static func label(forRef ref: String) -> [GitRefLabel] {
        if let name = ref.dropping(prefix: "refs/heads/") {
            return [GitRefLabel(kind: .localBranch, name: name)]
        }
        if let name = ref.dropping(prefix: "refs/tags/") {
            return [GitRefLabel(kind: .tag, name: name)]
        }
        if let name = ref.dropping(prefix: "refs/remotes/"), !name.hasSuffix("/HEAD") {
            return [GitRefLabel(kind: .remoteBranch, name: name)]
        }
        return []
    }
}

/// One commit as Git History lists it.
public struct GitCommit: Equatable, Sendable, Identifiable {
    public let sha: String
    public let parents: [String]
    public let author: String
    /// The author date.
    public let date: Date
    /// The first line of the message.
    public let subject: String
    public let refs: [GitRefLabel]

    public init(sha: String, parents: [String], author: String, date: Date, subject: String, refs: [GitRefLabel]) {
        self.sha = sha
        self.parents = parents
        self.author = author
        self.date = date
        self.subject = subject
        self.refs = refs
    }

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(GitHead.shortSHALength)) }
    /// The commit HEAD points to.
    public var isHead: Bool { refs.contains { $0.kind == .head } }
    public var isMerge: Bool { parents.count > 1 }
}

/// Which commits the log lists.
public enum GitLogScope: Hashable, Sendable {
    /// HEAD: the Checked-out Branch, or the detached commit's history.
    case head
    /// One branch by its full ref name (`refs/heads/x`, `refs/remotes/o/x`).
    case ref(String)
    /// Every local and remote-tracking branch (and HEAD), by date.
    case allBranches
}

/// One page of the log. `hasMore` is exact: the reader asks for one commit
/// beyond the page.
public struct GitLogPage: Equatable, Sendable {
    public let commits: [GitCommit]
    public let hasMore: Bool

    public init(commits: [GitCommit], hasMore: Bool) {
        self.commits = commits
        self.hasMore = hasMore
    }
}

extension String {
    func dropping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
