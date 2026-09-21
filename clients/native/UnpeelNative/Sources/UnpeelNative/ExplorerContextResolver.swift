//
//  ExplorerContextResolver.swift
//  UnpeelNative
//
//  Pure mapping from "what is selected" to what the explorer should show.
//

import Foundation
import UnpeelExplorer

enum ExplorerContextResolver {
    /// The explorer root is the session's worktree when it has one, else its
    /// project folder, else the pane's working directory. Remote scopes never
    /// resolve: their paths live on another machine.
    static func resolve(
        isLocalScope: Bool,
        hasSession: Bool,
        worktreePath: String?,
        projectPath: String?,
        fallbackDirectory: String?
    ) -> ExplorerContext {
        guard isLocalScope else { return .remote }
        guard hasSession else { return .none }
        let project = nonBlank(projectPath)
        guard let root = nonBlank(worktreePath) ?? project ?? nonBlank(fallbackDirectory) else {
            return .none
        }
        return .local(root: root, projectRoot: project ?? root)
    }

    /// What gets pasted into the agent's prompt for `path`: relative to the
    /// explorer root (the agent's checkout) when inside it, else absolute.
    static func agentReference(for path: String, root: String) -> String {
        ExplorerPaths.relative(path, to: root)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
