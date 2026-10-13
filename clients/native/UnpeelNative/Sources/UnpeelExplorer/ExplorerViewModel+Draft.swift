import Foundation

/// Fork-only: explorer operations. New File… / New Folder…: a Draft Row in
/// the target folder whose committed name is created there. The new item is
/// selected and revealed, never opened.
extension ExplorerViewModel {
    /// Where a new item goes for these targets: a folder itself, a file's
    /// folder, or the root when there is no target.
    public func draftFolder(for targets: [String]) -> String? {
        guard let model else { return nil }
        guard let first = targets.first, let entry = model.entry(at: first) else { return model.root }
        return entry.kind == .directory && entry.isExpandable ? entry.path : FileTreeModel.parent(of: entry.path)
    }

    /// Shows a Draft Row in `folder`, expanding it first.
    @discardableResult
    public func beginDraft(_ kind: ExplorerDraft.Kind, in folder: String) -> Task<Void, Never> {
        guard let model, folder == model.root || model.entry(at: folder)?.isExpandable == true else {
            return Task {}
        }
        let current = generation
        return Task {
            if folder != model.root { await self.expand(folder).value }
            guard current == self.generation, self.model?.directories[folder] != nil else { return }
            self.draft = ExplorerDraft(folder: folder, kind: kind)
        }
    }

    public func cancelDraft() {
        guard draft != nil else { return }
        draft = nil
    }

    /// Creates the draft's item under `name` — a relative path creates the
    /// folders on the way.
    @discardableResult
    public func commitDraft(_ name: String) -> Task<Void, Never> {
        guard let draft else { return Task {} }
        self.draft = nil
        switch draft.kind {
        case .file: return createFile(name, in: draft.folder)
        case .folder: return createFolder(name, in: draft.folder)
        }
    }
}
