import AppKit

/// Fork-only: explorer operations. Duplicate, Cut, Copy and Paste through
/// the general pasteboard's file URLs, so Finder interoperates both ways.
/// A cut is remembered with the pasteboard's change count: its rows are
/// dimmed until it is pasted once or something else is copied.
extension ExplorerOutlineController {
    struct CutState: Equatable {
        let paths: [String]
        let changeCount: Int
    }

    var clipboardActions: [MenuAction?] {
        [.cut, .copy, .paste, .duplicate, nil]
    }

    // MARK: - Writing

    func copyItems(_ paths: [String], cutting: Bool) {
        let targets = paths.filter { applied?.entry(at: $0) != nil }
        guard !targets.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(targets.map { NSURL(fileURLWithPath: $0) })
        cutState = cutting ? CutState(paths: targets, changeCount: pasteboard.changeCount) : nil
        refreshCutRows()
    }

    /// Whether `path` is cut and waiting to be pasted.
    func isCut(_ path: String) -> Bool {
        guard let cutState, cutState.changeCount == pasteboard.changeCount else { return false }
        return cutState.paths.contains(path)
    }

    // MARK: - Pasting

    /// Files on the pasteboard, or nothing — a cut that was already pasted
    /// once is not pasted again.
    var pasteableFiles: [String] {
        guard pasteboard.changeCount != consumedChangeCount else { return [] }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (urls as? [URL])?.map(\.path) ?? []
    }

    /// Pastes into the folder `targets` point at: a folder, a file's folder,
    /// or the root. Our own cut moves; anything else copies.
    func paste(into targets: [String]) {
        let files = pasteableFiles
        guard !files.isEmpty, let folder = viewModel.draftFolder(for: targets) else { return }
        let moving = cutState.map { $0.changeCount == pasteboard.changeCount && $0.paths == files } ?? false
        if moving {
            consumedChangeCount = pasteboard.changeCount
            cutState = nil
            refreshCutRows()
        }
        transfer(files, into: folder, copying: !moving, as: .paste)
    }

    func duplicate(_ paths: [String]) {
        let targets = paths.filter { applied?.entry(at: $0) != nil }
        guard !targets.isEmpty else { return }
        viewModel.duplicate(targets)
    }

    /// Asks the Collision Prompt about every name already in `folder`, then
    /// moves or copies. The answers are collected before anything changes.
    @discardableResult
    func transfer(_ paths: [String], into folder: String, copying: Bool, as kind: FileOperationKind) -> Task<Void, Never> {
        let collisions = viewModel.collidingSources(paths, into: folder)
        guard !collisions.isEmpty else {
            return copying
                ? viewModel.copy(paths, into: folder, as: kind)
                : viewModel.move(paths, into: folder, as: kind)
        }
        let prompt = collisionPrompt ?? AlertCollisionPrompt(window: outlineView?.window)
        let asking = Task { @MainActor in
            var resolutions: [String: CollisionResolution] = [:]
            var forAll: CollisionResolution?
            for (index, source) in collisions.enumerated() {
                if let forAll {
                    resolutions[source] = forAll
                    continue
                }
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: source, isDirectory: &isFolder)
                let answer = await prompt.answer(
                    forExisting: (source as NSString).lastPathComponent, isFolder: isFolder.boolValue,
                    copying: copying, remaining: collisions.count - index - 1
                )
                resolutions[source] = answer.resolution
                if answer.appliesToAll { forAll = answer.resolution }
            }
            let task = copying
                ? viewModel.copy(paths, into: folder, resolutions: resolutions, as: kind)
                : viewModel.move(paths, into: folder, resolutions: resolutions, as: kind)
            await task.value
        }
        pendingTransfer = asking
        return asking
    }

    // MARK: - Dimming

    func refreshCutRows() {
        outlineView?.enumerateAvailableRowViews { rowView, row in
            guard let item = self.outlineView?.item(atRow: row) as? ExplorerItem, item.role == .entry,
                  let cell = rowView.view(atColumn: 0) as? ExplorerRowCellView,
                  cell.textField !== self.nameEditor?.field
            else { return }
            self.configure(cell, for: item)
        }
    }
}
