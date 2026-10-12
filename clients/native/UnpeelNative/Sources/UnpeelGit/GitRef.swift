import Foundation

/// A branch the History Branch Filter can choose.
public struct GitRef: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case localBranch
        case remoteBranch
    }

    public let kind: Kind
    /// The short name: `main`, `origin/main`.
    public let name: String
    /// The full ref name: `refs/heads/main`, `refs/remotes/origin/main`.
    public let fullName: String

    public init(kind: Kind, name: String, fullName: String) {
        self.kind = kind
        self.name = name
        self.fullName = fullName
    }

    public var id: String { fullName }

    /// The branch a full ref name names, or nil for anything that is not a
    /// branch: tags, stash, notes, and a remote's `HEAD` symref.
    init?(fullName: String) {
        if let name = fullName.dropping(prefix: "refs/heads/") {
            self.init(kind: .localBranch, name: name, fullName: fullName)
        } else if let name = fullName.dropping(prefix: "refs/remotes/"), !name.hasSuffix("/HEAD") {
            self.init(kind: .remoteBranch, name: name, fullName: fullName)
        } else {
            return nil
        }
    }

    /// One `for-each-ref` record: full name, NUL, symref target (empty for
    /// a real branch). Symrefs are not branches of their own.
    static func parse(record: Substring) -> GitRef? {
        let fields = record.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard let fullName = fields.first, fields.dropFirst().first?.isEmpty ?? true else { return nil }
        return GitRef(fullName: fullName)
    }
}
