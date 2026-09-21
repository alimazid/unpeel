import Foundation

public enum ExplorerPaths {
    /// `path` relative to `base` when beneath it; otherwise `path` unchanged.
    public static func relative(_ path: String, to base: String) -> String {
        if path == base { return "." }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    public static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    /// True when `path` is a `.git` directory below `root`, or lies inside
    /// one. The single place the "`.git` is never listed" invariant is
    /// decided: row rendering merely filters, while `expand`/`reveal` must
    /// refuse outright, or `.git` is scanned into the model and persisted
    /// into the saved expansion set. Only components BELOW the root count,
    /// so a root that is itself inside a `.git` directory still lists its
    /// own contents.
    public static func isInsideDotGit(_ path: String, root: String) -> Bool {
        relative(path, to: root).split(separator: "/").contains(".git")
    }
}
