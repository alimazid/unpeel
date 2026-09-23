import XCTest
@testable import UnpeelNative

@MainActor
final class ExplorerSectionModelTests: XCTestCase {
    private func makeModel() -> (ExplorerSectionModel, String) {
        let suite = "unpeel.explorer.sectionmodeltests.\(UUID().uuidString)"
        return (ExplorerSectionModel(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    /// Reproduces the SwiftUI ordering that motivated this: a new host's
    /// `onAppear` (claim B) can land before an old host's `onDisappear`
    /// (release A) when the view's identity changes. Only the still-active
    /// claim's release may report that teardown should happen.
    func testOnlyTheStillActiveHostMayTearDown() {
        let (model, suite) = makeModel()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let hostA = UUID()
        let hostB = UUID()

        model.claim(hostA)
        model.claim(hostB)

        XCTAssertFalse(model.release(hostA), "a superseded host's release must not trigger teardown")
        XCTAssertTrue(model.release(hostB), "the still-active host's release must trigger teardown")
    }

    func testReleaseIsNotRepeatable() {
        let (model, suite) = makeModel()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let host = UUID()
        model.claim(host)

        XCTAssertTrue(model.release(host))
        XCTAssertFalse(model.release(host), "a second release of the same token must not re-trigger teardown")
    }
}
