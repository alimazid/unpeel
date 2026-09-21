import Foundation

/// realpath(3)-based canonicalisation. FSEvents reports real paths
/// (`/private/var/…`) while `URL.resolvingSymlinksInPath()` strips `/private`,
/// so every path the explorer compares goes through here.
public enum CanonicalPath {
    public static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `path` resolves to `root` or to something beneath it.
    public static func isInside(_ path: String, root: String) -> Bool {
        guard let resolvedPath = resolve(path), let resolvedRoot = resolve(root) else {
            return false
        }
        if resolvedPath == resolvedRoot { return true }
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolvedPath.hasPrefix(prefix)
    }
}
