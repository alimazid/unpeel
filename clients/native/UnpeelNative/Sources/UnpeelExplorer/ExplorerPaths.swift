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
}
