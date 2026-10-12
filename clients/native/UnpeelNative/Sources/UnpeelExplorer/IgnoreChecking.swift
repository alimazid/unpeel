import Foundation
import UnpeelGit

public protocol IgnoreChecking: Sendable {
    /// The subset of `paths` that git ignores. Empty when `root` is not in a
    /// repository or git is unavailable — ignoring is never a reason to fail
    /// a listing.
    func ignoredPaths(among paths: [String], root: String) -> Set<String>
}

public struct NoIgnoreChecker: IgnoreChecking {
    public init() {}
    public func ignoredPaths(among _: [String], root _: String) -> Set<String> { [] }
}

/// One `git check-ignore -z --stdin` process per call, through the shared
/// read-only `GitRunner` (so a Mac without git spawns nothing after the
/// first lookup). Exit status 0 = some ignored, 1 = none ignored, anything
/// else (128 = not a repository) = treat as none.
public struct GitIgnoreChecker: IgnoreChecking {
    private let runner: GitRunner

    public init(runner: GitRunner = .shared) {
        self.runner = runner
    }

    public func ignoredPaths(among paths: [String], root: String) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let payload = Data(paths.joined(separator: "\0").utf8) + Data([0])
        guard case .finished(let output) = runner.run(.checkIgnore, ["-z", "--stdin"], in: root, input: payload),
              output.status == 0
        else { return [] }
        let returned = output.stdout.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
        // git echoes directories back with a trailing slash even though the
        // input had none; the contract with callers is that returned paths
        // are string-equal to the inputs, so normalise before matching.
        let inputs = Set(paths)
        let ignored = returned.map { path -> String in
            guard !inputs.contains(path), path.hasSuffix("/") else { return path }
            let trimmed = String(path.dropLast())
            return inputs.contains(trimmed) ? trimmed : path
        }
        return Set(ignored).intersection(inputs)
    }
}
