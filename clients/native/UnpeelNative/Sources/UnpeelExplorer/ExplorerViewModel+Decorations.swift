import Foundation
import UnpeelGit

/// Fork-only: git support. The repository the EXPLORER's decorations follow:
/// the root as the hub shares its status under and the view's hold on it.
/// Each follow is a new value, so a read started for an earlier one can
/// tell it is stale.
struct FollowedRepository {
    /// The Explorer Root as the context names it.
    let explorerRoot: String
    /// The repository read: the Explorer Root, or (Fork-only: nested
    /// repositories) the nested repository chosen in it.
    let root: String
    let subscription: GitRepositorySubscription
    /// Fork-only: nested repositories. The hold on which repository the
    /// Explorer Root reads, when nested repositories are offered.
    let choice: GitRepositorySubscription?
    let id = UUID()
}

/// Fork-only: git support. Git Status Decorations: while a root is shown
/// its repository is followed through the shared `GitRepositoryHub`, and
/// the decorations are re-read (debounced) when the working tree changes,
/// when the repository changes (the hub's signal: a commit, checkout or
/// stage made outside Unpeel), or on Refresh. A non-repository or a Mac
/// without git simply has none — unless (Fork-only: nested repositories) a
/// nested repository is chosen in it through `GitRepositoryRoots`, whose
/// files, folder and the folders above it are then decorated; the tree
/// itself is never reloaded for a choice.
extension ExplorerViewModel {
    /// Follows `root`'s repository and reads its decorations right away.
    func startDecorations(root: String) -> Task<Void, Never> {
        guard services.repositories != nil else { return Task {} }
        let current = generation
        let choice = services.repositoryRoots?.subscribe(explorerRoot: root) { [weak self] in
            guard let self, current == self.generation else { return }
            self.scheduleDecorations(debounce: self.decorationDebounce)
        }
        followRepository(root, explorerRoot: root, choice: choice)
        return scheduleDecorations(debounce: 0)
    }

    /// Follows `root` through the hub for `explorerRoot`'s decorations.
    /// Nothing watched the working tree while the EXPLORER was closed (or
    /// followed another repository), so a read another view (Git History)
    /// kept meanwhile is not trusted.
    @discardableResult
    private func followRepository(
        _ root: String, explorerRoot: String, choice: GitRepositorySubscription?
    ) -> FollowedRepository? {
        guard let hub = services.repositories else { return nil }
        let current = generation
        followedRepository?.subscription.cancel()
        let subscription = hub.subscribe(root: root) { [weak self] in
            guard let self, current == self.generation else { return }
            self.scheduleDecorations(debounce: self.decorationDebounce)
        }
        let followed = FollowedRepository(explorerRoot: explorerRoot, root: root, subscription: subscription, choice: choice)
        followedRepository = followed
        hub.workingTreeDidChange(root: root)
        return followed
    }

    func stopDecorations() {
        followedRepository?.subscription.cancel()
        followedRepository?.choice?.cancel()
        followedRepository = nil
        decorationRefresh.reset()
        if repositoryState != nil { repositoryState = nil }
        if !decorations.isEmpty { decorations = .none }
    }

    /// Fork-only: nested repositories. The nested repository decorated, if
    /// one is.
    var nestedRepositoryRoot: String? {
        guard let followed = followedRepository, followed.root != followed.explorerRoot else { return nil }
        return followed.root
    }

    /// Whether a watcher batch can have changed the status of the
    /// repository at `root`. Its `.git` is the repository signal's to
    /// report — counting it here too would read the status twice for one
    /// commit — so a batch only inside it (and the folders holding a
    /// `.git`, which FSEvents names along with it) does not count; neither
    /// does one only outside the repository (Fork-only: nested
    /// repositories — the rest of the Explorer Root). A batch that lost
    /// events always does.
    static func touchesWorkingTree(_ change: FileSystemChange, root: String) -> Bool {
        if change.needsFullRescan { return true }
        let holdersOfDotGit = Set(change.directories
            .filter { ($0 as NSString).lastPathComponent == ".git" }
            .map { ($0 as NSString).deletingLastPathComponent })
        let prefix = root + "/"
        return change.directories.contains { path in
            (path == root || path.hasPrefix(prefix))
                && !ExplorerPaths.isInsideDotGit(path, root: root) && !holdersOfDotGit.contains(path)
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
    /// current one: not after the root changed, failed, or was closed, nor
    /// after another repository was chosen.
    @discardableResult
    func scheduleDecorations(debounce: TimeInterval) -> Task<Void, Never> {
        guard let hub = services.repositories, followedRepository != nil else { return Task {} }
        return decorationRefresh.request(debounce: debounce) { [weak self] in
            guard let followed = self?.followedRepository,
                  let target = await self?.resolveRepository(for: followed)
            else { return }
            let result = await hub.status(root: target.root)
            guard let self, self.followedRepository?.id == target.id else { return }
            self.show(result)
        }
    }

    /// Fork-only: nested repositories. The repository the Explorer Root
    /// reads now, followed through the hub when it changed; nil when the
    /// follow ended meanwhile.
    private func resolveRepository(for followed: FollowedRepository) async -> FollowedRepository? {
        guard let roots = services.repositoryRoots else { return followed }
        let state = await roots.resolve(explorerRoot: followed.explorerRoot)
        guard let current = followedRepository, current.id == followed.id else { return nil }
        if state != repositoryState { repositoryState = state }
        guard state.repositoryRoot != current.root else { return current }
        return followRepository(state.repositoryRoot, explorerRoot: current.explorerRoot, choice: current.choice)
    }

    private func show(_ result: GitReadResult<GitRepositorySnapshot>) {
        let next: GitDecorations
        switch result {
        case .success(let snapshot):
            next = GitDecorations(snapshot: snapshot, shownFrom: model?.root)
        case .failure(.notARepository), .failure(.gitUnavailable):
            next = .none
        case .failure(.failed(let message)):
            Self.logger.error("git status failed; no decorations: \(message, privacy: .public)")
            next = .none
        }
        if next != decorations { decorations = next }
    }

    // MARK: - Nested repositories

    /// Fork-only: nested repositories. Whether the folder at `path` can be
    /// made the repository the git views read: a repository inside an
    /// Explorer Root that is not one, other than the one in use.
    public func canUseAsGitRepository(_ path: String) -> Bool {
        guard let state = repositoryState, state.canChoose, state.chosen != path,
              model?.entry(at: path)?.kind == .directory
        else { return false }
        return GitNestedRepositoryFinder.isRepository(path)
    }

    /// Fork-only: nested repositories. Makes the repository at `path` the
    /// one the decorations and Git History read, and remembers it.
    @discardableResult
    public func useAsGitRepository(_ path: String) -> Task<Void, Never> {
        guard canUseAsGitRepository(path), let roots = services.repositoryRoots, let followed = followedRepository,
              roots.choose(path, in: followed.explorerRoot)
        else { return Task {} }
        // Choosing told every follower, this one included; the user is
        // waiting, so this one reads now rather than after the debounce.
        decorationRefresh.reset()
        return scheduleDecorations(debounce: 0)
    }

    /// Fork-only: nested repositories. Searches an Explorer Root that is
    /// not a repository for nested ones again (Refresh). A repository has
    /// none to find, and its other views are not disturbed.
    func searchForRepositoriesAgain() {
        guard let followed = followedRepository, repositoryState?.folder == .notARepository else { return }
        services.repositoryRoots?.invalidate(followed.explorerRoot)
    }
}
