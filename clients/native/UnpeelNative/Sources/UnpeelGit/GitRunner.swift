import Foundation
import os

/// What one git process produced.
public struct GitOutput: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public init(status: Int32, stdout: Data, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum GitRunOutcome: Sendable, Equatable {
    /// No runnable `git` on this Mac; nothing was spawned.
    case unavailable
    case finished(GitOutput)
}

/// The one way Unpeel runs git: read commands only (`GitReadCommand`), in a
/// given directory, with `GIT_OPTIONAL_LOCKS=0` so a `status` never takes
/// the index lock an agent's `git commit` needs, `GIT_TERMINAL_PROMPT=0`
/// so nothing can block on a credential prompt, and `GIT_NO_LAZY_FETCH=1`
/// so a partial clone's missing contents are never fetched into the
/// repository (git 2.44 and later). `git` is located once per
/// runner; when it cannot be found or launched, every later call returns
/// `.unavailable` without spawning a process. Blocking: call it off the
/// main thread.
public final class GitRunner: @unchecked Sendable {
    public static let shared = GitRunner(resolver: .system)

    private static let logger = Logger(subsystem: "com.unpeel.git", category: "runner")
    /// Repository overrides an inherited environment could carry; any of
    /// them would aim every read at the wrong repository whatever `-C` says.
    private static let strippedVariables: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES",
    ]

    private enum Resolution {
        case unresolved
        case available(URL)
        case unavailable
    }

    private let resolver: GitExecutableResolver
    private let lock = NSLock()
    private var resolution = Resolution.unresolved

    public init(resolver: GitExecutableResolver) {
        self.resolver = resolver
    }

    /// Whether git can currently be run (resolving it if not yet done).
    var isAvailable: Bool { executable() != nil }

    static func environment(base: [String: String]) -> [String: String] {
        var environment = base.filter { !strippedVariables.contains($0.key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // A read that needs contents a partial clone lacks fails instead of
        // fetching them: a fetch writes to the repository.
        environment["GIT_NO_LAZY_FETCH"] = "1"
        // Untranslated messages: "not a git repository" is recognised by
        // its text. Output with paths or messages is NUL-delimited bytes,
        // which the locale does not touch.
        environment["LC_ALL"] = "C"
        return environment
    }

    public func run(
        _ command: GitReadCommand,
        _ arguments: [String],
        in directory: String,
        input: Data? = nil
    ) -> GitRunOutcome {
        guard let git = executable() else { return .unavailable }
        let process = Process()
        process.executableURL = git
        process.arguments = ["-C", directory, "--no-pager", command.rawValue] + arguments
        process.environment = Self.environment(base: ProcessInfo.processInfo.environment)
        let output = Pipe()
        let errors = Pipe()
        let stdin = input.map { _ in Pipe() }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Self.logger.error("git could not launch: \(error.localizedDescription, privacy: .public)")
            markUnavailable()
            return .unavailable
        }
        // Feed stdin and drain stderr on other threads: git streams results
        // while it reads, so doing either inline would deadlock once a pipe
        // buffer fills.
        let group = DispatchGroup()
        if let input, let writer = stdin?.fileHandleForWriting {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                Self.write(input, to: writer, command: command)
            }
        }
        let errorBox = ErrorTextBox()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            errorBox.text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return .finished(GitOutput(status: process.terminationStatus, stdout: data, stderr: errorBox.text))
    }

    private static func write(_ input: Data, to writer: FileHandle, command: GitReadCommand) {
        do {
            try writer.write(contentsOf: input)
        } catch {
            // git exited before reading everything (e.g. not a repository);
            // its exit status already tells the caller what went wrong.
            logger.error("git \(command.rawValue, privacy: .public) stdin write failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try writer.close()
        } catch {
            logger.error("git \(command.rawValue, privacy: .public) stdin close failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func executable() -> URL? {
        lock.lock(); defer { lock.unlock() }
        switch resolution {
        case .available(let url):
            return url
        case .unavailable:
            return nil
        case .unresolved:
            if let url = resolver.resolve() {
                resolution = .available(url)
                return url
            }
            resolution = .unavailable
            return nil
        }
    }

    private func markUnavailable() {
        lock.lock(); defer { lock.unlock() }
        resolution = .unavailable
    }
}

/// Written once by the stderr drain before `group.wait()` returns.
private final class ErrorTextBox: @unchecked Sendable {
    var text = ""
}
