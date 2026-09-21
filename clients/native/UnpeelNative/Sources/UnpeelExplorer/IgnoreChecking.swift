import Foundation
import os

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

/// One `git check-ignore -z --stdin` process per call. Exit status 0 = some
/// ignored, 1 = none ignored, anything else (128 = not a repository) = treat
/// as none.
public struct GitIgnoreChecker: IgnoreChecking {
    private static let logger = Logger(subsystem: "com.unpeel.explorer", category: "ignore")

    public init() {}

    public func ignoredPaths(among paths: [String], root: String) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root, "check-ignore", "-z", "--stdin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Self.logger.error("git check-ignore could not start: \(error.localizedDescription, privacy: .public)")
            return []
        }
        // Feed stdin from another thread: git streams results while it reads,
        // so writing everything first would deadlock once a pipe fills.
        let payload = Data(paths.joined(separator: "\0").utf8) + Data([0])
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let returned = data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
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
