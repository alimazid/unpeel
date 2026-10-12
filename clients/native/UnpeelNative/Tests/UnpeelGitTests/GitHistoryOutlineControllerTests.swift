import AppKit
import XCTest
@testable import UnpeelGit

@MainActor
final class GitHistoryOutlineControllerTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("unpeel.git.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    private func commit(
        _ sha: String,
        subject: String = "subject",
        author: String = "Ada",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        parents: [String] = ["p"],
        refs: [GitRefLabel] = []
    ) -> GitCommit {
        GitCommit(sha: sha, parents: parents, author: author, date: date, subject: subject, refs: refs)
    }

    private func makeController(
        commits: [GitCommit],
        hasMore: Bool = false,
        services: GitHistoryServices? = nil
    ) async -> (GitHistoryOutlineController, GitHistoryNSOutlineView, NSScrollView) {
        let fake = FakeGitHistory()
        fake.setHead(.success(GitHead(oid: commits.first?.sha, branch: "main")), for: "/repo")
        fake.setCommits(commits, for: "/repo")
        let viewModel = GitHistoryViewModel(services: services ?? fake.services, pageSize: max(1, commits.count))
        await viewModel.setContext(.local(root: "/repo", projectRoot: "/repo")).value
        let controller = GitHistoryOutlineController(viewModel: viewModel, palette: .system)
        controller.pasteboard = pasteboard
        controller.now = { Date(timeIntervalSince1970: 1_700_000_000 + 2 * 3600) }
        let outline = GitHistoryOutlineView.makeOutlineView()
        controller.attach(to: outline)
        let scroll = GitHistoryOutlineView.makeScrollView(documentView: outline)
        scroll.frame = NSRect(x: 0, y: 0, width: 280, height: 300)
        controller.apply(commits: viewModel.commits)
        return (controller, outline, scroll)
    }

    func testOneRowPerCommit() async {
        let (_, outline, _) = await makeController(commits: [commit("a"), commit("b"), commit("c")])

        XCTAssertEqual(outline.numberOfRows, 3)
    }

    func testCommitRowShowsSubjectAuthorAndRelativeDate() async throws {
        let (controller, outline, _) = await makeController(commits: [
            commit("a", subject: "Fix the parser", author: "Grace Hopper"),
        ])

        let cell = try XCTUnwrap(controller.outlineView(outline, viewFor: nil, item: try XCTUnwrap(outline.item(atRow: 0))) as? GitCommitCellView)

        XCTAssertEqual(cell.subjectField.stringValue, "Fix the parser")
        XCTAssertEqual(cell.metaField.stringValue, "Grace Hopper · 2h")
        XCTAssertNotNil(cell.toolTip?.range(of: "a"))
    }

    func testHeadAndTagsAreShownAsLabels() async throws {
        let (controller, outline, _) = await makeController(commits: [
            commit("a", refs: [
                GitRefLabel(kind: .head, name: "HEAD"),
                GitRefLabel(kind: .localBranch, name: "main"),
                GitRefLabel(kind: .remoteBranch, name: "origin/main"),
                GitRefLabel(kind: .tag, name: "v1.0"),
            ]),
            commit("b"),
        ])

        let top = try XCTUnwrap(controller.outlineView(outline, viewFor: nil, item: try XCTUnwrap(outline.item(atRow: 0))) as? GitCommitCellView)
        let plain = try XCTUnwrap(controller.outlineView(outline, viewFor: nil, item: try XCTUnwrap(outline.item(atRow: 1))) as? GitCommitCellView)

        XCTAssertEqual(top.pills.labels.map(\.name), ["HEAD", "main", "v1.0", "origin/main"])
        XCTAssertTrue(top.gutter.isHead)
        XCTAssertEqual(plain.pills.labels, [])
        XCTAssertFalse(plain.gutter.isHead)
    }

    func testGutterLineStopsAtTheEnds() async throws {
        let (controller, outline, _) = await makeController(commits: [
            commit("a"), commit("b"), commit("c", parents: []),
        ])

        func gutter(_ row: Int) throws -> GitCommitGutterView {
            try XCTUnwrap(controller.outlineView(outline, viewFor: nil, item: try XCTUnwrap(outline.item(atRow: row))) as? GitCommitCellView).gutter
        }

        XCTAssertEqual(try gutter(0).lineAbove, false)
        XCTAssertEqual(try gutter(0).lineBelow, true)
        XCTAssertEqual(try gutter(1).lineAbove, true)
        XCTAssertEqual(try gutter(2).lineBelow, false, "a root commit ends the lane")
    }

    func testCopySHAAndSubjectPutTheExactValuesOnThePasteboard() async {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let (controller, _, _) = await makeController(commits: [commit(sha, subject: "feat: the \"thing\"")])

        controller.perform(.copySHA, on: sha)
        XCTAssertEqual(pasteboard.string(forType: .string), sha)

        controller.perform(.copySubject, on: sha)
        XCTAssertEqual(pasteboard.string(forType: .string), "feat: the \"thing\"")
    }

    func testCommitMenuOffersCopySHAAndCopySubject() async {
        let (controller, _, _) = await makeController(commits: [commit("a")])
        let menu = NSMenu()

        controller.rebuildMenuItems(menu, forCommit: "a")

        XCTAssertEqual(menu.items.map(\.title), ["Copy SHA", "Copy Subject"])
        controller.rebuildMenuItems(menu, forCommit: nil)
        XCTAssertTrue(menu.items.isEmpty)
    }

    func testCopyCommandCopiesTheSelectedCommitsSHA() async {
        let (controller, outline, _) = await makeController(commits: [commit("a"), commit("b")])
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        XCTAssertTrue(controller.copySelection())

        XCTAssertEqual(pasteboard.string(forType: .string), "b")
    }

    func testAppendedPageKeepsTheSelection() async {
        let first = (0..<3).map { commit("c\($0)") }
        let (controller, outline, _) = await makeController(commits: first)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        controller.apply(commits: first + [commit("c3"), commit("c4")])

        XCTAssertEqual(outline.numberOfRows, 5)
        XCTAssertEqual(outline.selectedRow, 1)
    }

    func testReplacedListKeepsTheSelectedCommitWhereItMoved() async {
        let (controller, outline, _) = await makeController(commits: [commit("a"), commit("b")])
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        controller.apply(commits: [commit("x"), commit("b")])

        XCTAssertEqual(outline.selectedRow, 1)
        controller.apply(commits: [commit("y")])
        XCTAssertEqual(outline.selectedRow, -1)
    }

    /// New commits landing on top while the user is scrolled down must not
    /// move what they are looking at.
    func testCommitsLandingOnTopKeepTheVisibleRowsInPlace() async throws {
        let first = (0..<40).map { commit("c\($0)") }
        let (controller, outline, scroll) = await makeController(commits: first)
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 10 * GitHistoryRowMetrics.commitRowHeight))
        let topRow = outline.row(at: NSPoint(x: 1, y: clip.bounds.minY + 1))
        let topSHA = try XCTUnwrap(outline.item(atRow: topRow) as? GitHistoryItem).sha

        controller.apply(commits: [commit("new1"), commit("new0")] + first)

        XCTAssertEqual(outline.numberOfRows, 42)
        let nowTop = outline.row(at: NSPoint(x: 1, y: clip.bounds.minY + 1))
        XCTAssertEqual((outline.item(atRow: nowTop) as? GitHistoryItem)?.sha, topSHA)
    }

    func testCommitsLandingOnTopAreShownWhenAtTheTop() async {
        let first = (0..<40).map { commit("c\($0)") }
        let (controller, outline, scroll) = await makeController(commits: first)

        controller.apply(commits: [commit("new0")] + first)

        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        XCTAssertEqual((outline.item(atRow: 0) as? GitHistoryItem)?.sha, "new0")
    }

    /// A scroll back to the top can settle a fraction of a point below it
    /// (seen in the running app); that is still the top.
    func testCommitsLandingOnTopAreShownWhenASubPointBelowTheTop() async {
        let first = (0..<40).map { commit("c\($0)") }
        let (controller, outline, scroll) = await makeController(commits: first)
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0.3))

        controller.apply(commits: [commit("new0")] + first)

        XCTAssertEqual(scroll.contentView.bounds.minY, 0.3, accuracy: 0.001)
        XCTAssertEqual(outline.row(at: NSPoint(x: 1, y: scroll.contentView.bounds.minY + 1)), 0)
        XCTAssertEqual((outline.item(atRow: 0) as? GitHistoryItem)?.sha, "new0")
    }

    /// Expanding GIT HISTORY again builds a new outline over the kept view
    /// model; it reopens where the user left it, and the fresh outline's
    /// own report of being at the top does not overwrite that.
    func testARebuiltListReopensWhereItWasScrolled() async {
        let commits = (0..<40).map { commit("c\($0)") }
        let (controller, _, scroll) = await makeController(commits: commits)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        controller.noteScrollOffset(scroll.contentView.bounds.minY)
        XCTAssertEqual(controller.viewModel.scrollOffset, 200)

        let rebuilt = GitHistoryOutlineController(viewModel: controller.viewModel, palette: .system)
        let outline = GitHistoryOutlineView.makeOutlineView()
        rebuilt.attach(to: outline)
        let rebuiltScroll = GitHistoryOutlineView.makeScrollView(documentView: outline)
        rebuiltScroll.frame = NSRect(x: 0, y: 0, width: 280, height: 300)
        rebuilt.noteScrollOffset(0)
        rebuilt.apply(commits: controller.viewModel.commits)

        XCTAssertEqual(rebuiltScroll.contentView.bounds.minY, 200)
        XCTAssertEqual(controller.viewModel.scrollOffset, 200)
        rebuiltScroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        rebuilt.noteScrollOffset(rebuiltScroll.contentView.bounds.minY)
        XCTAssertEqual(controller.viewModel.scrollOffset, 120)
    }

    func testScrollingNearTheBottomLoadsMore() async {
        let fake = FakeGitHistory()
        let all = (0..<60).map { commit("c\($0)") }
        fake.setHead(.success(GitHead(oid: "c0", branch: "main")), for: "/repo")
        fake.setCommits(all, for: "/repo")
        let viewModel = GitHistoryViewModel(services: fake.services, pageSize: 30)
        await viewModel.setContext(.local(root: "/repo", projectRoot: "/repo")).value
        let controller = GitHistoryOutlineController(viewModel: viewModel, palette: .system)
        let outline = GitHistoryOutlineView.makeOutlineView()
        controller.attach(to: outline)
        let scroll = GitHistoryOutlineView.makeScrollView(documentView: outline)
        scroll.frame = NSRect(x: 0, y: 0, width: 280, height: 300)
        controller.apply(commits: viewModel.commits)

        controller.noteScrolled(visibleMaxY: 100)
        XCTAssertEqual(fake.logCalls.count, 1, "far from the bottom: no read")

        await controller.noteScrolled(visibleMaxY: outline.rect(ofRow: outline.numberOfRows - 1).maxY - 10)?.value
        XCTAssertEqual(fake.logCalls.map(\.offset), [0, 30])
        XCTAssertEqual(viewModel.commits.count, 60)
    }

    func testRelativeDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func text(_ secondsAgo: TimeInterval) -> String {
            GitRelativeDate.text(for: now.addingTimeInterval(-secondsAgo), now: now)
        }
        XCTAssertEqual(text(20), "now")
        XCTAssertEqual(text(-300), "now", "a clock-skewed future date")
        XCTAssertEqual(text(5 * 60), "5m")
        XCTAssertEqual(text(3 * 3600), "3h")
        XCTAssertEqual(text(2 * 86400), "2d")
        XCTAssertEqual(text(15 * 86400), "2w")
        XCTAssertEqual(text(70 * 86400), "2mo")
        XCTAssertEqual(text(800 * 86400), "2y")
    }
}
