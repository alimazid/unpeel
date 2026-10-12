import UnpeelGit

/// Fork-only: git support. The one hub the app's repository views share,
/// reading with the shared runner. Lives here rather than in `UnpeelGit`
/// because the FSEvents watcher it will use does.
extension GitRepositoryHub {
    public static let shared = GitRepositoryHub(services: .reading(GitReader()))
}
