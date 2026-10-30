import Foundation

/// Fork-only: nested repositories. Finds the git repositories inside a
/// folder that is not one: every folder holding a `.git` (a repository's
/// folder, or a worktree's link file), up to `maxDepth` levels down. A
/// repository's own contents are not searched further, and hidden folders,
/// `node_modules`, packages, symbolic links and privacy-protected folders
/// (looking inside Documents or Desktop would ask the user for access out
/// of nowhere) are passed over. Shallow folders are searched first, so
/// stopping at `limit` keeps the nearest repositories. Reads the disk:
/// call it off the main thread.
public struct GitNestedRepositoryFinder: Sendable {
    public static let defaultDepth = 2
    public static let defaultLimit = 50
    private static let skippedNames: Set<String> = ["node_modules"]

    private let maxDepth: Int
    private let limit: Int
    private let protectedFolders: Set<String>

    public init(
        maxDepth: Int = GitNestedRepositoryFinder.defaultDepth,
        limit: Int = GitNestedRepositoryFinder.defaultLimit,
        protectedFolders: Set<String> = GitNestedRepositoryFinder.privacyProtectedFolders
    ) {
        self.maxDepth = max(1, maxDepth)
        self.limit = max(1, limit)
        self.protectedFolders = protectedFolders
    }

    /// The user's folders macOS guards with a privacy prompt, as real paths.
    public static var privacyProtectedFolders: Set<String> {
        let directories: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .documentDirectory, .downloadsDirectory,
            .moviesDirectory, .musicDirectory, .picturesDirectory, .libraryDirectory,
        ]
        let urls = directories.flatMap { FileManager.default.urls(for: $0, in: .userDomainMask) }
        return Set(urls.map { GitPath.canonical($0.path) })
    }

    /// Whether `folder` holds a `.git` folder or file.
    public static func isRepository(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git"))
    }

    /// The repositories found, as absolute paths ordered by their path
    /// within `folder`.
    public func repositories(in folder: String) -> [String] {
        var found: [String] = []
        var level = [folder]
        for _ in 0..<maxDepth where !level.isEmpty && found.count < limit {
            var next: [String] = []
            for child in level.flatMap(subfolders(of:)) {
                guard found.count < limit else { break }
                if Self.isRepository(child) { found.append(child) } else { next.append(child) }
            }
            level = next
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]

    private func subfolders(of folder: String) -> [String] {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: Set(Self.keys)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  values.isPackage != true, values.isHidden != true,
                  !Self.skippedNames.contains(child.lastPathComponent)
            else { return nil }
            let path = (folder as NSString).appendingPathComponent(child.lastPathComponent)
            return protectedFolders.contains(path) ? nil : path
        }
    }
}

/// Fork-only: nested repositories. Paths as git and FSEvents report them.
enum GitPath {
    /// `path` with symbolic links resolved, or unchanged when it cannot be.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
