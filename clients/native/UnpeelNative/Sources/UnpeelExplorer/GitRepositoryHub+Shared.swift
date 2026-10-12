import UnpeelGit

/// Fork-only: git support. The hub the app's repository views share: reads
/// with the shared runner and watches with the EXPLORER's FSEvents watcher
/// (`GitRepositoryMonitor`), which is why it lives here, not in `UnpeelGit`.
extension GitRepositoryHub {
    public static let shared = GitRepositoryHub(services: .live)
}

extension GitRepositoryHubServices {
    public static let live = GitRepositoryHubServices.reading(
        GitReader(),
        makeMonitor: GitRepositoryMonitor.make,
        makeFolderMonitor: GitRepositoryMonitor.makeFolder
    )
}
