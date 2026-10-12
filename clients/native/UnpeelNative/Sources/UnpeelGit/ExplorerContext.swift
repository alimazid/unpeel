import Foundation

/// What the EXPLORER and Git History show: the selected Session's Explorer
/// Root (its worktree if it has one, otherwise its Project's root), or why
/// there is none. Derived by the app, shared by both views.
public enum ExplorerContext: Sendable, Equatable {
    /// No session is selected.
    case none
    /// The selected session runs on another Host; its files are not local.
    case remote
    case local(root: String, projectRoot: String)
}
