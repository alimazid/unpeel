import Foundation

/// Why a read produced no value. Distinct outcomes rather than thrown
/// errors, so each view can show its own empty state.
public enum GitReadFailure: Error, Equatable, Sendable {
    /// No runnable `git` on this Mac.
    case gitUnavailable
    /// The folder is not inside a git work tree.
    case notARepository
    /// git ran and refused; the first line of what it said.
    case failed(String)
}

public typealias GitReadResult<Value> = Result<Value, GitReadFailure>

extension GitRunOutcome {
    /// The output of a successful run, or the read failure it amounts to.
    func readResult() -> GitReadResult<GitOutput> {
        guard case .finished(let output) = self else { return .failure(.gitUnavailable) }
        guard output.status != 0 else { return .success(output) }
        if output.stderr.contains("not a git repository") {
            return .failure(.notARepository)
        }
        let firstLine = output.stderr
            .split(separator: "\n")
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return .failure(.failed(firstLine ?? "git exited with status \(output.status)"))
    }
}
