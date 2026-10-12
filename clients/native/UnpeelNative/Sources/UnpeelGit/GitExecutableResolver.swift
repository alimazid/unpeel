import Foundation
import os

/// Finds the `git` binary to run. `GitRunner` asks exactly once per runner
/// and remembers the answer, including "none".
public struct GitExecutableResolver: Sendable {
    public let resolve: @Sendable () -> URL?

    public init(resolve: @escaping @Sendable () -> URL?) {
        self.resolve = resolve
    }

    private static let logger = Logger(subsystem: "com.unpeel.git", category: "resolver")

    /// A concrete, runnable binary, or nil. `/usr/bin/git` is avoided: on a
    /// Mac without the developer tools it is a shim that opens the "install
    /// command line developer tools" dialog instead of running. Order: a
    /// `git` on `PATH` or in Homebrew's prefixes, then the active developer
    /// directory's own binary (`xcode-select -p`), which is what the shim
    /// would run anyway. The winner must answer `git --version`.
    public static let system = GitExecutableResolver {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = environmentPath.split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        let candidates = directories
            .filter { $0 != "/usr/bin" }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("git") }
            + [developerDirectoryGit()].compactMap { $0 }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            if answersVersion(candidate) { return candidate }
        }
        logger.info("no runnable git found; git features are off for this launch")
        return nil
    }

    private static func developerDirectoryGit() -> URL? {
        guard let output = runQuietly(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"]),
              output.status == 0
        else { return nil }
        let directory = String(decoding: output.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }
        return URL(fileURLWithPath: directory).appendingPathComponent("usr/bin/git")
    }

    private static func answersVersion(_ git: URL) -> Bool {
        runQuietly(git, ["--version"])?.status == 0
    }

    private static func runQuietly(_ executable: URL, _ arguments: [String]) -> (status: Int32, stdout: Data)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("could not run \(executable.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
