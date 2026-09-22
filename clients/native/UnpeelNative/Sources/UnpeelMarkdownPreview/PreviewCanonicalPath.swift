import Foundation

/// `realpath(3)`: resolves symlinks and `..`. Never `URL.resolvingSymlinksInPath()`,
/// which strips `/private` and would disagree with FSEvents paths.
enum PreviewCanonicalPath {
    static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
