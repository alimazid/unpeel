import Foundation

/// Where HEAD is in the Explorer Root's working tree: the Checked-out
/// Branch (or a detached commit) and how it compares with its upstream as
/// of the last fetch. Nothing here ever fetches.
public struct GitHead: Equatable, Sendable {
    /// The commit HEAD points to; nil while the branch has no commits yet.
    public let oid: String?
    /// The Checked-out Branch; nil when HEAD is detached.
    public let branch: String?
    /// The upstream's short name (e.g. `origin/main`), when configured.
    public let upstream: String?
    /// Commits on the branch not on its upstream; nil without a usable
    /// upstream (none configured, or configured but gone), so "nothing to
    /// push" is never claimed falsely.
    public let ahead: Int?
    public let behind: Int?

    public init(oid: String?, branch: String?, upstream: String? = nil, ahead: Int? = nil, behind: Int? = nil) {
        self.oid = oid
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    /// The same length the worktree sidebar uses for its marker.
    public static let shortSHALength = 12

    public var isDetached: Bool { branch == nil }
    public var hasCommits: Bool { oid != nil }

    /// The branch name, or `detached@<short-sha>` — the marker worktrees
    /// already use for a detached checkout.
    public var displayName: String {
        if let branch { return branch }
        return "detached@\((oid ?? "").prefix(Self.shortSHALength))"
    }

    /// Reads the `# branch.*` headers of `git status --porcelain=v2
    /// --branch -z`; entry records (anything else) are ignored.
    public static func parse(porcelainV2 data: Data) -> GitHead {
        var oid: String?
        var branch: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        for record in data.split(separator: 0) {
            let line = String(decoding: record, as: UTF8.self)
            guard line.hasPrefix("# branch.") else { continue }
            let parts = line.dropFirst("# branch.".count).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "oid":
                oid = value == "(initial)" ? nil : value
            case "head":
                branch = value == "(detached)" ? nil : value
            case "upstream":
                upstream = value
            case "ab":
                let counts = value.split(separator: " ")
                ahead = counts.first.flatMap { Int($0.dropFirst()) }
                behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) }
            default:
                continue
            }
        }
        return GitHead(oid: oid, branch: branch, upstream: upstream, ahead: ahead, behind: behind)
    }
}
