import Foundation

/// A directory listing with git-ignore state applied. Ignore rules are
/// re-evaluated on every scan, so there is no cache to invalidate; a changed
/// `.gitignore` is handled by rescanning (see `ExplorerViewModel`).
public struct DirectoryScanner: Sendable {
    private let loader: DirectoryLoader
    private let ignore: any IgnoreChecking

    public init(loader: DirectoryLoader = DirectoryLoader(), ignore: any IgnoreChecking = GitIgnoreChecker()) {
        self.loader = loader
        self.ignore = ignore
    }

    public func scan(directory: String, root: String) throws -> DirectoryListing {
        let listing = try loader.load(directory: directory, root: root)
        let ignored = ignore.ignoredPaths(among: listing.entries.map(\.path), root: root)
        guard !ignored.isEmpty else { return listing }
        return DirectoryListing(
            entries: listing.entries.map { $0.with(isIgnored: ignored.contains($0.path)) },
            truncatedCount: listing.truncatedCount
        )
    }
}
