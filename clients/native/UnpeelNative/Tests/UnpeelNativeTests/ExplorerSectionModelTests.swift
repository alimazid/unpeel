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

    // MARK: - Fork-only: git support (#9)

    /// A changed file clicked in Git History while the EXPLORER is
    /// collapsed or hidden is revealed the next time its tree opens.
    func testARevealWhileTheTreeIsNotShownIsAppliedWhenItOpens() async throws {
        let (model, suite) = makeModel()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let root = try makeTree(["a/b/c.txt", "d.txt"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let target = root + "/a/b/c.txt"

        model.reveal(target)
        XCTAssertEqual(model.viewModel.selection, [])

        model.claim(UUID())
        await model.open(.local(root: root, projectRoot: root)).value

        XCTAssertEqual(model.viewModel.selection, [target])
        XCTAssertEqual(model.viewModel.model?.expanded, [root + "/a", root + "/a/b"])
    }

    /// While the tree is showing the reveal happens at once and nothing is
    /// left over for a later open.
    func testARevealWhileTheTreeIsShownHappensNow() async throws {
        let (model, suite) = makeModel()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let root = try makeTree(["a/c.txt", "d.txt"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let host = UUID()
        model.claim(host)
        await model.open(.local(root: root, projectRoot: root)).value

        await model.reveal(root + "/a/c.txt").value
        XCTAssertEqual(model.viewModel.selection, [root + "/a/c.txt"])
        model.viewModel.selection = [root + "/d.txt"]

        _ = model.release(host)
        await model.open(.none).value
        model.claim(UUID())
        await model.open(.local(root: root, projectRoot: root)).value
        XCTAssertEqual(model.viewModel.selection, [root + "/d.txt"], "the tree's own saved selection, nothing else")
    }

    private func makeTree(_ files: [String]) throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("unpeel-reveal-\(UUID().uuidString)")
        for file in files {
            let url = base.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        guard let real = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        return String(cString: real)
    }
}
