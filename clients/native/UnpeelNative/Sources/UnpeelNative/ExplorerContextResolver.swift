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

    /// Which session's pane a user-facing action (Send Path to Agent) should
    /// target. `selectedSessionID` alone names the pane GROUP's
    /// representative session — in a split, `UnpeelStore` rewrites selection
    /// to that representative and routes pane-level intent through focus
    /// instead (see `UnpeelStore.selectedSessionID`'s setter) — so it is
    /// never the exact pane the user is looking at within a split. The
    /// focused pane wins when a group is focused; the last-focused solo/panel
    /// pane is next (groups clear `activePane`, so this is what the focus
    /// border keys on for those); the plain selection is the final fallback.
    static func targetSessionID(
        activePane: String?,
        focusedSolo: String?,
        selected: String?
    ) -> String? {
        activePane ?? focusedSolo ?? selected
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
