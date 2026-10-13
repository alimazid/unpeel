import Foundation
import UnpeelGit

/// Fork-only: git support. The repository the EXPLORER's decorations follow:
/// the root as the context names it (the key its status is shared under in
/// `GitRepositoryHub`) and the view's hold on it. Each follow is a new
/// value, so a read started for an earlier one can tell it is stale.
struct FollowedRepository {
    let root: String
    let subscription: GitRepositorySubscription
    let id = UUID()
}

/// Fork-only: git support. Git Status Decorations: while a root is shown
/// its repository is followed through the shared `GitRepositoryHub`, and
/// the decorations are re-read (debounced) when the working tree changes,
/// when the repository changes (the hub's signal: a commit, checkout or
/// stage made outside Unpeel), or on Refresh. A non-repository or a Mac
/// without git simply has none.
extension ExplorerViewModel {
    /// Follows `root`'s repository and reads its decorations right away.
    /// Nothing watched the working tree while the EXPLORER was closed, so a
    /// read another view (Git History) kept meanwhile is not trusted.
    func startDecorations(root: String) -> Task<Void, Never> {
        guard let hub = services.repositories else { return Task {} }
        let current = generation
        let subscription = hub.subscribe(root: root) { [weak self] in
            guard let self, current == self.generation else { return }
            self.scheduleDecorations(debounce: self.decorationDebounce)
        }
        followedRepository = FollowedRepository(root: root, subscription: subscription)
        hub.workingTreeDidChange(root: root)
        return scheduleDecorations(debounce: 0)
    }

    func stopDecorations() {
        followedRepository?.subscription.cancel()
        followedRepository = nil
        decorationRefresh.reset()
        if !decorations.isEmpty { decorations = .none }
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

    /// Files under the root changed: the shared status is stale, and the
    /// decorations are re-read once the burst settles.
    func workingTreeDidChange() -> Task<Void, Never> {
        guard let hub = services.repositories, let followed = followedRepository else { return Task {} }
        hub.workingTreeDidChange(root: followed.root)
        return scheduleDecorations(debounce: decorationDebounce)
    }

    /// A read is shown only while the follow it was made for is still the
    /// current one: not after the root changed, failed, or was closed.
    @discardableResult
    func scheduleDecorations(debounce: TimeInterval) -> Task<Void, Never> {
        guard let hub = services.repositories, let followed = followedRepository else { return Task {} }
        return decorationRefresh.request(debounce: debounce) { [weak self] in
            let result = await hub.status(root: followed.root)
            guard let self, self.followedRepository?.id == followed.id else { return }
            self.show(result)
        }
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
