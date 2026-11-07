import XCTest
@testable import UnpeelNative

/// The flattener that turns the PROJECTS tree into one flat list of rows
/// (ADR 0009, #41). Both carousel pages render its output, so its order,
/// ids, ancestry and flags are the contract this suite pins down.
final class SidebarTreeFlattenerTests: XCTestCase {
    // MARK: Order

    func testOrderIsPinnedPartitionThenMixedThenRecursionIntoExpandedFolders() {
        let group = folder("group", parent: "p", sessions: [session("g1", in: "group")])
        let tree = project("p", sessions: [session("pin"), session("s1")], folders: [group])

        let rows = flatten(
            [tree],
            expanded: ["p", "group"],
            pinned: ["p": [.session(session("pin"))]],
            regular: [
                "p": [.session(session("s1")), .folder(group)],
                "group": [.session(session("g1", in: "group"))],
            ]
        )

        XCTAssertEqual(rows.map(\.id), [
            "folder:p", "session:pin", "session:s1", "folder:group", "session:g1",
        ])
        XCTAssertEqual(rows.map(\.kind), [
            .projectHeader, .session, .session, .folderHeader, .session,
        ])
    }

    func testPinnedChildGroupInterleavesWithPinnedSessions() {
        let pinnedGroup = folder("pg", parent: "p")
        let tree = project("p", sessions: [session("a"), session("b")], folders: [pinnedGroup])

        let rows = flatten(
            [tree],
            expanded: ["p"],
            pinned: ["p": [.session(session("a")), .folder(pinnedGroup), .session(session("b"))]],
            regular: ["p": []]
        )

        XCTAssertEqual(rows.map(\.id), [
            "folder:p", "session:a", "folder:pg", "session:b",
        ])
        XCTAssertEqual(rows.map(\.isPinned), [false, true, true, true])
    }

    func testPlaceholderFollowsAnExpandedProjectWithNothingToList() {
        let rows = flatten([project("p")], expanded: ["p"])

        XCTAssertEqual(rows.map(\.id), ["folder:p", "empty:p"])
        XCTAssertEqual(rows.last?.kind, .emptyPlaceholder)
    }

    func testPlaceholderOfAnEmptyExpandedGroupIsOwnedByTheGroup() {
        let group = folder("group", parent: "p")
        let rows = flatten(
            [project("p", folders: [group])],
            expanded: ["p", "group"],
            regular: ["p": [.folder(group)]]
        )

        XCTAssertEqual(rows.map(\.id), ["folder:p", "folder:group", "empty:group"])
        XCTAssertEqual(rows.last?.folderChain, ["group"])
    }

    // MARK: Ids

    func testRowIdsUseOneIdSpaceAndAreUnique() {
        let group = folder("group", parent: "p")
        let tree = project("p", sessions: [session("s1")], folders: [group])

        let rows = flatten(
            [tree, project("q")],
            expanded: ["p", "group", "q"],
            regular: ["p": [.session(session("s1")), .folder(group)]]
        )

        XCTAssertEqual(rows.map(\.id), [
            "folder:p", "session:s1", "folder:group", "empty:group", "folder:q", "empty:q",
        ])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testASessionListedTwiceAppearsOnce() {
        // A pinned Session that also leaks into the regular list must not
        // render twice: one ForEach would see a duplicate id.
        let rows = flatten(
            [project("p", sessions: [session("dup")])],
            expanded: ["p"],
            pinned: ["p": [.session(session("dup"))]],
            regular: ["p": [.session(session("dup"))]]
        )

        XCTAssertEqual(rows.map(\.id), ["folder:p", "session:dup"])
        XCTAssertEqual(rows.last?.isPinned, true)
    }

    func testAFolderListedTwiceAppearsOnceWithItsRows() {
        let group = folder("group", parent: "p", sessions: [session("g1", in: "group")])
        let rows = flatten(
            [project("p", folders: [group])],
            expanded: ["p", "group"],
            pinned: ["p": [.folder(group)]],
            regular: [
                "p": [.folder(group)],
                "group": [.session(session("g1", in: "group"))],
            ]
        )

        XCTAssertEqual(rows.map(\.id), ["folder:p", "folder:group", "session:g1"])
    }

    // MARK: Depth and ancestry

    func testDepthMatchesTheNestedTree() {
        let inner = folder("inner", parent: "outer", sessions: [session("i1", in: "inner")])
        let outer = folder(
            "outer", parent: "p", sessions: [session("o1", in: "outer")], folders: [inner]
        )
        let rows = flatten(
            [project("p", sessions: [session("s1")], folders: [outer])],
            expanded: ["p", "outer", "inner"],
            regular: [
                "p": [.session(session("s1")), .folder(outer)],
                "outer": [.session(session("o1", in: "outer")), .folder(inner)],
                "inner": [.session(session("i1", in: "inner"))],
            ]
        )

        XCTAssertEqual(rows.map(\.id), [
            "folder:p", "session:s1", "folder:outer", "session:o1", "folder:inner", "session:i1",
        ])
        // Sessions sit at their owner's depth; a child folder header one
        // level below its parent (the live tree's ProjectNodeView depths).
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1, 2, 2])
        XCTAssertEqual(rows.map(\.topLevelProjectID), Array(repeating: "p", count: 6))
        XCTAssertEqual(rows.map(\.folderChain), [
            [], [], ["outer"], ["outer"], ["outer", "inner"], ["outer", "inner"],
        ])
    }

    func testPlaceholderSitsAtItsOwnersDepth() {
        let group = folder("group", parent: "p")
        let rows = flatten(
            [project("p", folders: [group])],
            expanded: ["p", "group"],
            regular: ["p": [.folder(group)]]
        )

        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
    }

    // MARK: Block flags

    func testFirstAndLastOfBlockFlagsAndTheGapBetweenBlocks() {
        let rows = flatten(
            [
                project("p", sessions: [session("s1"), session("s2")]),
                project("collapsed", sessions: [session("hidden", in: "collapsed")]),
                project("q", sessions: [session("q1", in: "q")]),
            ],
            expanded: ["p", "q"],
            regular: [
                "p": [.session(session("s1")), .session(session("s2"))],
                "q": [.session(session("q1", in: "q"))],
            ]
        )

        XCTAssertEqual(rows.map(\.id), [
            "folder:p", "session:s1", "session:s2", "folder:collapsed", "folder:q", "session:q1",
        ])
        XCTAssertEqual(rows.map(\.isFirstOfBlock), [true, false, false, true, true, false])
        XCTAssertEqual(rows.map(\.isLastOfBlock), [false, false, true, true, false, true])
        // 1 pt between projects: above every top-level header but the first.
        XCTAssertEqual(rows.map(\.hasBlockGapAbove), [false, false, false, true, true, false])
    }

    // MARK: Stagger

    func testStaggerIndicesRestartPerListAndCountHiddenItems() {
        let group = folder("group", parent: "p", sessions: [
            session("g1", in: "group"), session("g2", in: "group"),
        ])
        let rows = flatten(
            [project("p", sessions: [
                session("pin1"), session("pin2"), session("s1"),
            ], folders: [group])],
            expanded: ["p", "group"],
            hidden: ["pin1"],
            pinned: ["p": [.session(session("pin1")), .session(session("pin2"))]],
            regular: [
                "p": [.session(session("s1")), .folder(group)],
                "group": [.session(session("g1", in: "group")), .session(session("g2", in: "group"))],
            ]
        )

        XCTAssertEqual(rows.map(\.id), [
            "folder:p", "session:pin2", "session:s1", "folder:group", "session:g1", "session:g2",
        ])
        // Pinned rows use their index; regular rows the pinned count plus
        // theirs. Both count the hidden pane member, as the live
        // sessionList's enumerated ForEach does.
        XCTAssertEqual(rows.map(\.staggerIndex), [0, 1, 2, 3, 0, 1])
    }

    // MARK: Pane members and collapsed nodes

    func testHiddenPaneMembersLeaveTheList() {
        let rows = flatten(
            [project("p", sessions: [session("rep"), session("member")])],
            expanded: ["p"],
            hidden: ["member"],
            regular: ["p": [.session(session("rep")), .session(session("member"))]]
        )

        XCTAssertEqual(rows.map(\.id), ["folder:p", "session:rep"])
    }

    func testAListOfOnlyHiddenMembersShowsNoPlaceholder() {
        // The live list checks the raw lists for emptiness.
        let rows = flatten(
            [project("p", sessions: [session("member")])],
            expanded: ["p"],
            hidden: ["member"],
            regular: ["p": [.session(session("member"))]]
        )

        XCTAssertEqual(rows.map(\.id), ["folder:p"])
    }

    func testCollapsedNodesListOnlyTheirHeader() {
        let group = folder("group", parent: "p", sessions: [session("g1", in: "group")])
        let rows = flatten(
            [
                project("collapsed", sessions: [session("c1", in: "collapsed")]),
                project("p", folders: [group]),
            ],
            expanded: ["p"],
            regular: [
                "collapsed": [.session(session("c1", in: "collapsed"))],
                "p": [.folder(group)],
                "group": [.session(session("g1", in: "group"))],
            ]
        )

        XCTAssertEqual(rows.map(\.id), ["folder:collapsed", "folder:p", "folder:group"])
        XCTAssertEqual(rows.map(\.content.isExpanded), [false, true, false])
    }

    // MARK: Budget

    func testTheBudgetCapsEveryRowKind() {
        let sessions = (0..<30).map { session("s\($0)") }
        let rows = flatten(
            [
                project("p", sessions: sessions),
                project("empty"),
                project("q", sessions: sessions.map { session("q-\($0.id)", in: "q") }),
            ],
            expanded: ["p", "empty", "q"],
            regular: [
                "p": sessions.map { .session($0) },
                "q": sessions.map { .session(session("q-\($0.id)", in: "q")) },
            ],
            budget: 40
        )

        XCTAssertEqual(rows.count, 40)
        XCTAssertEqual(rows.prefix(33).map(\.id).suffix(3), [
            "session:s29", "folder:empty", "empty:empty",
        ])
        XCTAssertEqual(rows.last?.id, "session:q-s5")
    }

    func testACutListCarriesOnPastItsLastRow() {
        // The live page keeps going where the pooled glance stops, so the
        // cut must not round the wash's bottom or end the block.
        let group = folder("group", parent: "p", sessions: [
            session("g1", in: "group"), session("g2", in: "group"),
        ])
        let rows = flatten(
            [project("p", folders: [group]), project("q")],
            expanded: ["p", "group"],
            regular: [
                "p": [.folder(group)],
                "group": [.session(session("g1", in: "group")), .session(session("g2", in: "group"))],
            ],
            budget: 3
        )

        XCTAssertEqual(rows.map(\.id), ["folder:p", "folder:group", "session:g1"])
        XCTAssertEqual(rows.last?.washSlices, [slice("group", top: false, bottom: false)])
        XCTAssertEqual(rows.last?.isLastOfBlock, false)
    }

    func testABudgetSpentExactlyStillClosesTheList() {
        let group = folder("group", parent: "p", sessions: [session("g1", in: "group")])
        let rows = flatten(
            [project("p", folders: [group])],
            expanded: ["p", "group"],
            regular: [
                "p": [.folder(group)],
                "group": [.session(session("g1", in: "group"))],
            ],
            budget: 3
        )

        XCTAssertEqual(rows.last?.washSlices, [slice("group", top: false, bottom: true)])
        XCTAssertEqual(rows.last?.isLastOfBlock, true)
    }

    func testHiddenMembersDoNotSpendTheBudget() {
        let rows = flatten(
            [project("p", sessions: [session("hidden"), session("a"), session("b")])],
            expanded: ["p"],
            hidden: ["hidden"],
            regular: ["p": [
                .session(session("hidden")), .session(session("a")), .session(session("b")),
            ]],
            budget: 3
        )

        XCTAssertEqual(rows.map(\.id), ["folder:p", "session:a", "session:b"])
    }

    func testNoBudgetListsEverything() {
        let sessions = (0..<120).map { session("s\($0)") }
        let rows = flatten(
            [project("p", sessions: sessions)],
            expanded: ["p"],
            regular: ["p": sessions.map { .session($0) }]
        )

        XCTAssertEqual(rows.count, 121)
    }

    // MARK: Group wash slices

    func testGroupWashRoundsTheHeaderTopAndTheLastRowBottom() {
        let group = folder("group", parent: "p", sessions: [
            session("g1", in: "group"), session("g2", in: "group"),
        ])
        let rows = flatten(
            [project("p", sessions: [session("after")], folders: [group])],
            expanded: ["p", "group"],
            regular: [
                "p": [.folder(group), .session(session("after"))],
                "group": [.session(session("g1", in: "group")), .session(session("g2", in: "group"))],
            ]
        )

        XCTAssertEqual(rows.map(\.id), [
            "folder:p", "folder:group", "session:g1", "session:g2", "session:after",
        ])
        XCTAssertEqual(rows.map(\.washSlices), [
            [],
            [slice("group", top: true, bottom: false)],
            [slice("group", top: false, bottom: false)],
            [slice("group", top: false, bottom: true)],
            [],
        ])
    }

    func testOneRowClusterIsFullyRounded() {
        let group = folder("group", parent: "p", sessions: [session("g1", in: "group")])
        let rows = flatten(
            [project("p", folders: [group])],
            expanded: ["p"],
            regular: ["p": [.folder(group)]]
        )

        XCTAssertEqual(rows.last?.washSlices, [slice("group", top: true, bottom: true)])
    }

    func testNestedGroupsStackOneSlicePerAncestor() {
        let inner = folder("inner", parent: "outer", sessions: [session("i1", in: "inner")])
        let outer = folder(
            "outer", parent: "p", sessions: [session("o1", in: "outer")], folders: [inner]
        )
        let rows = flatten(
            [project("p", folders: [outer])],
            expanded: ["p", "outer", "inner"],
            regular: [
                "p": [.folder(outer)],
                "outer": [.folder(inner), .session(session("o1", in: "outer"))],
                "inner": [.session(session("i1", in: "inner"))],
            ]
        )

        XCTAssertEqual(rows.map(\.id), [
            "folder:p", "folder:outer", "folder:inner", "session:i1", "session:o1",
        ])
        XCTAssertEqual(rows.map(\.washSlices), [
            [],
            [slice("outer", top: true, bottom: false)],
            [slice("outer", top: false, bottom: false), slice("inner", top: true, bottom: false)],
            [slice("outer", top: false, bottom: false), slice("inner", top: false, bottom: true)],
            [slice("outer", top: false, bottom: true)],
        ])
    }

    func testAClusterEndingTheBlockClosesEveryLevel() {
        let inner = folder("inner", parent: "outer", sessions: [session("i1", in: "inner")])
        let outer = folder("outer", parent: "p", folders: [inner])
        let rows = flatten(
            [project("p", folders: [outer]), project("q")],
            expanded: ["p", "outer", "inner"],
            regular: [
                "p": [.folder(outer)],
                "outer": [.folder(inner)],
                "inner": [.session(session("i1", in: "inner"))],
            ]
        )

        XCTAssertEqual(rows[3].id, "session:i1")
        XCTAssertEqual(rows[3].washSlices, [
            slice("outer", top: false, bottom: true), slice("inner", top: false, bottom: true),
        ])
        XCTAssertEqual(rows[4].washSlices, [])
    }

    func testSiblingGroupsCloseTheirOwnClusters() {
        let first = folder("first", parent: "p", sessions: [session("f1", in: "first")])
        let second = folder("second", parent: "p")
        let rows = flatten(
            [project("p", folders: [first, second])],
            expanded: ["p", "first"],
            regular: [
                "p": [.folder(first), .folder(second)],
                "first": [.session(session("f1", in: "first"))],
            ]
        )

        XCTAssertEqual(rows.map(\.washSlices), [
            [],
            [slice("first", top: true, bottom: false)],
            [slice("first", top: false, bottom: true)],
            [slice("second", top: true, bottom: true)],
        ])
    }

    func testWashedFoldersContainingTheSelection() {
        let inner = folder("inner", parent: "outer", sessions: [session("deep", in: "inner")])
        let outer = folder("outer", parent: "p", folders: [inner])
        let other = folder("other", parent: "p", sessions: [session("o1", in: "other")])
        let nodes = [project("p", sessions: [session("top")], folders: [outer, other])]

        XCTAssertEqual(
            SidebarTreeFlattener.washedFolderIDs(containing: "deep", in: nodes),
            ["outer", "inner"]
        )
        // A Session directly in a project lights no group wash.
        XCTAssertEqual(SidebarTreeFlattener.washedFolderIDs(containing: "top", in: nodes), [])
        XCTAssertEqual(SidebarTreeFlattener.washedFolderIDs(containing: nil, in: nodes), [])
    }

    // MARK: Helpers

    private func flatten(
        _ nodes: [ProjectNode],
        expanded: Set<String>,
        hidden: Set<String> = [],
        pinned: [String: [SidebarMixedItem]] = [:],
        regular: [String: [SidebarMixedItem]] = [:],
        budget: Int? = nil
    ) -> [SidebarTreeRow] {
        SidebarTreeFlattener.rows(
            topLevelNodes: nodes,
            expandedProjectIDs: expanded,
            hiddenSessionIDs: hidden,
            pinnedItems: { pinned[$0.id] ?? [] },
            regularItems: { regular[$0.id] ?? [] },
            budget: budget
        )
    }

    private func slice(_ id: String, top: Bool, bottom: Bool) -> SidebarWashSlice {
        SidebarWashSlice(folderID: id, roundsTop: top, roundsBottom: bottom)
    }

    private func project(
        _ id: String,
        sessions: [SessionEntry] = [],
        folders: [ProjectNode] = []
    ) -> ProjectNode {
        ProjectNode(
            project: Project(
                id: id, name: id, path: "/tmp/\(id)", parentProjectID: nil,
                sortOrder: nil, isFolder: nil, worktreeBranch: nil,
                workspacesEnabled: nil, mcpBlocked: nil
            ),
            sessions: sessions,
            worktrees: folders
        )
    }

    private func folder(
        _ id: String,
        parent: String,
        sessions: [SessionEntry] = [],
        folders: [ProjectNode] = []
    ) -> ProjectNode {
        ProjectNode(
            project: Project(
                id: id, name: id, path: "/tmp/\(parent)", parentProjectID: parent,
                sortOrder: nil, isFolder: true, worktreeBranch: nil,
                workspacesEnabled: nil, mcpBlocked: nil
            ),
            sessions: sessions,
            worktrees: folders
        )
    }

    private func session(_ id: String, in projectID: String = "p") -> SessionEntry {
        SessionEntry(
            id: id,
            projectID: projectID,
            label: id,
            command: "claude",
            createdAt: 1,
            status: .idle
        )
    }
}
