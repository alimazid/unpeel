import Foundation

/// Commit detail: one expanded commit at a time, read once per commit.
extension GitHistoryViewModel {
    private static let detailCacheLimit = 64

    /// Expands `sha` in place (collapsing any other commit), or collapses it
    /// when it is the expanded one.
    @discardableResult
    public func toggleExpanded(_ sha: String) -> Task<Void, Never> {
        if expanded?.sha == sha {
            expanded = nil
            return Task {}
        }
        return expand(sha)
    }

    @discardableResult
    public func expand(_ sha: String) -> Task<Void, Never> {
        guard expanded?.sha != sha, let root, let commit = commits.first(where: { $0.sha == sha }) else {
            return Task {}
        }
        if let cached = detailCache[sha] {
            expanded = GitExpandedCommit(sha: sha, state: .loaded(cached))
            return Task {}
        }
        expanded = GitExpandedCommit(sha: sha, state: .loading)
        let current = generation
        let readDetail = services.commitDetail
        return Task {
            let result = await Task.detached(priority: .userInitiated) { readDetail(root, commit) }.value
            guard current == self.generation, self.expanded?.sha == sha else { return }
            switch result {
            case .success(let detail):
                self.remember(detail)
                self.expanded = GitExpandedCommit(sha: sha, state: .loaded(detail))
            case .failure(let failure):
                self.expanded = GitExpandedCommit(sha: sha, state: .failed(GitHistoryStatus(failure).message ?? ""))
            }
        }
    }

    public func collapse() {
        expanded = nil
    }

    private func remember(_ detail: GitCommitDetail) {
        if detailCache.count >= Self.detailCacheLimit { detailCache.removeAll(keepingCapacity: true) }
        detailCache[detail.sha] = detail
    }

    /// The changed file's absolute path in the working tree, or nil when it
    /// no longer exists there as a file (deleted, renamed away, now a
    /// folder) — old commits stay browsable without errors.
    public func workTreePath(for file: GitChangedFile) -> String? {
        // git never reports `..` components; refusing them keeps a path
        // from ever resolving outside the work tree.
        guard let workTree = location?.workTree, !file.path.hasPrefix("/"),
              !file.path.split(separator: "/").contains("..")
        else { return nil }
        let path = (workTree as NSString).appendingPathComponent(file.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return path
    }
}
