import Foundation

/// Fork-only: explorer operations. File Operations as the EXPLORER performs
/// them: one at a time, off the main actor, each recorded in its Explorer
/// Root's Operation History and shown at once — the result selected and
/// revealed, any failure in the message strip.
extension ExplorerViewModel {
    // MARK: - Operations

    @discardableResult
    public func createFile(_ relativePath: String, in folder: String) -> Task<Void, Never> {
        record { $0.createFile(relativePath, in: folder) }
    }

    @discardableResult
    public func createFolder(_ relativePath: String, in folder: String) -> Task<Void, Never> {
        record { $0.createFolder(relativePath, in: folder) }
    }

    @discardableResult
    public func rename(_ path: String, to name: String) -> Task<Void, Never> {
        record { $0.rename(path, to: name) }
    }

    /// `kind` names the history step when it is not a plain Move (a paste).
    /// A move to another volume that copies a lot runs as a Transfer.
    @discardableResult
    public func move(
        _ paths: [String], into folder: String, resolutions: [String: CollisionResolution] = [:],
        as kind: FileOperationKind? = nil
    ) -> Task<Void, Never> {
        transfer(paths, into: folder, kind: .move, resolutions: resolutions, named: kind)
    }

    /// A copy over `ExplorerServices.largeTransfer` runs as a Transfer: the
    /// returned task ends when it has been put in place or given up.
    @discardableResult
    public func copy(
        _ paths: [String], into folder: String, resolutions: [String: CollisionResolution] = [:],
        as kind: FileOperationKind? = nil
    ) -> Task<Void, Never> {
        transfer(paths, into: folder, kind: .copy, resolutions: resolutions, named: kind)
    }

    /// Which of `paths` already have a namesake in `folder` and so need the
    /// Collision Prompt's answer.
    public func collidingSources(_ paths: [String], into folder: String) -> [String] {
        guard let root = model?.root, let operations = services.makeOperations(root) else { return [] }
        return operations.collidingSources(paths, into: folder)
    }

    @discardableResult
    public func duplicate(_ paths: [String]) -> Task<Void, Never> {
        record { $0.duplicate(paths) }
    }

    /// Moves `paths` to the Trash at once — no confirmation; ⌘Z puts them
    /// back. `next` is selected afterwards (VS Code selects the row after
    /// the removed ones).
    @discardableResult
    public func trash(_ paths: [String], thenSelect next: String? = nil) -> Task<Void, Never> {
        record(selectingWhenEmpty: next.map { [$0] } ?? []) { $0.trash(paths) }
    }

    // MARK: - Undo and redo

    /// "Undo <operation>" for the current root, nil when there is nothing.
    public var undoActionTitle: String? {
        currentHistory?.nextUndo.map { "Undo \($0.kind.title)" }
    }

    public var redoActionTitle: String? {
        currentHistory?.nextRedo.map { "Redo \($0.kind.title)" }
    }

    @discardableResult
    public func undo() -> Task<Void, Never> {
        enqueue { root, operations in
            guard let record = self.histories[root]?.nextUndo else { return nil }
            let outcome = await Self.detached { operations.reverse(record) }
            self.histories[root] = self.histories[root]?.undone(replacement: outcome.record)
            return outcome
        }
    }

    @discardableResult
    public func redo() -> Task<Void, Never> {
        enqueue { root, operations in
            guard let record = self.histories[root]?.nextRedo else { return nil }
            let outcome = await Self.detached { operations.reverse(record) }
            self.histories[root] = self.histories[root]?.redone(replacement: outcome.record)
            return outcome
        }
    }

    public func dismissOperationMessage() {
        operationMessage = nil
    }

    // MARK: - Running

    private var currentHistory: OperationHistory? {
        model.flatMap { histories[$0.root] }
    }

    /// A new operation: run, then pushed onto its root's history. When it
    /// leaves nothing to select (a trash), `fallback` is selected instead.
    private func record(
        selectingWhenEmpty fallback: [String] = [],
        _ work: @escaping @Sendable (FileOperations) -> FileOperationOutcome
    ) -> Task<Void, Never> {
        enqueue(selectingWhenEmpty: fallback) { root, operations in
            let outcome = await Self.detached { work(operations) }
            self.push(outcome.record, root: root)
            return outcome
        }
    }

    func push(_ record: FileOperationRecord?, root: String) {
        guard let record else { return }
        histories[root] = (histories[root] ?? OperationHistory()).recording(record)
    }

    /// Runs `body` after every operation asked for before it, against the
    /// root shown when it was asked for.
    func enqueue(
        selectingWhenEmpty fallback: [String] = [],
        _ body: @escaping @MainActor (String, FileOperations) async -> FileOperationOutcome?
    ) -> Task<Void, Never> {
        guard let root = model?.root else { return Task {} }
        guard let operations = services.makeOperations(root) else {
            operationMessage = ExplorerError.rootUnavailable(root).localizedDescription
            return Task {}
        }
        return enqueue(root: root, operations: operations, selectingWhenEmpty: fallback, body)
    }

    /// Runs `body` against `root` after every operation asked for before
    /// it. The history is updated even if the root changed meanwhile — the
    /// files did change — but the result is only shown while that root
    /// still is.
    func enqueue(
        root: String, operations: FileOperations, selectingWhenEmpty fallback: [String] = [],
        _ body: @escaping @MainActor (String, FileOperations) async -> FileOperationOutcome?
    ) -> Task<Void, Never> {
        let current = generation
        let previous = operationTail
        let task = Task { @MainActor in
            await previous?.value
            guard let outcome = await body(root, operations) else { return }
            await self.show(outcome, root: root, generation: current, fallback: fallback)
        }
        operationTail = task
        return task
    }

    static func detached<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    // MARK: - Showing

    private func show(
        _ outcome: FileOperationOutcome, root: String, generation current: Int, fallback: [String]
    ) async {
        guard current == generation, model?.root == root else { return }
        operationMessage = Self.message(for: outcome.failures)
        guard let record = outcome.record else { return }
        let effects = Self.effects(of: record.steps, root: root)
        await reloadAfterOperation(changedFolders: effects.folders, relocations: effects.relocations).value
        guard current == generation else { return }
        await revealAll(record.resultPaths.isEmpty ? fallback : record.resultPaths)
        guard current == generation else { return }
        persistState()
    }

    /// The first failure, and how many more there were.
    static func message(for failures: [FileOperationFailure]) -> String? {
        guard let first = failures.first?.localizedDescription else { return nil }
        return failures.count > 1 ? "\(first) (and \(failures.count - 1) more)" : first
    }

    /// The folders inside `root` whose listings a record's steps changed,
    /// and the items it moved.
    static func effects(
        of steps: [FileOperationStep], root: String
    ) -> (folders: Set<String>, relocations: [(from: String, to: String)]) {
        var folders: Set<String> = []
        var relocations: [(from: String, to: String)] = []
        for step in steps {
            switch step {
            case let .created(path, _, _):
                folders.insert(FileTreeModel.parent(of: path))
            case let .moved(from, to, _):
                folders.formUnion([FileTreeModel.parent(of: from), FileTreeModel.parent(of: to)])
                relocations.append((from, to))
            case let .trashed(original, _, _, _):
                folders.insert(FileTreeModel.parent(of: original))
            }
        }
        return (folders.filter { $0 == root || $0.hasPrefix(root + "/") }, relocations)
    }

    /// Expands the folders holding `paths` and selects the ones that are
    /// still there.
    func revealAll(_ paths: [String]) async {
        guard let root = model?.root else { return }
        let current = generation
        let ancestors = Set(paths.flatMap { Self.ancestors(of: $0, root: root) })
        for folder in ancestors.sorted(by: { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }) {
            guard current == generation else { return }
            await expand(folder).value
        }
        guard current == generation, let model else { return }
        revealToken += 1
        selection = paths.filter { model.entry(at: $0) != nil }
    }

    private static func ancestors(of path: String, root: String) -> [String] {
        guard path.hasPrefix(root + "/") else { return [] }
        var folders: [String] = []
        var folder = FileTreeModel.parent(of: path)
        while folder != root, folder.count > root.count {
            folders.append(folder)
            folder = FileTreeModel.parent(of: folder)
        }
        return folders
    }
}
