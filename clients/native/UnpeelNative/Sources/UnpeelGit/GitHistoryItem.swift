import AppKit

/// `NSOutlineView` tracks expansion and selection by item identity, so each
/// row maps to one long-lived object keyed by what it shows.
final class GitHistoryItem: NSObject {
    enum Role: Hashable {
        case commit(sha: String)
        /// The expanded commit's full message.
        case message(sha: String)
        /// One changed file of the expanded commit, by its index.
        case file(sha: String, index: Int)
    }

    let role: Role

    init(_ role: Role) {
        self.role = role
    }

    var sha: String {
        switch role {
        case .commit(let sha), .message(let sha), .file(let sha, _): return sha
        }
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? GitHistoryItem)?.role == role
    }

    override var hash: Int { role.hashValue }
}
