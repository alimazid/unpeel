import AppKit

/// Fork-only: explorer operations. The Draft Row: inserted into its folder's
/// rows (first among the folders for New Folder…, first among the files for
/// New File…) with an open name field.
extension ExplorerOutlineController {
    func applyDraft(_ draft: ExplorerDraft?) {
        guard draft != appliedDraft else { return }
        let previous = appliedDraft
        appliedDraft = draft
        if let previous {
            if nameEditingFolder == previous.folder, nameEditor?.purpose == .create { nameEditor?.cancel() }
            reloadRows(of: previous.folder)
        }
        guard let draft else { return }
        nameEditor?.cancel()
        reloadRows(of: draft.folder)
        // After this update pass: the row must exist before its field can
        // take focus.
        DispatchQueue.main.async { [weak self] in self?.beginDraftEditing(draft) }
    }

    func withDraftRow(_ entries: [ExplorerItem], in directory: String) -> [ExplorerItem] {
        guard let draft = appliedDraft, draft.folder == directory else { return entries }
        let row = item(for: draft.itemPath, role: .draft)
        let lastFolder = entries.lastIndex { applied?.entry(at: $0.path)?.kind == .directory }
        let index = draft.kind == .folder ? 0 : (lastFolder.map { $0 + 1 } ?? 0)
        var rows = entries
        rows.insert(row, at: index)
        return rows
    }

    func configureDraft(_ cell: ExplorerRowCellView) {
        let isFolder = appliedDraft?.kind == .folder
        cell.imageView?.image = NSWorkspace.shared.icon(for: isFolder ? .folder : .data)
        cell.textField?.lineBreakMode = .byTruncatingMiddle
        cell.textField?.stringValue = ""
        cell.restingTextColor = palette.text
    }

    func beginDraftEditing(_ draft: ExplorerDraft) {
        guard appliedDraft == draft, nameEditor == nil, let outlineView, let item = items[draft.itemPath] else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ExplorerRowCellView,
              let field = cell.textField
        else { return }
        let editor = ExplorerNameEditor(
            field: field,
            purpose: .create,
            isTaken: { Self.nameIsTaken($0, in: draft.folder) },
            onFinish: { [weak self] outcome in self?.finishDraft(draft, outcome) }
        )
        nameEditor = editor
        nameEditingFolder = draft.folder
        if !editor.begin(selecting: NSRange(location: 0, length: 0)) {
            endNameEditing()
            viewModel.cancelDraft()
        }
    }

    private func finishDraft(_ draft: ExplorerDraft, _ outcome: ExplorerNameEditor.Outcome) {
        endNameEditing()
        // A draft replaced or dropped meanwhile (another request, a root
        // change) is no longer the view model's to resolve.
        guard viewModel.draft == draft else { return }
        switch outcome {
        case .commit(let name): viewModel.commitDraft(name)
        case .cancel: viewModel.cancelDraft()
        }
    }
}
