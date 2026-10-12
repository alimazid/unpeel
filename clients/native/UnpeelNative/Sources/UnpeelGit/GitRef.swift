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

    /// One `for-each-ref` record: full name, NUL, symref target (empty for
    /// a real branch). Symrefs (`origin/HEAD`) are not branches of their
    /// own and are dropped.
    static func parse(record: Substring) -> GitRef? {
        let fields = record.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard let fullName = fields.first, fields.dropFirst().first?.isEmpty ?? true else { return nil }
        if let name = fullName.dropping(prefix: "refs/heads/") {
            return GitRef(kind: .localBranch, name: name, fullName: fullName)
        }
        if let name = fullName.dropping(prefix: "refs/remotes/"), !name.hasSuffix("/HEAD") {
            return GitRef(kind: .remoteBranch, name: name, fullName: fullName)
        }
        return nil
    }
}
