import Foundation
import UnpeelGit

/// Fork-only: git support. Git Status Decorations: while a root is shown
/// its repository is followed through the shared `GitRepositoryHub`, and
/// the decorations are re-read (debounced) when the working tree changes,
/// when the repository changes (the hub's signal: a commit, checkout or
/// stage made outside Unpeel), or on Refresh. A non-repository or a Mac
/// without git simply has none.
extension ExplorerViewModel {
    /// How long a change waits for more before the decorations are re-read.
    public nonisolated static let defaultDecorationDebounce: TimeInterval = 0.2

    /// Follows `root`'s repository and reads its decorations right away.
    func startDecorations(root: String) -> Task<Void, Never> {
        guard let hub = services.repositories else { return Task {} }
        let current = generation
        repositorySubscription = hub.subscribe(root: root) { [weak self] in
            guard let self, current == self.generation else { return }
            self.scheduleDecorations(debounce: self.decorationDebounce)
        }
        decorationsRoot = root
        return scheduleDecorations(debounce: 0)
    }

    /// Whether a watcher batch can have changed the status. The root's own
    /// `.git` is the repository signal's to report — counting it here too
    /// would read the status twice for one commit — so a batch only inside
    /// it (and the folders holding a `.git`, which FSEvents names along
    /// with it) does not count. A batch that lost events always does.
    static func touchesWorkingTree(_ change: FileSystemChange, root: String) -> Bool {
        if change.needsFullRescan { return true }
        let holdersOfDotGit = Set(change.directories
            .filter { ($0 as NSString).lastPathComponent == ".git" }
            .map { ($0 as NSString).deletingLastPathComponent })
        return change.directories.contains { path in
            !ExplorerPaths.isInsideDotGit(path, root: root) && !holdersOfDotGit.contains(path)
        }
    }

    func stopDecorations() {
        repositorySubscription?.cancel()
        repositorySubscription = nil
        decorationsRoot = nil
        decorationsPending = false
        decorationTask = nil
        if !decorations.isEmpty { decorations = .none }
    }

    /// Files under the root changed: the shared status is stale, and the
    /// decorations are re-read once the burst settles.
    func workingTreeDidChange() -> Task<Void, Never> {
        guard let hub = services.repositories, let root = decorationsRoot else { return Task {} }
        hub.workingTreeDidChange(root: root)
        return scheduleDecorations(debounce: decorationDebounce)
    }

    /// One loop serves every request: a request while it waits or reads
    /// costs at most one more read, never one per request.
    @discardableResult
    func scheduleDecorations(debounce: TimeInterval) -> Task<Void, Never> {
        guard let hub = services.repositories, let root = decorationsRoot else { return Task {} }
        decorationsPending = true
        if let decorationTask { return decorationTask }
        let current = generation
        let task = Task {
            if debounce > 0 { try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000)) }
            while self.decorationsPending, current == self.generation {
                self.decorationsPending = false
                let result = await hub.status(root: root)
                guard current == self.generation else { return }
                self.show(result)
            }
            if current == self.generation { self.decorationTask = nil }
        }
        decorationTask = task
        return task
    }

    private func show(_ result: GitReadResult<GitRepositorySnapshot>) {
        let next: GitDecorations
        switch result {
        case .success(let snapshot):
            next = GitDecorations(snapshot: snapshot)
        case .failure(.notARepository), .failure(.gitUnavailable):
            next = .none
        case .failure(.failed(let message)):
            Self.logger.error("git status failed; no decorations: \(message, privacy: .public)")
            next = .none
        }
        if next != decorations { decorations = next }
    }
}
