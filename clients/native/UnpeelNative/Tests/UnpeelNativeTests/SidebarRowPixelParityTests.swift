import AppKit
import SwiftUI
import UnpeelShared
import XCTest
@testable import UnpeelNative

/// Fork-only (#49): #41 story 32 as a test. The pooled carousel page is
/// pixel-identical to the live page it becomes at the commit swap. Each test
/// takes the path a swipe takes: the neighbor's pooled page first, then the
/// scope switch, then the live page.
///
/// Not covered, because only the live page has them: a plain git project's
/// checked-out branch beside its name, and a project's local-site globe. The
/// fixture's paths are no git repositories and serve no sites.
@MainActor
final class SidebarRowPixelParityTests: XCTestCase {
    /// The live page with its whole interaction layer, at rest: what the user
    /// sees on either side of the swap, the per-group observers lighting the
    /// wash on one page and `highlightedFolderIDs` on the other.
    func testTheIncomingPageIsPixelIdenticalToTheLivePageItBecomes() throws {
        let swipe = try WorkspaceSwipe()
        defer { swipe.finish() }

        let pooled = try Pixels.appearances.map { appearance in
            try Pixels.settled(
                of: Self.page(SidebarListPage(source: .pooled(swipe.neighbor), store: swipe.store)),
                appearance: appearance
            )
        }
        swipe.commit()
        let live = try Pixels.appearances.map { appearance in
            try Pixels.settled(of: Self.page(swipe.livePanel()), appearance: appearance)
        }

        XCTAssertEqual(Set(swipe.store.sidebarTreeRows.map(\.kind)).count, 4, "every row kind is on the page")
        for (appearance, (pooledPage, livePage)) in zip(Pixels.appearances, zip(pooled, live)) {
            XCTAssertFalse(pooledPage[0].isBlank, "the capture drew something")
            Pixels.assertEqual(pooledPage, livePage, "page, \(appearance.rawValue)")
        }
    }

    /// Each row kind's rows through their one container with no interaction
    /// layer, so a difference is the row views' inputs, and the failure names
    /// the kind.
    func testEachRowKindPaintsTheSameFromBothPagesInputs() throws {
        let swipe = try WorkspaceSwipe()
        defer { swipe.finish() }
        let content = try XCTUnwrap(SidebarListContentBuilder.content(for: swipe.neighbor, store: swipe.store))
        let lit = content.inputs.highlightedFolderIDs

        swipe.commit()
        let rows = swipe.store.sidebarTreeRows
        let list = SidebarLiveTreeList(store: swipe.store, dragState: SidebarDragState())
        let inputs = SidebarLiveRowInputs(store: swipe.store)

        XCTAssertEqual(content.rows.map(\.id), rows.map(\.id))
        XCTAssertEqual(content.inputs.selectedSessionID, WorkspaceSwipe.selected)
        XCTAssertEqual(lit, ["group", "inner"], "the selection lights both washes")
        XCTAssertEqual(content.inputs.paneItemsByRepresentative["pane-main"]?.count, 2, "a pane group's row is on the page")
        let pooledByKind = Dictionary(grouping: content.rows, by: \.kind)
        let liveByKind = Dictionary(grouping: rows, by: \.kind)
        XCTAssertEqual(liveByKind.count, 4, "every row kind is on the page")
        for (kind, liveRows) in liveByKind {
            let pooled = try Pixels.settled(of: Self.strip(VStack(spacing: 0) {
                ForEach(pooledByKind[kind] ?? []) { SidebarPooledTreeRow(row: $0, inputs: content.inputs) }
            }))
            let live = try Pixels.settled(of: Self.strip(VStack(spacing: 0) {
                ForEach(liveRows) { Self.restingRow($0, list: list, inputs: inputs, lit: lit) }
            }))
            Pixels.assertEqual(pooled, live, "\(kind) rows")
        }
    }

    /// The drag registry is the live layer's door: a pooled row never walks
    /// through it, even with a controller in its environment.
    func testAPooledRowRegistersNoDragFrameWhereALiveRowDoes() throws {
        let swipe = try WorkspaceSwipe()
        defer { swipe.finish() }
        let content = try XCTUnwrap(SidebarListContentBuilder.content(for: swipe.neighbor, store: swipe.store))
        let controller = SidebarSessionDragController()
        let ids = [WorkspaceSwipe.selected, "alpha", "inner"]

        try Pixels.hosting(
            VStack(spacing: 0) {
                ForEach(content.rows) { SidebarPooledTreeRow(row: $0, inputs: content.inputs) }
            }
            .environment(\.sidebarSessionDragController, controller)
        ) { _ in
            for id in ids {
                XCTAssertNil(controller.registeredRowFrame(id: id), id)
            }
        }

        swipe.commit()
        try Pixels.hosting(Self.page(swipe.livePanel(controller: controller))) { _ in
            for id in ids {
                XCTAssertNotNil(controller.registeredRowFrame(id: id), id)
            }
        }
    }

    /// Swiping back to the current instance from another scope: the live page
    /// it becomes reads the tints its Host publishes, and the store can't
    /// resolve them while it is scoped away.
    func testSwipingBackToLocalPaintsTheTintsItsHostPublishes() throws {
        let swipe = try WorkspaceSwipe(neighborKind: .local(
            record: nil, isDefault: true, isCurrentInstance: true, isRunning: true
        ))
        defer { swipe.finish() }
        swipe.scopeAway()

        let content = try XCTUnwrap(SidebarListContentBuilder.content(for: swipe.neighbor, store: swipe.store))

        XCTAssertEqual(content.inputs.folderColors, ["alpha": .violet, "dated": .teal])
    }

    /// A true remote Host's live page shows no tints, whatever it publishes.
    func testARemoteHostsPageStaysUntinted() throws {
        let swipe = try WorkspaceSwipe(neighborKind: .ssh(SSHHostRecord(
            id: "ssh-parity",
            name: "Parity",
            target: "ssh://parity",
            hostID: WorkspaceSwipe.macID,
            mode: .command,
            usesStoredSecret: false
        )))
        defer { swipe.finish() }

        let content = try XCTUnwrap(SidebarListContentBuilder.content(for: swipe.neighbor, store: swipe.store))

        XCTAssertTrue(content.inputs.folderColors.isEmpty)
    }

    /// The comparison itself has to see what it guards: a 1 pt shift and an
    /// unlit wash, at both scales.
    func testTheComparisonSeesAOnePointShiftAndAnUnlitWash() throws {
        let swipe = try WorkspaceSwipe()
        defer { swipe.finish() }
        let content = try XCTUnwrap(SidebarListContentBuilder.content(for: swipe.neighbor, store: swipe.store))
        let row = try XCTUnwrap(content.rows.first { $0.id == "session:inner-plain" })
        let unlit = SidebarPooledRowInputs(
            selectedSessionID: content.inputs.selectedSessionID,
            highlightedFolderIDs: [],
            unreadSessionIDs: content.inputs.unreadSessionIDs,
            paneItemsByRepresentative: content.inputs.paneItemsByRepresentative,
            dateSortedProjectIDs: content.inputs.dateSortedProjectIDs,
            folderColors: content.inputs.folderColors
        )

        func painted(shift: CGFloat = 0, inputs: SidebarPooledRowInputs) throws -> [Pixels] {
            try Pixels.settled(of: Self.strip(
                SidebarPooledTreeRow(row: row, inputs: inputs)
                    .padding(.top, shift)
                    .frame(height: 40, alignment: .top)
            ))
        }
        let resting = try painted(inputs: content.inputs)

        XCTAssertEqual(resting, try painted(inputs: content.inputs), "the same row paints the same")
        for (scale, (shifted, washless)) in zip(Pixels.scales, try zip(painted(shift: 1, inputs: content.inputs), painted(inputs: unlit))) {
            let base = try XCTUnwrap(resting.first { $0.width == shifted.width })
            XCTAssertNotEqual(base, shifted, "1 pt at \(scale)x")
            XCTAssertNotEqual(base, washless, "the wash at \(scale)x")
        }
    }

    // MARK: Helpers

    private static func page(_ content: some View) -> some View {
        content
            .frame(width: 260, height: 760, alignment: .top)
            .background(Color.black)
    }

    /// Rows at the width the page's 8 pt gutters leave them.
    private static func strip(_ rows: some View) -> some View {
        rows
            .frame(width: 244, alignment: .top)
            .background(Color.black)
    }

    /// A live page's row: its row view from the live builders, in the container
    /// both pages share, with no interaction layer.
    @ViewBuilder
    private static func restingRow(
        _ row: SidebarTreeRow,
        list: SidebarLiveTreeList,
        inputs: SidebarLiveRowInputs,
        lit: Set<String>
    ) -> some View {
        switch row.content {
        case let .projectHeader(node, isExpanded):
            SidebarProjectHeaderRow(
                row: row,
                rowView: list.headerRowView(node, row: row, isExpanded: isExpanded, inputs: inputs),
                highlightedFolderIDs: lit
            )
        case let .folderHeader(node, isExpanded):
            SidebarFolderHeaderRow(
                row: row,
                node: node,
                rowView: list.headerRowView(node, row: row, isExpanded: isExpanded, inputs: inputs),
                highlightedFolderIDs: lit
            )
        case let .session(entry):
            SidebarSessionRow(
                row: row,
                sessionID: entry.id,
                rowView: list.sessionRowView(entry, ownerID: row.listOwnerID, depth: row.depth),
                highlightedFolderIDs: lit
            )
        case let .emptyPlaceholder(owner):
            SidebarPlaceholderRow(
                row: row,
                ownerID: owner.id,
                rowView: list.placeholderRowView(owner, depth: row.depth, inputs: inputs),
                highlightedFolderIDs: lit
            )
        }
    }

    /// One swipe onto a local workspace: the store sits in Local with the
    /// neighbor's snapshot pooled, and `commit` lands the scope switch.
    @MainActor
    private final class WorkspaceSwipe {
        static let home = UnpeelWorkspaceRegistry.normalizePath(
            LaunchConfig.unpeelDir.appendingPathComponent("scope-parity").path
        )
        static let macID = "parity-host"
        static let selected = "group-selected"
        /// Expansion, keyed the way both pages read it: every folder is open
        /// but the two that show collapsed marks.
        static let expanded = ["alpha", "pinnedGroup", "group", "inner", "emptyGroup", "dated", "topGroup", "empty"]

        let store: UnpeelStore
        let neighbor: WorkspaceListRowModel
        private let expansionKey = UnpeelStore.expandedProjectsKey + "." + WorkspaceSwipe.macID

        init(
            neighborKind: WorkspaceListRowModel.Kind = .local(
                record: nil, isDefault: false, isCurrentInstance: false, isRunning: true
            )
        ) throws {
            AppDefaults.shared.set(Self.expanded, forKey: expansionKey)
            store = UnpeelStore.sidebarFixture(snapshot: Self.localTree, expandedProjectIDs: [])
            // The neighbor's pane group, where both pages read it.
            let panes = store.paneLayoutController
            panes.switchScope(to: "workspace:\(Self.home)")
            try panes.mutate {
                try $0.createGroup(representativeSessionID: "pane-main", adding: "pane-member", at: .right)
            }
            panes.switchScope(to: store.selectedHostScope.paneScopeID)
            neighbor = WorkspaceListRowModel(
                id: "workspace:parity", name: "Parity", detail: "", icon: "", badge: nil,
                home: Self.home, tint: .none,
                kind: neighborKind
            )
            let key = neighbor.id
            // An excluded key keeps its pooled snapshot and opens no connection.
            // The foreground key keeps the fixture's attention rows from posting
            // a real notification.
            store.workspacePool.start(targetsProvider: { [] }, excludedKeys: { [key] }, foregroundKey: { key })
            store.workspacePool.noteExternalSnapshot(Self.workspaceTree, forKey: key, name: neighbor.name)
            SidebarListContentBuilder.invalidate()
        }

        func commit() {
            scope(to: Self.workspaceTree)
            store.selectedSessionID = Self.selected
        }

        /// To a scope that shares nothing with the neighbor's tree.
        func scopeAway() {
            scope(to: Self.localTree)
        }

        private func scope(to tree: RemoteBootstrapSnapshot) {
            store.selectLocalWorkspace(home: Self.home, name: neighbor.name)
            store.remoteHostRuntime.holdSnapshotForTesting(tree)
            store.projectRemoteScope(snapshot: tree)
        }

        func livePanel(controller: SidebarSessionDragController = SidebarSessionDragController()) -> some View {
            SidebarProjectTreePanel(
                store: store,
                dragState: SidebarDragState(),
                sessionDragController: controller
            )
        }

        func finish() {
            store.workspacePool.stop()
            SidebarListContentBuilder.invalidate()
            AppDefaults.shared.removeObject(forKey: expansionKey)
        }

        private static let localTree = RemoteBootstrapSnapshot(
            folders: [],
            projects: [RemoteProjectSummary(id: "local", name: "local", path: "/fixture/local", sortOrder: 0)],
            presets: [],
            sessions: [],
            capturedAtUnixMs: 1
        )

        /// Every row kind and the marks both pages can show, nothing busy: a
        /// spinner or a shimmer is never at rest. The selected Session is
        /// the first blocked one, which makes it the workspace's default
        /// selection on the pooled page. It sits two groups deep to light both
        /// washes.
        static let workspaceTree: RemoteBootstrapSnapshot = {
            let threeDaysAgo = Int64(Date().timeIntervalSince1970 * 1000) - 3 * 86_400_000
            func session(
                _ id: String,
                in project: String,
                status: RemoteSessionStatus = .running,
                activity: RemoteActivityState = .idle,
                unread: Bool = false,
                pinned: Bool = false
            ) -> RemoteSessionSummary {
                RemoteSessionSummary(
                    id: id,
                    projectID: project,
                    title: id,
                    command: "zsh",
                    createdAtUnixMs: threeDaysAgo,
                    status: status,
                    activity: activity,
                    unread: unread,
                    pinned: pinned
                )
            }
            return RemoteBootstrapSnapshot(
                macID: macID,
                folders: [],
                projects: [
                    RemoteProjectSummary(id: "alpha", name: "alpha", path: "/fixture/alpha", colorID: "violet", sortOrder: 0),
                    RemoteProjectSummary(id: "pinnedGroup", name: "pinned group", path: "/fixture/pg", parentProjectID: "alpha", isGroup: true, pinned: true, sortOrder: 1),
                    RemoteProjectSummary(id: "group", name: "group", path: "/fixture/group", parentProjectID: "alpha", isGroup: true, sortOrder: 2),
                    RemoteProjectSummary(id: "inner", name: "inner", path: "/fixture/inner", parentProjectID: "group", isGroup: true, sortOrder: 3),
                    RemoteProjectSummary(id: "emptyGroup", name: "empty group", path: "/fixture/eg", parentProjectID: "group", isGroup: true, sortOrder: 4),
                    RemoteProjectSummary(id: "worktree", name: "worktree", path: "/fixture/wt", parentProjectID: "alpha", worktreeBranch: "feature", sortOrder: 5),
                    RemoteProjectSummary(id: "attention", name: "attention", path: "/fixture/at", parentProjectID: "alpha", isGroup: true, sortOrder: 6),
                    RemoteProjectSummary(id: "dated", name: "dated", path: "/fixture/dated", colorID: "teal", sortOrder: 7, dateSorted: true),
                    RemoteProjectSummary(id: "topGroup", name: "top group", path: "/fixture/tg", isGroup: true, sortOrder: 8),
                    RemoteProjectSummary(id: "collapsed", name: "collapsed", path: "/fixture/collapsed", sortOrder: 9),
                    RemoteProjectSummary(id: "empty", name: "empty", path: "/fixture/empty", sortOrder: 10),
                ],
                presets: [],
                sessions: [
                    session(selected, in: "inner", activity: .blocked),
                    session("inner-plain", in: "inner"),
                    session("alpha-plain", in: "alpha"),
                    session("alpha-pinned", in: "alpha", pinned: true),
                    session("alpha-unread", in: "alpha", unread: true),
                    session("alpha-stopped", in: "alpha", status: .exited),
                    session("pane-main", in: "alpha"),
                    session("pane-member", in: "alpha"),
                    session("pinned-group-plain", in: "pinnedGroup"),
                    session("worktree-unread", in: "worktree", unread: true),
                    session("attention-blocked", in: "attention", activity: .blocked),
                    session("dated-plain", in: "dated"),
                    session("top-plain", in: "topGroup"),
                    session("collapsed-unread", in: "collapsed", unread: true),
                ],
                capturedAtUnixMs: 2
            )
        }()
    }
}

/// An off-screen window has no screen to take a scale from, so it says which
/// one it renders at: a window's own backing scale is what sets its raster. A
/// 1x bitmap of a 2x window is not what a 1x display shows.
private final class ScaledWindow: NSWindow {
    var scale: CGFloat = 2
    override var backingScaleFactor: CGFloat { scale }
}

/// A view's raster at one scale, in an off-screen window.
private struct Pixels: Equatable {
    static let scales: [CGFloat] = [1, 2]
    static let appearances: [NSAppearance.Name] = [.darkAqua, .aqua]

    let width: Int
    let height: Int
    let bytes: Data

    /// Hosts a view in a real window for as long as `body` runs.
    @MainActor
    static func hosting<Content: View>(
        _ view: Content,
        appearance: NSAppearance.Name = .darkAqua,
        scale: CGFloat = 2,
        body: (NSHostingView<Content>) throws -> Void
    ) throws {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = ScaledWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.scale = scale
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        flush(host)
        try body(host)
    }

    @MainActor
    private static func flush(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
        host.display()
    }

    /// One bitmap per scale, once the view holds still, which waits out what
    /// animates in as it appears (a lit wash fades in over 120 ms).
    @MainActor
    static func settled(
        of view: some View,
        appearance: NSAppearance.Name = .darkAqua
    ) throws -> [Pixels] {
        try scales.map { scale in
            var settled: Pixels?
            try hosting(view, appearance: appearance, scale: scale) { host in
                var stillTurns = 0
                for _ in 0 ..< 100 where stillTurns < 3 {
                    let now = try capture(host, scale: scale)
                    stillTurns = now == settled ? stillTurns + 1 : 0
                    settled = now
                    flush(host)
                }
                XCTAssertEqual(stillTurns, 3, "the view never held still")
            }
            return try XCTUnwrap(settled)
        }
    }

    static func assertEqual(
        _ first: [Pixels],
        _ second: [Pixels],
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (scale, (one, other)) in zip(scales, zip(first, second)) {
            one.assertEqual(to: other, "\(name) at \(Int(scale))x", file: file, line: line)
        }
    }

    @MainActor
    private static func capture(_ view: NSView, scale: CGFloat) throws -> Pixels {
        let bounds = view.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ))
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        let bytes = try XCTUnwrap(rep.bitmapData)
        return Pixels(
            width: rep.pixelsWide,
            height: rep.pixelsHigh,
            bytes: Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        )
    }

    /// True when every pixel is the same, as a failed capture would be.
    var isBlank: Bool {
        guard bytes.count >= 4 else { return true }
        let first = bytes.prefix(4)
        return stride(from: 0, to: bytes.count, by: 4).allSatisfy {
            bytes[bytes.startIndex + $0 ..< bytes.startIndex + $0 + 4] == first
        }
    }

    private func assertEqual(
        to other: Pixels,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard self != other else { return }
        guard width == other.width, height == other.height else {
            XCTFail("\(name): \(width)x\(height) vs \(other.width)x\(other.height)", file: file, line: line)
            return
        }
        var differing = 0
        var box = (minX: width, minY: height, maxX: -1, maxY: -1)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let start = (y * width + x) * 4
                guard bytes[start ..< start + 4] != other.bytes[start ..< start + 4] else { continue }
                differing += 1
                box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            }
        }
        let paths = [("first", self), ("second", other)].map { label, pixels in
            pixels.writePNG(named: "parity-\(name)-\(label)".replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "-"))
        }
        XCTFail(
            "\(name): \(differing) of \(width * height) pixels differ, x \(box.minX)...\(box.maxX), y \(box.minY)...\(box.maxY); \(paths)",
            file: file,
            line: line
        )
    }

    /// Both sides of a failure, to look at.
    private func writePNG(named name: String) -> String {
        var planes: UnsafeMutablePointer<UInt8>? = UnsafeMutablePointer(mutating: (bytes as NSData).bytes.assumingMemoryBound(to: UInt8.self))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: &planes,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let png = rep.representation(using: .png, properties: [:]) else {
            return "no PNG for \(name)"
        }
        do {
            try png.write(to: url)
            return url.path
        } catch {
            return "no PNG for \(name): \(error)"
        }
    }
}
