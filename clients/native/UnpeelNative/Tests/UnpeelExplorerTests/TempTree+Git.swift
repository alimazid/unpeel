import Foundation
import XCTest

/// Fork-only: git support. Setup commands for a `TempTree` that is a git
/// repository, run with a fixed identity and no user or system config.
extension TempTree {
    @discardableResult
    func git(_ arguments: String..., in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory ?? root] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment[key] = nil }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "T"; environment["GIT_AUTHOR_EMAIL"] = "t@example.com"
        environment["GIT_COMMITTER_NAME"] = "T"; environment["GIT_COMMITTER_EMAIL"] = "t@example.com"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(errorText)")
            throw CocoaError(.executableLoad)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `git init` plus a first commit of whatever the tree holds.
    func initRepository(commitMessage: String = "first") throws {
        try git("init", "-q", "-b", "main")
        try git("add", "-A")
        try git("commit", "-q", "--allow-empty", "-m", commitMessage)
    }
}
