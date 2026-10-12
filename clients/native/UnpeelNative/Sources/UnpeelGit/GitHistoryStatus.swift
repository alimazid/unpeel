import Foundation

/// What Git History can show for the current Explorer Root.
public enum GitHistoryStatus: Equatable, Sendable {
    /// No Session is selected.
    case noSession
    /// The selected Session runs on another Host.
    case remote
    /// The first read for this Explorer Root has not finished. Shown blank:
    /// a "Loading…" flash on every Session switch would be noise.
    case loading
    case notARepository
    case gitUnavailable
    /// A repository whose branch has no commits yet (`git init` only).
    case noCommits
    case failed(String)
    case ready

    /// The empty-state sentence, or nil when there is no message to show.
    /// The first two match the EXPLORER's wording.
    public var message: String? {
        switch self {
        case .noSession: return "Select a session to browse its history."
        case .remote: return "Git History is available for sessions running on this Mac."
        case .notARepository: return "This folder is not a git repository."
        case .gitUnavailable:
            return "git was not found on this Mac. Install the Command Line Tools (xcode-select --install) to see history."
        case .noCommits: return "No commits yet."
        case .failed(let message): return message
        case .loading, .ready: return nil
        }
    }

    init(_ failure: GitReadFailure) {
        switch failure {
        case .gitUnavailable: self = .gitUnavailable
        case .notARepository: self = .notARepository
        case .failed(let message): self = .failed(message)
        }
    }
}
