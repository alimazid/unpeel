import Foundation
import UnpeelGit

/// Fork-only: git support. Git Status Decorations: while a root is shown
/// its repository is followed through the shared `GitRepositoryHub`, and
/// the decorations are re-read (debounced) when the working tree changes or
/// on Refresh. A non-repository or a Mac without git simply has none.
extension ExplorerViewModel {
    /// How long a change waits for more before the decorations are re-read.
    public nonisolated static let defaultDecorationDebounce: TimeInterval = 0.2

    /// Follows `root`'s repository and reads its decorations right away.
    func startDecorations(root: String) -> Task<Void, Never> {
        guard let hub = services.repositories else { return Task {} }
        repositorySubscription = hub.subscribe(root: root)
        decorationsRoot = root
        return scheduleDecorations(debounce: 0)
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
