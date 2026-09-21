import AppKit

/// `NSOutlineView` tracks expansion and selection by item identity, so each
/// path maps to one long-lived object rather than a fresh value per reload.
public final class ExplorerItem: NSObject {
    public enum Role: Equatable {
        case entry
        /// A non-interactive line: a load failure or "… N more items".
        case note(String)
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
