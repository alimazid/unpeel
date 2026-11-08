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
        flush(host)
        // Collapse and expand a group, then a whole project.
        store.toggleProjectExpanded("group")
        flush(host)
        store.toggleProjectExpanded("group")
        flush(host)
        store.toggleProjectExpanded("big")
        flush(host)
        store.toggleProjectExpanded("big")
        store.selectedSessionID = "second-29"
        flush(host)

        XCTAssertEqual(store.sidebarTreeRows.count, rows.count, "the round trip restores every row")
    }

    // MARK: Helpers

    private func render(_ store: UnpeelStore) -> NSHostingView<some View> {
        let list = ScrollView {
            SidebarLiveTreeList(store: store, dragState: SidebarDragState())
                .padding(.horizontal, 8)
        }
        let host = NSHostingView(rootView: list.frame(width: 260, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        flush(host)
        return host
    }

    /// Lets a store change reach the hosted view, then lays it out and
    /// renders it.
    private func flush(_ host: NSView) {
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
