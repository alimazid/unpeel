import AppKit
import SwiftUI
import UnpeelShared
import XCTest
@testable import UnpeelNative

/// The live PROJECTS list hosted for real (#45): about 150 rows across
/// expanded projects and nested groups lay out and render without trapping,
/// through the expand, collapse and selection churn a busy sidebar sees.
/// The hang in #39 was SwiftUI looping in the estimates of a lazy stack
/// whose children held lazy stacks; the flat list has one lazy level.
@MainActor
final class SidebarLiveTreeListLayoutTests: XCTestCase {
    func testAboutOneHundredFiftyRowsLayOutWithoutTrapping() {
        let store = UnpeelStore.sidebarFixture(
            snapshot: Self.largeTree,
            expandedProjectIDs: ["big", "group", "nested", "wt", "second", "topGroup", "empty"]
        )
        let rows = store.sidebarTreeRows
        XCTAssertGreaterThanOrEqual(rows.count, 140, "the fixture fills the list")
        XCTAssertTrue(rows.contains { $0.depth == 2 }, "a group nests inside a group")
        let host = render(store)

        // Selection lights the nested groups' washes through their own
        // observers; the list body itself never observes selection.
        store.selectedSessionID = "nested-3"
        Self.flushHostedView(host)
        // Collapse and expand a group, then a whole project.
        store.toggleProjectExpanded("group")
        Self.flushHostedView(host)
        store.toggleProjectExpanded("group")
        Self.flushHostedView(host)
        store.toggleProjectExpanded("big")
        Self.flushHostedView(host)
        store.toggleProjectExpanded("big")
        store.selectedSessionID = "second-29"
        Self.flushHostedView(host)

        XCTAssertEqual(store.sidebarTreeRows.count, rows.count, "the round trip restores every row")
    }

    /// A lazy row that scrolls away drops out of the drag registry, and it must
    /// come back with the row. Its frame in the list is unchanged, so geometry
    /// alone never reports it again: the row would look fine and refuse every
    /// press and drop until something moved it.
    func testARowScrolledAwayAndBackIsADragTargetAgain() throws {
        let panel = try HostedPanel()
        defer { panel.close() }

        let header = "group"
        let registered = try XCTUnwrap(panel.controller.registeredRowFrame(id: header), "mounted at the top")

        panel.scroll(toY: 3000)
        XCTAssertNil(panel.controller.registeredRowFrame(id: header), "the lazy list unmounted it")

        panel.scroll(toY: 0)
        let frame = try XCTUnwrap(panel.controller.registeredRowFrame(id: header), "back on screen, back in the registry")
        XCTAssertEqual(frame.minY, registered.minY, accuracy: 1)
    }

    // MARK: Selection reveal (#46)

    func testSelectingAFarOffScreenSessionCentersItsRow() throws {
        let panel = try HostedPanel()
        defer { panel.close() }
        XCTAssertNil(panel.frame(of: Self.farSession), "the fixture's far row starts unmounted")
        let top = panel.visibleRect

        panel.store.selectedSessionID = Self.farSession

        let frame = try panel.settledFrame(of: Self.farSession)
        XCTAssertGreaterThan(panel.visibleRect.minY, top.minY, "the list scrolled")
        XCTAssertTrue(panel.visibleRect.contains(frame), "\(frame) in \(panel.visibleRect)")
        XCTAssertEqual(frame.midY, panel.visibleRect.midY, accuracy: 1, "centered")
    }

    func testSelectingAMountedRowAtTheBottomEdgeScrollsItJustClearOfTheFade() throws {
        let panel = try HostedPanel()
        defer { panel.close() }
        let edge = panel.visibleRect.maxY - Self.margin
        let row = try XCTUnwrap(panel.mountedSessions.first { $0.frame.maxY > edge }, "a row in the bottom margin")

        panel.store.selectedSessionID = row.id

        let frame = try panel.settledFrame(of: row.id)
        XCTAssertEqual(panel.visibleRect.maxY, frame.maxY + Self.margin, accuracy: 1)
    }

    func testSelectingAMountedRowAtTheTopEdgeScrollsItJustClearOfTheFade() throws {
        let panel = try HostedPanel()
        defer { panel.close() }
        panel.scroll(toY: 1000)
        let edge = panel.visibleRect.minY + SidebarSectionMetrics.projectsFadeRamp + Self.margin
        let row = try XCTUnwrap(panel.mountedSessions.last { $0.frame.minY < edge }, "a row in the top margin")

        panel.store.selectedSessionID = row.id

        let frame = try panel.settledFrame(of: row.id)
        XCTAssertEqual(panel.visibleRect.minY, frame.minY - Self.margin, accuracy: 1)
    }

    func testSelectingARowClearOfTheEdgesDoesNotScroll() throws {
        let panel = try HostedPanel()
        defer { panel.close() }
        let before = panel.visibleRect
        let row = try XCTUnwrap(panel.mountedSessions.first { $0.frame.midY > before.midY }, "a row mid-list")

        panel.store.selectedSessionID = row.id
        panel.settle()

        XCTAssertEqual(panel.visibleRect, before)
    }

    func testARevealRequestForAnUnmountedRowCentersIt() throws {
        let panel = try HostedPanel()
        defer { panel.close() }

        panel.store.revealSessionInSidebar(Self.farSession)

        let frame = try panel.settledFrame(of: Self.farSession)
        XCTAssertEqual(frame.midY, panel.visibleRect.midY, accuracy: 1)
    }

    /// Following a row asks for the minimal scroll, which only a mounted row
    /// can take. An unmounted one still comes into view, centered.
    func testFollowingAnUnmountedRowCentersIt() throws {
        let panel = try HostedPanel()
        defer { panel.close() }

        panel.store.followSessionRowInSidebar(Self.farSession)

        let frame = try panel.settledFrame(of: Self.farSession)
        XCTAssertEqual(frame.midY, panel.visibleRect.midY, accuracy: 1)
    }

    func testARevealRequestForAMountedRowCentersIt() throws {
        let panel = try HostedPanel()
        defer { panel.close() }
        let edge = panel.visibleRect.maxY - Self.margin
        let row = try XCTUnwrap(panel.mountedSessions.first { $0.frame.maxY > edge }, "a row in the bottom margin")

        panel.store.revealSessionInSidebar(row.id)

        let frame = try panel.settledFrame(of: row.id)
        XCTAssertEqual(frame.midY, panel.visibleRect.midY, accuracy: 1)
    }

    /// A Host-scope switch lands at the top at once. The far selection it
    /// adopts in the same commit starts no reveal scroll underneath.
    func testAScopeSwitchLandsAtTheTopWithNoRevealScroll() throws {
        let panel = try HostedPanel()
        defer { panel.close() }
        panel.store.selectedSessionID = Self.farSession
        panel.settle()
        XCTAssertGreaterThan(panel.visibleRect.minY, 0, "scrolled away first")
        let elsewhere = LaunchConfig.unpeelDir
            .appendingPathComponent("scope-\(UUID().uuidString.prefix(6))").path

        panel.store.selectLocalWorkspace(home: elsewhere, name: "Elsewhere")
        // A scoped selection is the runtime's, and it only takes a row its
        // own snapshot holds.
        panel.store.remoteHostRuntime.holdSnapshotForTesting(Self.largeTree)
        panel.store.projectRemoteScope(snapshot: Self.largeTree)
        panel.store.selectedSessionID = "second-20"

        panel.flush()
        XCTAssertEqual(panel.visibleRect.minY, 0, "at the top on the first frame, so no animation")
        panel.settle()
        XCTAssertEqual(panel.visibleRect.minY, 0, "and no reveal scroll after it")
        XCTAssertEqual(panel.store.selectedSessionID, "second-20", "the far row is selected")
    }

    // MARK: Helpers

    /// The panel the app shows, in a real window (`scrollTo` needs one), off
    /// screen. It carries about 150 rows across expanded projects and nested
    /// groups, in a viewport far shorter than the list.
    @MainActor
    private final class HostedPanel {
        let store: UnpeelStore
        let controller = SidebarSessionDragController()
        let scrollView: NSScrollView
        private let window: NSWindow
        private let host: NSView

        init() throws {
            store = UnpeelStore.sidebarFixture(
                snapshot: largeTree,
                expandedProjectIDs: ["big", "group", "nested", "wt", "second", "topGroup", "empty"]
            )
            let panel = SidebarProjectTreePanel(
                store: store,
                dragState: SidebarDragState(),
                sessionDragController: controller
            )
            window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: 260, height: 600),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            host = NSHostingView(rootView: panel.frame(width: 260, height: 600))
            window.contentView = host
            window.orderBack(nil)
            flushHostedView(host)
            scrollView = try XCTUnwrap(firstScrollView(in: host))
        }

        func close() {
            window.orderOut(nil)
        }

        var visibleRect: CGRect { scrollView.documentVisibleRect }

        /// The Session rows the lazy list has built, top to bottom.
        var mountedSessions: [(id: String, frame: CGRect)] {
            store.sidebarTreeRows.compactMap { row in
                guard case let .session(entry) = row.content,
                      let frame = frame(of: entry.id)
                else { return nil }
                return (entry.id, frame)
            }
        }

        func frame(of sessionID: String) -> CGRect? {
            controller.registeredRowFrame(id: sessionID)
        }

        /// The row's frame once the list stopped moving, however long a
        /// scroll animation takes. Fails if the row never mounts.
        func settledFrame(
            of sessionID: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> CGRect {
            settle()
            return try XCTUnwrap(frame(of: sessionID), "the row never mounted", file: file, line: line)
        }

        /// Waits out any scroll animation: the visible rect holds still for
        /// several turns in a row.
        func settle() {
            var last = visibleRect
            var stillTurns = 0
            for _ in 0 ..< 60 where stillTurns < 6 {
                flush()
                stillTurns = visibleRect == last ? stillTurns + 1 : 0
                last = visibleRect
            }
        }

        func scroll(toY y: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            settle()
        }

        func flush() {
            flushHostedView(host)
        }
    }

    /// Far below the viewport, with rows after it, so centering it is
    /// reachable.
    private static let farSession = "second-15"

    /// How far past a row's ends a minimal scroll stops (spec #41).
    private static let margin: CGFloat = 48

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }

    private func render(_ store: UnpeelStore) -> NSHostingView<some View> {
        let list = ScrollView {
            SidebarLiveTreeList(store: store, dragState: SidebarDragState())
                .padding(.horizontal, 8)
        }
        let host = NSHostingView(rootView: list.frame(width: 260, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        Self.flushHostedView(host)
        return host
    }

    /// Lets a store change reach the hosted view, then lays it out and
    /// renders it.
    private static func flushHostedView(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        host.display()
    }

    /// big (60 Sessions, 3 pinned) ▸ group (20) ▸ nested (10), big ▸ wt
    /// (10); second (30); a top-level group (10); an empty project.
    private static let largeTree: RemoteBootstrapSnapshot = {
        let projects: [(id: String, parent: String?, isGroup: Bool, branch: String?)] = [
            ("big", nil, false, nil),
            ("group", "big", true, nil),
            ("nested", "group", true, nil),
            ("wt", "big", false, "feature"),
            ("second", nil, false, nil),
            ("topGroup", nil, true, nil),
            ("empty", nil, false, nil),
        ]
        let counts = ["big": 60, "group": 20, "nested": 10, "wt": 10, "second": 30, "topGroup": 10]
        var createdAt: Int64 = 1
        let sessions = projects.flatMap { project in
            (0 ..< (counts[project.id] ?? 0)).map { index -> RemoteSessionSummary in
                createdAt += 1
                return RemoteSessionSummary(
                    id: "\(project.id)-\(index)",
                    projectID: project.id,
                    title: "\(project.id) \(index)",
                    command: "zsh",
                    createdAtUnixMs: createdAt,
                    status: .running,
                    activity: index % 7 == 0 ? .working : .idle,
                    pinned: project.id == "big" && index < 3
                )
            }
        }
        return RemoteBootstrapSnapshot(
            folders: [],
            projects: projects.enumerated().map { order, project in
                RemoteProjectSummary(
                    id: project.id,
                    name: project.id,
                    path: "/fixture/\(project.id)",
                    parentProjectID: project.parent,
                    worktreeBranch: project.branch,
                    isGroup: project.isGroup ? true : nil,
                    pinned: nil,
                    sortOrder: order,
                    sessionOrder: nil
                )
            },
            presets: [],
            sessions: sessions,
            capturedAtUnixMs: 1
        )
    }()
}
