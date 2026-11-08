import AppKit
import UnpeelShared
@testable import UnpeelNative

extension UnpeelStore {
    /// A store running as a client of a fixture Host (the shipped Local
    /// path) in the bundle's private home (`TestHomeIsolationTests`), its
    /// sidebar tree projected from `snapshot`. No step may run a Host verb:
    /// with no Host behind the fixture it fails, and the failure opens a
    /// modal NSAlert that blocks the test run.
    @MainActor
    static func sidebarFixture(
        snapshot: RemoteBootstrapSnapshot,
        expandedProjectIDs: Set<String>
    ) -> UnpeelStore {
        // Scope switches set NSApp.appearance.
        _ = NSApplication.shared
        let panes = PaneLayoutController(
            fileURL: LaunchConfig.unpeelDir
                .appendingPathComponent("panes-\(UUID().uuidString.prefix(6)).json")
        )
        let store = UnpeelStore(paneLayoutController: panes)
        if !store.isExperimentalEnabled(.worktrees) {
            store.setExperimental(true, for: .worktrees)
        }
        store.markLocalHostClientStartedForTesting()
        // The store's runtime subscription delivers the runtime's initial
        // nil snapshot on the next main-queue turn, and that projection
        // clears the tree. Let it land before projecting the fixture, so a
        // test that runs the run loop keeps its rows.
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        store.expandedProjectIDs = expandedProjectIDs
        store.projectRemoteScope(snapshot: snapshot)
        return store
    }
}
