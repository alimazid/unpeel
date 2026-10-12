import Foundation
import XCTest

/// A throwaway git repository under the system temp dir, addressed by its
/// realpath. Setup commands run with a fixed identity and no user/system
/// config, so a developer's hooks, signing or aliases never leak into a
/// fixture; the code under test still runs git the way the app does.
struct GitTestRepo {
    let root: String

    /// A fresh directory; `init` runs `git init` in it unless told not to.
    init(initialize: Bool = true, branch: String = "main") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("unpeel-git-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let real = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        root = String(cString: real)
        if initialize {
            try git("init", "-q", "-b", branch)
        }
    }

    /// A repository at an explicit path (e.g. a bare `origin` or a clone).
    init(existing root: String) {
        self.root = root
    }

    func path(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    @discardableResult
    func write(_ relative: String, _ contents: String = "") throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.write(toFile: target, atomically: true, encoding: .utf8)
        return target
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: path(relative))
    }

    /// Commits everything in the working tree. `date` is a Unix timestamp
    /// used for both author and committer, so ordering tests are exact.
    @discardableResult
    func commit(_ message: String, date: Int? = nil, author: String = "Test Author") throws -> String {
        try git("add", "-A")
        var env: [String: String] = ["GIT_AUTHOR_NAME": author]
        if let date {
            env["GIT_AUTHOR_DATE"] = "@\(date) +0000"
            env["GIT_COMMITTER_DATE"] = "@\(date) +0000"
        }
        try git(["commit", "-q", "--allow-empty", "-m", message], environment: env)
        return try output("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try git(arguments)
    }

    @discardableResult
    func git(_ arguments: [String], environment extra: [String: String] = [:], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root] + arguments
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_AUTHOR_NAME"] = "Test Author"
        env["GIT_AUTHOR_EMAIL"] = "author@example.com"
        env["GIT_COMMITTER_NAME"] = "Test Committer"
        env["GIT_COMMITTER_EMAIL"] = "committer@example.com"
        env.merge(extra) { _, new in new }
        process.environment = env
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(errorText)")
            throw CocoaError(.executableLoad)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func output(_ arguments: String...) throws -> String {
        try git(arguments)
    }

    /// A bare repository next to this one, added as `origin`.
    func addBareOrigin() throws -> GitTestRepo {
        let bare = try GitTestRepo(initialize: false)
        try bare.git("init", "-q", "--bare", "-b", "main")
        try git("remote", "add", "origin", bare.root)
        return bare
    }

    func delete() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
