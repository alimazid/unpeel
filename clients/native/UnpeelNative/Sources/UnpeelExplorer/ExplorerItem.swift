import AppKit

/// `NSOutlineView` tracks expansion and selection by item identity, so each
/// path maps to one long-lived object rather than a fresh value per reload.
public final class ExplorerItem: NSObject {
    public enum Role: Equatable {
        case entry
        /// A non-interactive line: a load failure or "… N more items".
        /// Carries no text itself — `ExplorerOutlineController.noteText`
        /// derives the current text live from the model, so a directory's
        /// note row keeps one stable identity even as its message changes
        /// (e.g. the truncated count growing) rather than losing identity
        /// each time the text does.
        case note
        /// Fork-only: explorer operations. The Draft Row of a New File… or
        /// New Folder… (`ExplorerDraft`).
        case draft
    }

    public let path: String
    public let role: Role

    public init(path: String, role: Role) {
        self.path = path
        self.role = role
    }

    public override func isEqual(_ object: Any?) -> Bool {
        (object as? ExplorerItem)?.path == path
    }

    public override var hash: Int { path.hashValue }
}
