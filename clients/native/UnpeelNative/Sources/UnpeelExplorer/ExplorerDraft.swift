import Foundation

/// Fork-only: explorer operations. A pending New File… or New Folder…: the
/// Draft Row shown at the top of `folder`'s files (or folders) until its
/// name is committed or cancelled. Each request is a new draft, even in the
/// same folder, so asking again restarts the field.
public struct ExplorerDraft: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file, folder
    }

    public let folder: String
    public let kind: Kind
    let id = UUID()

    public init(folder: String, kind: Kind) {
        self.folder = folder
        self.kind = kind
    }

    /// The Draft Row's identity in the outline; never a real path.
    var itemPath: String { folder + "/\u{0}draft" }
}
