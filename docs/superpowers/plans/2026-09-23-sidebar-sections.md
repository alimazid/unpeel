# Sidebar Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Mac app's left sidebar into a VS Code-style stack of collapsible, resizable sections — PROJECTS on top, EXPLORER below — and remove the separate explorer column.

**Architecture:** A pure value type (`SidebarSectionLayout`) owns visibility, collapse and height weights plus all layout maths; a small `ObservableObject` store persists it in `AppDefaults.shared`. A generic SwiftUI container (`SidebarSectionStack`) draws headers, separators and drag dividers around section content supplied as descriptors. Upstream's sidebar hands its project-list area to the stack through one marked hook; the explorer's view model moves to a long-lived owner so the section header can show its menu.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, macOS 13 deployment target, XCTest. Package at `clients/native/UnpeelNative` (targets `UnpeelNative`, `UnpeelExplorer`).

**Spec:** `docs/superpowers/specs/2026-09-23-sidebar-sections-design.md`

## Global Constraints

- Fork-only feature. Every edit to an upstream file sits in a block whose comment starts `Fork-only: sidebar sections`. New code lives in new files under `clients/native/UnpeelNative/Sources/UnpeelNative/Views/SidebarSections/`.
- Upstream files this plan may edit, and no others: `Views/SidebarView.swift`, `Views/SidebarWorkspaceDots.swift`, `Views/RootView.swift`, `AppDelegate.swift`. Fork-only files it edits: `Views/ExplorerPanelHost.swift`, `UnpeelExplorer/ExplorerPanelView.swift`; it deletes `ExplorerPanelState.swift` and `Tests/UnpeelNativeTests/ExplorerPanelStateTests.swift`.
- Sections: `projects`, `explorer` (in that default order). Titles `PROJECTS`, `EXPLORER`. Minimum content heights: PROJECTS 80 pt, EXPLORER 120 pt.
- Header height 22 pt; separator 1 pt (`Theme.paneDividerLine`, hover/drag `Theme.paneDividerLineHover`); divider hit area 6 pt tall.
- Default layout: both visible, both expanded, weights PROJECTS 0.4, EXPLORER 0.6.
- Persistence key `unpeel.sidebarSections.layout` in `AppDefaults.shared`, JSON, `version` 1. Legacy keys `unpeel.explorer.visible` and `unpeel.explorer.width` are removed on load and never carried over.
- Collapse/expand/hide animations use `.easeInOut(duration: 0.15)` and must be implicit animations scoped to the section stack (never `withAnimation` from the app delegate, never a window-wide transaction). Divider drags are not animated.
- Layout operations return new values; never mutate a layout in place from outside the type.
- ⇧⌘E: if the tree has focus and EXPLORER is visible and expanded and the sidebar is not collapsed → collapse EXPLORER and focus the active terminal pane; otherwise un-collapse the sidebar, show + expand EXPLORER, and focus the outline. Menu title "Hide Explorer" exactly in the first case, else "Show Explorer".
- Never write to, launch or quit `/Applications/Unpeel.app`. Runtime checks use `clients/native/dev-blank.sh` with `UNPEEL_HOME=~/unpeel-dev-explorer-home`.
- Only one agent commits in this checkout at a time. A git hook rejects any command line containing `git commit` together with a `-n` flag anywhere; run `git commit` on its own line.
- Commit messages: conventional (`feat:`, `test:`, `refactor:`, `docs:`), ending with the line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Build: `cd clients/native/UnpeelNative && swift build`. Focused tests: `swift test --filter <TestClass>` from the same directory (compiles the whole package). Full gate: `clients/native/test-native.sh` from the repo root — expected `Executed N tests, with 1 test skipped and 0 failures` (the skip is upstream's).

---

## File map

| File | Responsibility |
|---|---|
| `Views/SidebarSections/SidebarSectionID.swift` (new) | The section ids, titles, minimum heights |
| `Views/SidebarSections/SidebarSectionLayout.swift` (new) | The layout value + pure maths + JSON encode/decode |
| `Views/SidebarSections/SidebarSectionLayoutStore.swift` (new) | Persisted, observable current layout; legacy-key cleanup |
| `Views/SidebarSections/ExplorerFocusCommand.swift` (new) | Pure ⇧⌘E decision + menu title |
| `Views/SidebarSections/SidebarSectionMetrics.swift` (new) | Header/separator/inset constants |
| `Views/SidebarSections/SidebarSectionHeader.swift` (new) | Header row |
| `Views/SidebarSections/SidebarSectionDivider.swift` (new) | Separator + drag handle |
| `Views/SidebarSections/SidebarSectionStack.swift` (new) | Generic stack container + descriptor type |
| `Views/SidebarSections/SidebarSectionContents.swift` (new) | PROJECTS header actions, EXPLORER title accessory, `ExplorerSectionModel` |
| `Views/SidebarSections/ExplorerFocus.swift` (new) | Find / focus the explorer outline in a window |
| `UnpeelExplorer/ExplorerPanelView.swift` | `showsHeader`, `rootName(for:)`, public `ExplorerPanelMenu` |
| `Views/ExplorerPanelHost.swift` | View model injected from `ExplorerSectionModel`; static context resolver; tears down on disappear |
| `Views/SidebarView.swift` | Hook: list area → section stack; drops + swipe monitor scoped to PROJECTS; takes `cache` |
| `Views/SidebarWorkspaceDots.swift` | Carousel top inset + fade ramp for in-section lists |
| `Views/RootView.swift` | Remove explorer column; pass `cache` to `SidebarView` |
| `AppDelegate.swift` | ⇧⌘E through `ExplorerFocusCommand` |

All paths below are relative to `clients/native/UnpeelNative/` unless they start with `docs/` or `clients/`.

---

### Task 1: Section layout model

**Files:**
- Create: `Sources/UnpeelNative/Views/SidebarSections/SidebarSectionID.swift`
- Create: `Sources/UnpeelNative/Views/SidebarSections/SidebarSectionLayout.swift`
- Test: `Tests/UnpeelNativeTests/SidebarSectionLayoutTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SidebarSectionID: String, CaseIterable, Sendable { case projects, explorer }` with `var title: String` and `var minimumContentHeight: CGFloat`, and `static var minimumContentHeights: [SidebarSectionID: CGFloat]`.
  - `struct SidebarSectionLayout: Equatable, Sendable` with `init(order:hidden:collapsed:weights:)`, `static let default`, `static let currentVersion = 1`, `static let defaultWeights`, read-only `order`, `hidden`, `collapsed`, `weights`, and:
    - `var visible: [SidebarSectionID]`, `var expanded: [SidebarSectionID]`
    - `func isVisible(_:) -> Bool`, `func isExpanded(_:) -> Bool`, `func weight(of:) -> Double`
    - `func contentSpace(available:headerHeight:separatorHeight:) -> CGFloat`
    - `func contentHeights(space:minimums:) -> [SidebarSectionID: CGFloat]`
    - `func resizing(upper:lower:by:space:minimums:) -> SidebarSectionLayout`
    - `func togglingCollapse(_:) -> SidebarSectionLayout`, `func settingCollapsed(_:_:) -> SidebarSectionLayout`, `func settingHidden(_:_:) -> SidebarSectionLayout`, `func revealing(_:) -> SidebarSectionLayout`
    - `func encoded() -> Data`, `static func decode(_ data: Data?) -> SidebarSectionLayout`

- [ ] **Step 1: Write the failing tests**

Create `Tests/UnpeelNativeTests/SidebarSectionLayoutTests.swift`:

```swift
import XCTest
@testable import UnpeelNative

final class SidebarSectionLayoutTests: XCTestCase {
    private let minimums: [SidebarSectionID: CGFloat] = [.projects: 80, .explorer: 120]

    // MARK: Defaults

    func testDefaultLayoutShowsAndExpandsBothSections() {
        let layout = SidebarSectionLayout.default
        XCTAssertEqual(layout.order, [.projects, .explorer])
        XCTAssertEqual(layout.visible, [.projects, .explorer])
        XCTAssertEqual(layout.expanded, [.projects, .explorer])
        XCTAssertEqual(layout.weight(of: .projects), 0.4, accuracy: 1e-9)
        XCTAssertEqual(layout.weight(of: .explorer), 0.6, accuracy: 1e-9)
    }

    func testIdsCarryTitlesAndMinimums() {
        XCTAssertEqual(SidebarSectionID.projects.title, "PROJECTS")
        XCTAssertEqual(SidebarSectionID.explorer.title, "EXPLORER")
        XCTAssertEqual(SidebarSectionID.minimumContentHeights, [.projects: 80, .explorer: 120])
    }

    // MARK: Heights

    func testContentSpaceSubtractsHeadersAndSeparators() {
        let layout = SidebarSectionLayout.default
        XCTAssertEqual(layout.contentSpace(available: 600, headerHeight: 22, separatorHeight: 1), 600 - 44 - 1)
        let oneVisible = layout.settingHidden(.explorer, true)
        XCTAssertEqual(oneVisible.contentSpace(available: 600, headerHeight: 22, separatorHeight: 1), 578)
        XCTAssertEqual(layout.contentSpace(available: 10, headerHeight: 22, separatorHeight: 1), 0)
    }

    func testHeightsFollowWeightsWhenMinimumsFit() {
        let heights = SidebarSectionLayout.default.contentHeights(space: 500, minimums: minimums)
        XCTAssertEqual(heights[.projects]!, 200, accuracy: 1e-6)
        XCTAssertEqual(heights[.explorer]!, 300, accuracy: 1e-6)
    }

    func testSingleExpandedSectionTakesAllSpace() {
        let layout = SidebarSectionLayout.default.settingCollapsed(.projects, true)
        XCTAssertEqual(layout.contentHeights(space: 500, minimums: minimums), [.explorer: 500])
    }

    func testNoExpandedSectionsGiveNoHeights() {
        let layout = SidebarSectionLayout.default
            .settingCollapsed(.projects, true)
            .settingCollapsed(.explorer, true)
        XCTAssertEqual(layout.contentHeights(space: 500, minimums: minimums), [:])
    }

    func testSectionBelowMinimumIsPinnedAndTheRestShared() {
        // 0.1 of 300 = 30 < 80 → projects pinned at 80, explorer gets 220.
        let layout = SidebarSectionLayout(
            order: [.projects, .explorer], hidden: [], collapsed: [],
            weights: [.projects: 0.1, .explorer: 0.9]
        )
        let heights = layout.contentHeights(space: 300, minimums: minimums)
        XCTAssertEqual(heights[.projects]!, 80, accuracy: 1e-6)
        XCTAssertEqual(heights[.explorer]!, 220, accuracy: 1e-6)
    }

    func testShortSpaceGivesMinimumsTopDownAndCompressesTheBottom() {
        let heights = SidebarSectionLayout.default.contentHeights(space: 150, minimums: minimums)
        XCTAssertEqual(heights[.projects]!, 80, accuracy: 1e-6)
        XCTAssertEqual(heights[.explorer]!, 70, accuracy: 1e-6)
        let tiny = SidebarSectionLayout.default.contentHeights(space: 50, minimums: minimums)
        XCTAssertEqual(tiny[.projects]!, 50, accuracy: 1e-6)
        XCTAssertEqual(tiny[.explorer]!, 0, accuracy: 1e-6)
    }

    // MARK: Divider

    func testDividerDragMovesHeightBetweenNeighbours() {
        let resized = SidebarSectionLayout.default.resizing(
            upper: .projects, lower: .explorer, by: 50, space: 500, minimums: minimums
        )
        let heights = resized.contentHeights(space: 500, minimums: minimums)
        XCTAssertEqual(heights[.projects]!, 250, accuracy: 1e-6)
        XCTAssertEqual(heights[.explorer]!, 250, accuracy: 1e-6)
        XCTAssertEqual(resized.weight(of: .projects) + resized.weight(of: .explorer), 1.0, accuracy: 1e-9)
    }

    func testDividerDragClampsAtBothMinimums() {
        let up = SidebarSectionLayout.default.resizing(
            upper: .projects, lower: .explorer, by: -1000, space: 500, minimums: minimums
        ).contentHeights(space: 500, minimums: minimums)
        XCTAssertEqual(up[.projects]!, 80, accuracy: 1e-6)
        XCTAssertEqual(up[.explorer]!, 420, accuracy: 1e-6)

        let down = SidebarSectionLayout.default.resizing(
            upper: .projects, lower: .explorer, by: 1000, space: 500, minimums: minimums
        ).contentHeights(space: 500, minimums: minimums)
        XCTAssertEqual(down[.projects]!, 380, accuracy: 1e-6)
        XCTAssertEqual(down[.explorer]!, 120, accuracy: 1e-6)
    }

    func testDividerDragIsIgnoredWhenANeighbourIsCollapsed() {
        let layout = SidebarSectionLayout.default.settingCollapsed(.explorer, true)
        XCTAssertEqual(
            layout.resizing(upper: .projects, lower: .explorer, by: 50, space: 500, minimums: minimums),
            layout
        )
    }

    // MARK: Collapse / hide

    func testCollapseKeepsWeightAndExpandRestoresIt() {
        let collapsed = SidebarSectionLayout.default.togglingCollapse(.explorer)
        XCTAssertFalse(collapsed.isExpanded(.explorer))
        XCTAssertTrue(collapsed.isVisible(.explorer))
        XCTAssertEqual(collapsed.contentHeights(space: 500, minimums: minimums), [.projects: 500])
        let expanded = collapsed.togglingCollapse(.explorer)
        XCTAssertEqual(expanded, SidebarSectionLayout.default)
    }

    func testHidingTheLastVisibleSectionIsRefused() {
        let one = SidebarSectionLayout.default.settingHidden(.projects, true)
        XCTAssertEqual(one.visible, [.explorer])
        XCTAssertEqual(one.settingHidden(.explorer, true), one)
        XCTAssertEqual(one.settingHidden(.projects, false).visible, [.projects, .explorer])
    }

    func testRevealingShowsAndExpands() {
        let hidden = SidebarSectionLayout.default
            .settingCollapsed(.explorer, true)
            .settingHidden(.explorer, true)
        let revealed = hidden.revealing(.explorer)
        XCTAssertTrue(revealed.isExpanded(.explorer))
        XCTAssertEqual(revealed.visible, [.projects, .explorer])
    }

    // MARK: Persistence

    func testEncodeDecodeRoundTrip() {
        let layout = SidebarSectionLayout.default
            .resizing(upper: .projects, lower: .explorer, by: 30, space: 500, minimums: minimums)
            .settingCollapsed(.explorer, true)
        XCTAssertEqual(SidebarSectionLayout.decode(layout.encoded()), layout)
    }

    func testDecodeFallsBackToDefaultForNilGarbageAndUnknownVersion() {
        XCTAssertEqual(SidebarSectionLayout.decode(nil), .default)
        XCTAssertEqual(SidebarSectionLayout.decode(Data("not json".utf8)), .default)
        let future = #"{"version":2,"order":["explorer"],"hidden":[],"collapsed":[],"weights":{}}"#
        XCTAssertEqual(SidebarSectionLayout.decode(Data(future.utf8)), .default)
    }

    func testDecodeDropsUnknownIdsAndAppendsMissingKnownOnes() {
        let json = #"{"version":1,"order":["explorer","gitHistory"],"hidden":["gitHistory"],"collapsed":["explorer"],"weights":{"explorer":0.7,"gitHistory":0.3}}"#
        let layout = SidebarSectionLayout.decode(Data(json.utf8))
        XCTAssertEqual(layout.order, [.explorer, .projects])
        XCTAssertEqual(layout.hidden, [])
        XCTAssertEqual(layout.collapsed, [.explorer])
        XCTAssertEqual(layout.weight(of: .explorer), 0.7, accuracy: 1e-9)
        XCTAssertEqual(layout.weight(of: .projects), 0.4, accuracy: 1e-9)
    }

    func testDecodeNeverHidesEverySection() {
        let json = #"{"version":1,"order":["projects","explorer"],"hidden":["projects","explorer"],"collapsed":[],"weights":{}}"#
        XCTAssertEqual(SidebarSectionLayout.decode(Data(json.utf8)).visible, [.projects, .explorer])
    }

    func testDecodeIgnoresNonPositiveOrNonFiniteWeights() {
        let json = #"{"version":1,"order":["projects","explorer"],"hidden":[],"collapsed":[],"weights":{"projects":-1,"explorer":0}}"#
        let layout = SidebarSectionLayout.decode(Data(json.utf8))
        XCTAssertEqual(layout.weight(of: .projects), 0.4, accuracy: 1e-9)
        XCTAssertEqual(layout.weight(of: .explorer), 0.6, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd clients/native/UnpeelNative && swift test --filter SidebarSectionLayoutTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'SidebarSectionLayout' in scope`.

- [ ] **Step 3: Write `SidebarSectionID.swift`**

```swift
//
//  SidebarSectionID.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The sections the left sidebar stacks, in
//  their default top-to-bottom order. A later section (Git History) is one
//  more case here; saved layouts pick it up without a migration
//  (`SidebarSectionLayout.decode` appends missing ids).
//

import CoreGraphics

enum SidebarSectionID: String, CaseIterable, Sendable {
    case projects
    case explorer

    var title: String {
        switch self {
        case .projects: return "PROJECTS"
        case .explorer: return "EXPLORER"
        }
    }

    /// Smallest content height (header excluded) a divider drag or a
    /// neighbour's growth may leave this section with.
    var minimumContentHeight: CGFloat {
        switch self {
        case .projects: return 80
        case .explorer: return 120
        }
    }

    static var minimumContentHeights: [SidebarSectionID: CGFloat] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.minimumContentHeight) })
    }
}
```

- [ ] **Step 4: Write `SidebarSectionLayout.swift`**

```swift
//
//  SidebarSectionLayout.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. Which sections are shown, which are
//  collapsed to their header, and how the expanded ones share the height.
//  A plain value: every operation returns a new layout, and all of the
//  layout maths lives here so it is testable without SwiftUI.
//

import CoreGraphics
import Foundation

struct SidebarSectionLayout: Equatable, Sendable {
    static let currentVersion = 1
    static let defaultWeights: [SidebarSectionID: Double] = [.projects: 0.4, .explorer: 0.6]
    /// Weight for an id with neither a stored nor a default weight.
    static let fallbackWeight = 0.5
    /// Floor so a section dragged to zero can still be proportioned.
    private static let minimumWeight = 0.0001

    private(set) var order: [SidebarSectionID]
    private(set) var hidden: Set<SidebarSectionID>
    private(set) var collapsed: Set<SidebarSectionID>
    private(set) var weights: [SidebarSectionID: Double]

    init(
        order: [SidebarSectionID],
        hidden: Set<SidebarSectionID>,
        collapsed: Set<SidebarSectionID>,
        weights: [SidebarSectionID: Double]
    ) {
        self.order = order
        self.hidden = hidden
        self.collapsed = collapsed
        self.weights = weights
    }

    static let `default` = SidebarSectionLayout(
        order: SidebarSectionID.allCases,
        hidden: [],
        collapsed: [],
        weights: defaultWeights
    )

    var visible: [SidebarSectionID] { order.filter { !hidden.contains($0) } }
    var expanded: [SidebarSectionID] { visible.filter { !collapsed.contains($0) } }

    func isVisible(_ id: SidebarSectionID) -> Bool { !hidden.contains(id) }
    func isExpanded(_ id: SidebarSectionID) -> Bool { isVisible(id) && !collapsed.contains(id) }

    func weight(of id: SidebarSectionID) -> Double {
        max(weights[id] ?? Self.defaultWeights[id] ?? Self.fallbackWeight, Self.minimumWeight)
    }

    // MARK: - Heights

    /// Height left for section content once every visible header and the
    /// separators between visible sections are laid out.
    func contentSpace(available: CGFloat, headerHeight: CGFloat, separatorHeight: CGFloat) -> CGFloat {
        let count = CGFloat(visible.count)
        return max(0, available - count * headerHeight - max(0, count - 1) * separatorHeight)
    }

    /// Content height of every expanded section for `space` points:
    /// proportional to the weights, never below a section's minimum while
    /// the minimums fit. When they do not fit, sections get their minimum
    /// top-down and the bottom-most expanded sections are compressed first.
    func contentHeights(space: CGFloat, minimums: [SidebarSectionID: CGFloat]) -> [SidebarSectionID: CGFloat] {
        let ids = expanded
        guard !ids.isEmpty else { return [:] }
        let space = max(0, space)
        func minimum(_ id: SidebarSectionID) -> CGFloat { max(0, minimums[id] ?? 0) }

        if ids.map(minimum).reduce(0, +) >= space {
            var remaining = space
            var result: [SidebarSectionID: CGFloat] = [:]
            for id in ids {
                let height = min(minimum(id), remaining)
                result[id] = height
                remaining -= height
            }
            return result
        }

        // Proportional split; any section that would fall below its minimum
        // is pinned there and the rest re-split. Each pass pins at least one
        // section, and at least one always stays free (the minimums fit), so
        // this terminates within `ids.count` passes.
        var pinned: [SidebarSectionID: CGFloat] = [:]
        while true {
            let free = ids.filter { pinned[$0] == nil }
            let freeSpace = space - pinned.values.reduce(0, +)
            let totalWeight = free.map(weight(of:)).reduce(0, +)
            let proposed = Dictionary(uniqueKeysWithValues: free.map {
                ($0, freeSpace * CGFloat(weight(of: $0) / totalWeight))
            })
            let short = free.filter { proposed[$0, default: 0] < minimum($0) }
            if short.isEmpty {
                return pinned.merging(proposed) { pinnedHeight, _ in pinnedHeight }
            }
            for id in short {
                pinned[id] = minimum(id)
            }
        }
    }

    /// The layout after dragging the separator between `upper` and `lower`
    /// (adjacent visible sections, both expanded) by `delta` points —
    /// positive moves it down, so `upper` grows. Only those two weights
    /// change; their content heights are clamped to their minimums.
    func resizing(
        upper: SidebarSectionID,
        lower: SidebarSectionID,
        by delta: CGFloat,
        space: CGFloat,
        minimums: [SidebarSectionID: CGFloat]
    ) -> SidebarSectionLayout {
        guard isExpanded(upper), isExpanded(lower) else { return self }
        let heights = contentHeights(space: space, minimums: minimums)
        guard let upperHeight = heights[upper], let lowerHeight = heights[lower] else { return self }
        let pair = upperHeight + lowerHeight
        let minUpper = max(0, minimums[upper] ?? 0)
        let minLower = max(0, minimums[lower] ?? 0)
        guard pair > 0, pair >= minUpper + minLower else { return self }
        let newUpper = min(max(upperHeight + delta, minUpper), pair - minLower)
        let pairWeight = weight(of: upper) + weight(of: lower)
        var next = weights
        next[upper] = pairWeight * Double(newUpper / pair)
        next[lower] = pairWeight * Double((pair - newUpper) / pair)
        return with(weights: next)
    }

    // MARK: - Collapse / hide

    func togglingCollapse(_ id: SidebarSectionID) -> SidebarSectionLayout {
        settingCollapsed(id, !collapsed.contains(id))
    }

    func settingCollapsed(_ id: SidebarSectionID, _ isCollapsed: Bool) -> SidebarSectionLayout {
        var next = collapsed
        if isCollapsed { next.insert(id) } else { next.remove(id) }
        return with(collapsed: next)
    }

    /// Hides or shows a section. Hiding the only visible section is refused
    /// (returns `self`): the sidebar never shows an empty stack.
    func settingHidden(_ id: SidebarSectionID, _ isHidden: Bool) -> SidebarSectionLayout {
        if isHidden, visible == [id] { return self }
        var next = hidden
        if isHidden { next.insert(id) } else { next.remove(id) }
        return with(hidden: next)
    }

    /// Shown and expanded (⇧⌘E).
    func revealing(_ id: SidebarSectionID) -> SidebarSectionLayout {
        settingHidden(id, false).settingCollapsed(id, false)
    }

    private func with(
        hidden: Set<SidebarSectionID>? = nil,
        collapsed: Set<SidebarSectionID>? = nil,
        weights: [SidebarSectionID: Double]? = nil
    ) -> SidebarSectionLayout {
        SidebarSectionLayout(
            order: order,
            hidden: hidden ?? self.hidden,
            collapsed: collapsed ?? self.collapsed,
            weights: weights ?? self.weights
        )
    }
}

// MARK: - Persistence

extension SidebarSectionLayout {
    /// On-disk shape. Ids are plain strings so a record written by a build
    /// with more (or fewer) sections still decodes.
    private struct Stored: Codable {
        var version: Int
        var order: [String]
        var hidden: [String]
        var collapsed: [String]
        var weights: [String: Double]
    }

    func encoded() -> Data {
        let stored = Stored(
            version: Self.currentVersion,
            order: order.map(\.rawValue),
            hidden: hidden.map(\.rawValue).sorted(),
            collapsed: collapsed.map(\.rawValue).sorted(),
            weights: Dictionary(uniqueKeysWithValues: weights.map { ($0.key.rawValue, $0.value) })
        )
        return (try? JSONEncoder().encode(stored)) ?? Data()
    }

    /// Never fails: nil, unreadable or other-version data gives `.default`;
    /// unknown ids are dropped; known ids missing from the record are
    /// appended visible and expanded with their default weight; a record
    /// that hides every section shows them all again.
    static func decode(_ data: Data?) -> SidebarSectionLayout {
        guard let data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == currentVersion
        else { return .default }

        var order: [SidebarSectionID] = []
        for raw in stored.order {
            if let id = SidebarSectionID(rawValue: raw), !order.contains(id) {
                order.append(id)
            }
        }
        for id in SidebarSectionID.allCases where !order.contains(id) {
            order.append(id)
        }

        func ids(_ raws: [String]) -> Set<SidebarSectionID> {
            Set(raws.compactMap(SidebarSectionID.init(rawValue:)))
        }
        var hidden = ids(stored.hidden)
        if hidden.count >= order.count { hidden = [] }

        var weights: [SidebarSectionID: Double] = [:]
        for (raw, value) in stored.weights {
            if let id = SidebarSectionID(rawValue: raw), value.isFinite, value > 0 {
                weights[id] = value
            }
        }
        return SidebarSectionLayout(order: order, hidden: hidden, collapsed: ids(stored.collapsed), weights: weights)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd clients/native/UnpeelNative && swift test --filter SidebarSectionLayoutTests 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 19 tests, with 0 failures`. If a test fails, fix the implementation, never the test's expected values (they are hand-computed from the spec's rules).

- [ ] **Step 6: Commit**

```bash
git add clients/native/UnpeelNative/Sources/UnpeelNative/Views/SidebarSections clients/native/UnpeelNative/Tests/UnpeelNativeTests/SidebarSectionLayoutTests.swift
git commit -m "feat(sidebar): section layout model for the sidebar section stack

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Layout store and the ⇧⌘E decision

**Files:**
- Create: `Sources/UnpeelNative/Views/SidebarSections/SidebarSectionLayoutStore.swift`
- Create: `Sources/UnpeelNative/Views/SidebarSections/ExplorerFocusCommand.swift`
- Test: `Tests/UnpeelNativeTests/SidebarSectionLayoutStoreTests.swift`
- Test: `Tests/UnpeelNativeTests/ExplorerFocusCommandTests.swift`

**Interfaces:**
- Consumes: `SidebarSectionLayout` (Task 1): `decode(_:)`, `encoded()`, `.default`.
- Produces:
  - `@MainActor final class SidebarSectionLayoutStore: ObservableObject` — `static let shared`, `static let layoutKey = "unpeel.sidebarSections.layout"`, `static let legacyExplorerKeys`, `init(defaults: UserDefaults)`, `@Published private(set) var layout: SidebarSectionLayout`, `func update(_ transform: (SidebarSectionLayout) -> SidebarSectionLayout)`.
  - `enum ExplorerCommandAction: Equatable, Sendable { case collapseExplorer, revealAndFocus }`
  - `enum ExplorerFocusCommand` — `static func action(treeFocused: Bool, explorerExpanded: Bool, explorerHidden: Bool, sidebarCollapsed: Bool) -> ExplorerCommandAction`, `static func menuTitle(for: ExplorerCommandAction) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelNativeTests/SidebarSectionLayoutStoreTests.swift`:

```swift
import XCTest
@testable import UnpeelNative

@MainActor
final class SidebarSectionLayoutStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "unpeel.sidebarSections.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testFreshDefaultsGiveTheDefaultLayout() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SidebarSectionLayoutStore(defaults: defaults).layout, .default)
    }

    func testUpdatesPersistAcrossInstances() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarSectionLayoutStore(defaults: defaults)
        store.update { $0.settingCollapsed(.explorer, true) }

        XCTAssertFalse(store.layout.isExpanded(.explorer))
        XCTAssertFalse(SidebarSectionLayoutStore(defaults: defaults).layout.isExpanded(.explorer))
    }

    func testUnchangedUpdateWritesNothing() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SidebarSectionLayoutStore(defaults: defaults)
        store.update { $0 }
        XCTAssertNil(defaults.data(forKey: SidebarSectionLayoutStore.layoutKey))
    }

    func testLegacyExplorerColumnKeysAreRemovedAndIgnored() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "unpeel.explorer.visible")
        defaults.set(333.0, forKey: "unpeel.explorer.width")

        let store = SidebarSectionLayoutStore(defaults: defaults)

        XCTAssertTrue(store.layout.isExpanded(.explorer))
        XCTAssertNil(defaults.object(forKey: "unpeel.explorer.visible"))
        XCTAssertNil(defaults.object(forKey: "unpeel.explorer.width"))
    }

    func testCorruptStoredLayoutFallsBackToDefault() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("garbage".utf8), forKey: SidebarSectionLayoutStore.layoutKey)
        XCTAssertEqual(SidebarSectionLayoutStore(defaults: defaults).layout, .default)
    }
}
```

`Tests/UnpeelNativeTests/ExplorerFocusCommandTests.swift`:

```swift
import XCTest
@testable import UnpeelNative

final class ExplorerFocusCommandTests: XCTestCase {
    func testCollapsesOnlyWhenFocusedExpandedVisibleAndSidebarOpen() {
        XCTAssertEqual(
            ExplorerFocusCommand.action(treeFocused: true, explorerExpanded: true, explorerHidden: false, sidebarCollapsed: false),
            .collapseExplorer
        )
    }

    func testEveryOtherStateRevealsAndFocuses() {
        for treeFocused in [true, false] {
            for explorerExpanded in [true, false] {
                for explorerHidden in [true, false] {
                    for sidebarCollapsed in [true, false] {
                        let collapses = treeFocused && explorerExpanded && !explorerHidden && !sidebarCollapsed
                        if collapses { continue }
                        XCTAssertEqual(
                            ExplorerFocusCommand.action(
                                treeFocused: treeFocused,
                                explorerExpanded: explorerExpanded,
                                explorerHidden: explorerHidden,
                                sidebarCollapsed: sidebarCollapsed
                            ),
                            .revealAndFocus,
                            "focused=\(treeFocused) expanded=\(explorerExpanded) hidden=\(explorerHidden) collapsed=\(sidebarCollapsed)"
                        )
                    }
                }
            }
        }
    }

    func testMenuTitles() {
        XCTAssertEqual(ExplorerFocusCommand.menuTitle(for: .collapseExplorer), "Hide Explorer")
        XCTAssertEqual(ExplorerFocusCommand.menuTitle(for: .revealAndFocus), "Show Explorer")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd clients/native/UnpeelNative && swift test --filter 'SidebarSectionLayoutStoreTests|ExplorerFocusCommandTests' 2>&1 | tail -5`
Expected: build failure, `cannot find 'SidebarSectionLayoutStore' in scope`.

- [ ] **Step 3: Write `SidebarSectionLayoutStore.swift`**

```swift
//
//  SidebarSectionLayoutStore.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The current section layout, persisted as
//  one JSON record in the app's defaults (`AppDefaults.shared`, so a dev
//  `UNPEEL_HOME` never touches the daily layout). Kept out of UnpeelStore
//  so upstream merges of the store stay conflict-free.
//

import Foundation

@MainActor
final class SidebarSectionLayoutStore: ObservableObject {
    static let shared = SidebarSectionLayoutStore(defaults: AppDefaults.shared)

    static let layoutKey = "unpeel.sidebarSections.layout"
    /// The retired explorer-column settings. Removed on load and never
    /// carried over: the explorer starts visible in the sidebar.
    static let legacyExplorerKeys = ["unpeel.explorer.visible", "unpeel.explorer.width"]

    private let defaults: UserDefaults

    @Published private(set) var layout: SidebarSectionLayout

    init(defaults: UserDefaults) {
        self.defaults = defaults
        layout = SidebarSectionLayout.decode(defaults.data(forKey: Self.layoutKey))
        for key in Self.legacyExplorerKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Replaces the layout with `transform(layout)` and saves it; a no-op
    /// when nothing changed.
    func update(_ transform: (SidebarSectionLayout) -> SidebarSectionLayout) {
        let next = transform(layout)
        guard next != layout else { return }
        layout = next
        defaults.set(next.encoded(), forKey: Self.layoutKey)
    }
}
```

- [ ] **Step 4: Write `ExplorerFocusCommand.swift`**

```swift
//
//  ExplorerFocusCommand.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The pure decision behind ⇧⌘E (View ▸
//  Show/Hide Explorer), so every branch is testable without a window.
//

enum ExplorerCommandAction: Equatable, Sendable {
    /// The tree already has focus in a visible, expanded EXPLORER section.
    case collapseExplorer
    /// Anything else: open the sidebar, show + expand EXPLORER, focus it.
    case revealAndFocus
}

enum ExplorerFocusCommand {
    static func action(
        treeFocused: Bool,
        explorerExpanded: Bool,
        explorerHidden: Bool,
        sidebarCollapsed: Bool
    ) -> ExplorerCommandAction {
        treeFocused && explorerExpanded && !explorerHidden && !sidebarCollapsed
            ? .collapseExplorer
            : .revealAndFocus
    }

    static func menuTitle(for action: ExplorerCommandAction) -> String {
        switch action {
        case .collapseExplorer: return "Hide Explorer"
        case .revealAndFocus: return "Show Explorer"
        }
    }
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd clients/native/UnpeelNative && swift test --filter 'SidebarSectionLayoutStoreTests|ExplorerFocusCommandTests' 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add clients/native/UnpeelNative/Sources/UnpeelNative/Views/SidebarSections clients/native/UnpeelNative/Tests/UnpeelNativeTests/SidebarSectionLayoutStoreTests.swift clients/native/UnpeelNative/Tests/UnpeelNativeTests/ExplorerFocusCommandTests.swift
git commit -m "feat(sidebar): persisted section layout store and the ⇧⌘E decision

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Explorer panel without its own header

**Files:**
- Modify: `Sources/UnpeelExplorer/ExplorerPanelView.swift` (whole file shown below)
- Test: `Tests/UnpeelExplorerTests/ExplorerPanelViewTests.swift` (append)

**Interfaces:**
- Consumes: existing `ExplorerViewModel` API (`model`, `filter`, `setFilter(_:)`, `refresh()`, `collapseAll()`, `context`, `rootError`, `retry()`).
- Produces:
  - `ExplorerPanelView.init(viewModel:palette:actionHandler:showsHeader: Bool = true)`
  - `public static func ExplorerPanelView.rootName(for: ExplorerContext) -> String?` — the root folder's last path component, not uppercased; nil for `.none` / `.remote`.
  - `public struct ExplorerPanelMenu: View` — `init(viewModel: ExplorerViewModel, tint: NSColor)`; `public static let itemTitles: [String]` = `["Refresh", "Collapse All", "Show Hidden Files", "Show Git-Ignored Files"]`.
  - `title(for:)` and `message(for:rootError:)` unchanged.

- [ ] **Step 1: Write the failing tests** — append inside `ExplorerPanelViewTests`:

```swift
    func testRootNameIsTheLastPathComponentOrNil() {
        XCTAssertEqual(
            ExplorerPanelView.rootName(for: .local(root: "/Users/me/my-proj", projectRoot: "/Users/me/my-proj")),
            "my-proj"
        )
        XCTAssertNil(ExplorerPanelView.rootName(for: .none))
        XCTAssertNil(ExplorerPanelView.rootName(for: .remote))
    }

    func testPanelMenuItemsInOrder() {
        XCTAssertEqual(
            ExplorerPanelMenu.itemTitles,
            ["Refresh", "Collapse All", "Show Hidden Files", "Show Git-Ignored Files"]
        )
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd clients/native/UnpeelNative && swift test --filter ExplorerPanelViewTests 2>&1 | tail -5`
Expected: build failure, `type 'ExplorerPanelView' has no member 'rootName'`.

- [ ] **Step 3: Replace `Sources/UnpeelExplorer/ExplorerPanelView.swift`** with:

```swift
import AppKit
import SwiftUI

public struct ExplorerPanelView: View {
    @ObservedObject private var viewModel: ExplorerViewModel
    private let palette: ExplorerPalette
    private let actionHandler: (any ExplorerActionHandler)?
    /// False when a host draws the title and `ExplorerPanelMenu` in its own
    /// chrome (the app's sidebar section header).
    private let showsHeader: Bool

    public init(
        viewModel: ExplorerViewModel,
        palette: ExplorerPalette,
        actionHandler: (any ExplorerActionHandler)?,
        showsHeader: Bool = true
    ) {
        self.viewModel = viewModel
        self.palette = palette
        self.actionHandler = actionHandler
        self.showsHeader = showsHeader
    }

    public static func title(for context: ExplorerContext) -> String {
        rootName(for: context)?.uppercased() ?? "EXPLORER"
    }

    /// The browsing root's folder name as it appears on disk, or nil when
    /// there is no local tree.
    public static func rootName(for context: ExplorerContext) -> String? {
        guard case .local(let root, _) = context else { return nil }
        return (root as NSString).lastPathComponent
    }

    public static func message(for context: ExplorerContext, rootError: String?) -> String? {
        switch context {
        case .none: return "Select a session to browse its files."
        case .remote: return "The explorer is available for sessions running on this Mac."
        case .local: return rootError
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                header
            }
            if let message = Self.message(for: viewModel.context, rootError: viewModel.rootError) {
                emptyState(message)
            } else {
                ExplorerOutlineView(viewModel: viewModel, palette: palette, actionHandler: actionHandler)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(Self.title(for: viewModel.context))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: palette.secondaryText))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            ExplorerPanelMenu(viewModel: viewModel, tint: palette.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: palette.secondaryText))
                .multilineTextAlignment(.center)
            if viewModel.rootError != nil {
                Button("Retry") { viewModel.retry() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The explorer's `…` menu — refresh, collapse, and visibility filters.
/// Public so a host that draws its own header shows the same menu.
public struct ExplorerPanelMenu: View {
    @ObservedObject private var viewModel: ExplorerViewModel
    private let tint: NSColor

    public static let itemTitles = ["Refresh", "Collapse All", "Show Hidden Files", "Show Git-Ignored Files"]

    public init(viewModel: ExplorerViewModel, tint: NSColor) {
        self.viewModel = viewModel
        self.tint = tint
    }

    public var body: some View {
        Menu {
            Button(Self.itemTitles[0]) { viewModel.refresh() }
            Button(Self.itemTitles[1]) { viewModel.collapseAll() }
            Divider()
            Toggle(Self.itemTitles[2], isOn: filterBinding(\.showHidden) {
                VisibilityFilter(showHidden: $0, showIgnored: viewModel.filter.showIgnored)
            })
            Toggle(Self.itemTitles[3], isOn: filterBinding(\.showIgnored) {
                VisibilityFilter(showHidden: viewModel.filter.showHidden, showIgnored: $0)
            })
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(Color(nsColor: tint))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(viewModel.model == nil)
    }

    private func filterBinding(
        _ keyPath: KeyPath<VisibilityFilter, Bool>,
        _ make: @escaping (Bool) -> VisibilityFilter
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.filter[keyPath: keyPath] },
            set: { viewModel.setFilter(make($0)) }
        )
    }
}
```

Before replacing, diff the current file's menu against this one (`git show HEAD:clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerPanelView.swift`). If the current menu has items or modifiers not listed above, keep them in `ExplorerPanelMenu` (and in `itemTitles` if they are menu items) and update the test's expected list to match — the move must not drop anything.

- [ ] **Step 4: Run to verify they pass**

Run: `cd clients/native/UnpeelNative && swift test --filter 'ExplorerPanelViewTests' 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerPanelView.swift clients/native/UnpeelNative/Tests/UnpeelExplorerTests/ExplorerPanelViewTests.swift
git commit -m "refactor(explorer): optional panel header and a shared public panel menu

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The section stack views

**Files:**
- Create: `Sources/UnpeelNative/Views/SidebarSections/SidebarSectionMetrics.swift`
- Create: `Sources/UnpeelNative/Views/SidebarSections/SidebarSectionHeader.swift`
- Create: `Sources/UnpeelNative/Views/SidebarSections/SidebarSectionDivider.swift`
- Create: `Sources/UnpeelNative/Views/SidebarSections/SidebarSectionStack.swift`
- Test: `Tests/UnpeelNativeTests/SidebarSectionStackTests.swift`

**Interfaces:**
- Consumes: `SidebarSectionID` (title, `minimumContentHeights`), `SidebarSectionLayout` (all operations), `SidebarSectionLayoutStore` (`layout`, `update`), `Theme.mutedForeground`, `Theme.paneDividerLine`, `Theme.paneDividerLineHover`, `Theme.titlebarHeight`.
- Produces:
  - `enum SidebarSectionMetrics` — `headerHeight = 22`, `separatorHeight = 1`, `dividerHitHeight = 6`, `stackTopInset = Theme.titlebarHeight`, `projectsTopInset = 4`, `projectsFadeRamp = 14`, `collapseAnimation`.
  - `struct SidebarSectionDescriptor: Identifiable` — `init(id:accessory:actions:content:)` with `accessory: AnyView`, `actions: AnyView`, `content: () -> AnyView`.
  - `struct SidebarSectionStack: View` — `init(layoutStore: SidebarSectionLayoutStore, sections: [SidebarSectionDescriptor])`.

- [ ] **Step 1: Write the failing smoke test** `Tests/UnpeelNativeTests/SidebarSectionStackTests.swift`:

```swift
import AppKit
import SwiftUI
import XCTest
@testable import UnpeelNative

/// Smoke coverage only: the maths is in `SidebarSectionLayoutTests`; this
/// proves the stack lays out real content for every layout state without
/// trapping (e.g. a zero or negative frame) — the visuals are verified at
/// runtime.
@MainActor
final class SidebarSectionStackTests: XCTestCase {
    private func makeStore() -> (SidebarSectionLayoutStore, UserDefaults, String) {
        let suite = "unpeel.sidebarSections.stack.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SidebarSectionLayoutStore(defaults: defaults), defaults, suite)
    }

    private func sections() -> [SidebarSectionDescriptor] {
        SidebarSectionID.allCases.map { id in
            SidebarSectionDescriptor(
                id: id,
                accessory: AnyView(EmptyView()),
                actions: AnyView(EmptyView()),
                content: { AnyView(Color.red) }
            )
        }
    }

    private func layOut(_ store: SidebarSectionLayoutStore, height: CGFloat) {
        let host = NSHostingView(rootView: SidebarSectionStack(layoutStore: store, sections: sections()))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.height, height)
    }

    func testLaysOutEveryLayoutState() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        layOut(store, height: 700)
        store.update { $0.settingCollapsed(.projects, true) }
        layOut(store, height: 700)
        store.update { $0.settingCollapsed(.explorer, true) }
        layOut(store, height: 700)
        store.update { $0.settingCollapsed(.projects, false).settingCollapsed(.explorer, false).settingHidden(.projects, true) }
        layOut(store, height: 700)
        layOut(store, height: 40)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clients/native/UnpeelNative && swift test --filter SidebarSectionStackTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'SidebarSectionDescriptor' in scope`.

- [ ] **Step 3: Write `SidebarSectionMetrics.swift`**

```swift
//
//  SidebarSectionMetrics.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. Geometry shared by the section stack and
//  the upstream list code it hosts.
//

import SwiftUI

enum SidebarSectionMetrics {
    static let headerHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 1
    /// Grab area of a divider, centred on its 1 pt line.
    static let dividerHitHeight: CGFloat = 6
    /// The stack starts under the traffic-light strip (a window drag area).
    static let stackTopInset: CGFloat = Theme.titlebarHeight
    /// First-row clearance inside the PROJECTS section, shared by both
    /// workspace carousel pages (was 48 pt when rows scrolled under the
    /// traffic lights; the section header now provides the separation).
    static let projectsTopInset: CGFloat = 4
    /// Height over which PROJECTS rows fade out under the section header.
    static let projectsFadeRamp: CGFloat = 14
    static let collapseAnimation = Animation.easeInOut(duration: 0.15)
}
```

- [ ] **Step 4: Write `SidebarSectionHeader.swift`**

```swift
//
//  SidebarSectionHeader.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. One section's header row: chevron, title,
//  optional accessory (e.g. the explorer's root name), and trailing
//  actions revealed on hover. A click anywhere outside the actions toggles
//  collapse; right-click lists every section to show or hide.
//

import SwiftUI

struct SidebarSectionHeader: View {
    struct VisibilityItem: Identifiable {
        let id: SidebarSectionID
        let isVisible: Bool
        let isEnabled: Bool
    }

    let title: String
    let isExpanded: Bool
    let accessory: AnyView
    let actions: AnyView
    let visibilityItems: [VisibilityItem]
    let onToggleCollapse: () -> Void
    let onSetVisible: (SidebarSectionID, Bool) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            accessory
            Spacer(minLength: 4)
            actions
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .foregroundStyle(Theme.mutedForeground)
        .padding(.horizontal, 10)
        .frame(height: SidebarSectionMetrics.headerHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCollapse)
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(visibilityItems) { item in
                Toggle(item.id.title.capitalized, isOn: Binding(
                    get: { item.isVisible },
                    set: { onSetVisible(item.id, $0) }
                ))
                .disabled(!item.isEnabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
    }
}
```

- [ ] **Step 5: Write `SidebarSectionDivider.swift`**

```swift
//
//  SidebarSectionDivider.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The visible 1 pt separator between two
//  sections; when both neighbours are expanded it is also a 6 pt drag
//  handle with the vertical resize cursor.
//

import AppKit
import SwiftUI

struct SidebarSectionDivider: View {
    let isDraggable: Bool
    /// Vertical translation since the drag began (positive = down).
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(hovering || dragging ? Theme.paneDividerLineHover : Theme.paneDividerLine)
            .frame(height: SidebarSectionMetrics.separatorHeight)
            .overlay {
                if isDraggable {
                    Color.clear
                        .frame(height: SidebarSectionMetrics.dividerHitHeight)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            hovering = inside
                            if inside {
                                NSCursor.resizeUpDown.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    dragging = true
                                    onDrag(value.translation.height)
                                }
                                .onEnded { _ in
                                    dragging = false
                                    onDragEnd()
                                }
                        )
                }
            }
    }
}
```

- [ ] **Step 6: Write `SidebarSectionStack.swift`**

```swift
//
//  SidebarSectionStack.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. A VS Code-style vertical stack of
//  collapsible, resizable sections. Generic: it knows section ids, headers
//  and heights, never what a section shows. All height maths is in
//  `SidebarSectionLayout`.
//

import SwiftUI

struct SidebarSectionDescriptor: Identifiable {
    let id: SidebarSectionID
    /// Shown right after the title (e.g. the explorer's root folder name).
    let accessory: AnyView
    /// Trailing header controls, revealed on hover.
    let actions: AnyView
    /// Built only while the section is expanded, so a collapsed or hidden
    /// section's content is unmounted.
    let content: () -> AnyView
}

struct SidebarSectionStack: View {
    @ObservedObject var layoutStore: SidebarSectionLayoutStore
    let sections: [SidebarSectionDescriptor]

    /// The committed layout when the current divider drag began.
    @State private var dragBase: SidebarSectionLayout?
    /// The live layout while a divider is being dragged (never persisted
    /// until the drag ends).
    @State private var liveLayout: SidebarSectionLayout?

    private var layout: SidebarSectionLayout { liveLayout ?? layoutStore.layout }
    private let minimums = SidebarSectionID.minimumContentHeights

    var body: some View {
        GeometryReader { geometry in
            let layout = self.layout
            let space = layout.contentSpace(
                available: geometry.size.height,
                headerHeight: SidebarSectionMetrics.headerHeight,
                separatorHeight: SidebarSectionMetrics.separatorHeight
            )
            let heights = layout.contentHeights(space: space, minimums: minimums)
            let shown = layout.visible.compactMap { id in sections.first { $0.id == id } }

            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        let upper = shown[index - 1].id
                        SidebarSectionDivider(
                            isDraggable: layout.isExpanded(upper) && layout.isExpanded(section.id),
                            onDrag: { dy in
                                resize(upper: upper, lower: section.id, by: dy, space: space)
                            },
                            onDragEnd: commitDrag
                        )
                        .zIndex(1)
                    }
                    SidebarSectionHeader(
                        title: section.id.title,
                        isExpanded: layout.isExpanded(section.id),
                        accessory: section.accessory,
                        actions: section.actions,
                        visibilityItems: visibilityItems(in: layout),
                        onToggleCollapse: {
                            layoutStore.update { $0.togglingCollapse(section.id) }
                        },
                        onSetVisible: { id, visible in
                            layoutStore.update { $0.settingHidden(id, !visible) }
                        }
                    )
                    if layout.isExpanded(section.id) {
                        section.content()
                            .frame(height: heights[section.id] ?? 0)
                            .clipped()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        // Implicit, keyed on collapse/hide only: header clicks and menu
        // toggles animate; divider drags (weights) track the pointer
        // directly. Scoped to this subtree — never a window transaction.
        .animation(SidebarSectionMetrics.collapseAnimation, value: layoutStore.layout.collapsed)
        .animation(SidebarSectionMetrics.collapseAnimation, value: layoutStore.layout.hidden)
    }

    private func visibilityItems(in layout: SidebarSectionLayout) -> [SidebarSectionHeader.VisibilityItem] {
        layout.order.map { id in
            let isVisible = layout.isVisible(id)
            return SidebarSectionHeader.VisibilityItem(
                id: id,
                isVisible: isVisible,
                isEnabled: !(isVisible && layout.visible.count == 1)
            )
        }
    }

    private func resize(upper: SidebarSectionID, lower: SidebarSectionID, by delta: CGFloat, space: CGFloat) {
        let base = dragBase ?? layoutStore.layout
        dragBase = base
        liveLayout = base.resizing(upper: upper, lower: lower, by: delta, space: space, minimums: minimums)
    }

    private func commitDrag() {
        if let final = liveLayout {
            layoutStore.update { _ in final }
        }
        dragBase = nil
        liveLayout = nil
    }
}
```

- [ ] **Step 7: Run the smoke test and the build**

Run: `cd clients/native/UnpeelNative && swift build 2>&1 | grep -E "error|Build complete" | tail -3 && swift test --filter SidebarSectionStackTests 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Build complete!`, then `Executed 1 test, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add clients/native/UnpeelNative/Sources/UnpeelNative/Views/SidebarSections clients/native/UnpeelNative/Tests/UnpeelNativeTests/SidebarSectionStackTests.swift
git commit -m "feat(sidebar): generic collapsible, resizable section stack

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Explorer as a section (host refactor, header pieces, focus helper)

**Files:**
- Modify: `Sources/UnpeelNative/Views/ExplorerPanelHost.swift` (the `ExplorerPanelHost` struct, lines 150-218 at plan time)
- Create: `Sources/UnpeelNative/Views/SidebarSections/SidebarSectionContents.swift`
- Create: `Sources/UnpeelNative/Views/SidebarSections/ExplorerFocus.swift`
- Test: `Tests/UnpeelNativeTests/ExplorerFocusTests.swift`

**Interfaces:**
- Consumes: `ExplorerPanelView(… showsHeader:)`, `ExplorerPanelView.rootName(for:)`, `ExplorerPanelMenu` (Task 3); `ExplorerHostActions` (unchanged class in `ExplorerPanelHost.swift`); `ExplorerContextResolver.resolve(...)`; `ExplorerNSOutlineView` (public, `UnpeelExplorer`).
- Produces:
  - `@MainActor final class ExplorerSectionModel: ObservableObject` — `init(defaults: UserDefaults = AppDefaults.shared)`, `let viewModel: ExplorerViewModel`, `let actions: ExplorerHostActions`. Publishes nothing.
  - `ExplorerPanelHost.init(store: UnpeelStore, cache: SurfaceCache, section: ExplorerSectionModel)`; `static func context(store: UnpeelStore, sessionID: String?) -> ExplorerContext`; `static var palette: ExplorerPalette`.
  - `struct ProjectsSectionActions: View` — `init(store: UnpeelStore)`.
  - `struct ExplorerSectionTitleAccessory: View` — `init(store: UnpeelStore)`.
  - `@MainActor enum ExplorerFocus` — `static func outline(in view: NSView?) -> ExplorerNSOutlineView?`, `static func isTreeFocused(in window: NSWindow?) -> Bool`, `static func focusTree(in window: NSWindow?, attemptsLeft: Int = 20)`.

- [ ] **Step 1: Write the failing focus tests** `Tests/UnpeelNativeTests/ExplorerFocusTests.swift`:

```swift
import AppKit
import UnpeelExplorer
import XCTest
@testable import UnpeelNative

@MainActor
final class ExplorerFocusTests: XCTestCase {
    func testFindsANestedOutline() {
        let root = NSView()
        let middle = NSView()
        let outline = ExplorerNSOutlineView()
        root.addSubview(NSView())
        root.addSubview(middle)
        middle.addSubview(outline)
        XCTAssertTrue(ExplorerFocus.outline(in: root) === outline)
    }

    func testNoOutlineGivesNil() {
        let root = NSView()
        root.addSubview(NSView())
        XCTAssertNil(ExplorerFocus.outline(in: root))
        XCTAssertNil(ExplorerFocus.outline(in: nil))
    }

    func testTreeFocusFollowsTheFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let outline = ExplorerNSOutlineView()
        let other = NSTextView()
        window.contentView?.addSubview(outline)
        window.contentView?.addSubview(other)

        XCTAssertTrue(window.makeFirstResponder(outline))
        XCTAssertTrue(ExplorerFocus.isTreeFocused(in: window))
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertFalse(ExplorerFocus.isTreeFocused(in: window))
        XCTAssertFalse(ExplorerFocus.isTreeFocused(in: nil))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd clients/native/UnpeelNative && swift test --filter ExplorerFocusTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'ExplorerFocus' in scope`.

- [ ] **Step 3: Write `ExplorerFocus.swift`**

```swift
//
//  ExplorerFocus.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. Finds the explorer's outline view in a
//  window, reports whether it holds keyboard focus, and focuses it — for
//  ⇧⌘E. The outline mounts a runloop turn or more after its section
//  expands, so `focusTree` retries briefly instead of assuming it exists.
//

import AppKit
import UnpeelExplorer

@MainActor
enum ExplorerFocus {
    private static let retryNanoseconds: UInt64 = 50_000_000

    static func outline(in view: NSView?) -> ExplorerNSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? ExplorerNSOutlineView { return outline }
        for subview in view.subviews {
            if let outline = outline(in: subview) { return outline }
        }
        return nil
    }

    static func isTreeFocused(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder is ExplorerNSOutlineView { return true }
        guard let outline = outline(in: window?.contentView) else { return false }
        return responder.isDescendant(of: outline)
    }

    /// Makes the outline first responder, retrying every 50 ms (about one
    /// second in total) while the section mounts. Gives up silently: the
    /// section is still revealed, only focus is missing.
    static func focusTree(in window: NSWindow?, attemptsLeft: Int = 20) {
        guard let window else { return }
        if let outline = outline(in: window.contentView) {
            window.makeFirstResponder(outline)
            return
        }
        guard attemptsLeft > 1 else { return }
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: retryNanoseconds)
            focusTree(in: window, attemptsLeft: attemptsLeft - 1)
        }
    }
}
```

- [ ] **Step 4: Refactor `ExplorerPanelHost`** — replace the whole `struct ExplorerPanelHost: View { … }` (from `struct ExplorerPanelHost: View {` to the end of the file) with:

```swift
/// Fork-only: sidebar sections. The explorer's view model and host actions
/// outlive the EXPLORER section's content, so the section header can show
/// the panel menu while the tree itself is unmounted (collapsed or hidden).
/// Publishes nothing: owning it never re-renders the sidebar.
@MainActor
final class ExplorerSectionModel: ObservableObject {
    let viewModel: ExplorerViewModel
    let actions = ExplorerHostActions()

    init(defaults: UserDefaults = AppDefaults.shared) {
        viewModel = ExplorerViewModel(stateStore: ExplorerStateStore(defaults: defaults))
    }
}

struct ExplorerPanelHost: View {
    @ObservedObject var store: UnpeelStore
    /// Selection has its own publication boundary (`SessionSelectionState`):
    /// `UnpeelStore.objectWillChange` deliberately does not fire on a plain
    /// session switch, so observing only `store` would leave the explorer
    /// showing the previous session's root (see `WorkspaceTitleStrip`, which
    /// observes selection for the same reason).
    @ObservedObject private var selection: SessionSelectionState
    @ObservedObject private var viewModel: ExplorerViewModel
    private let actions: ExplorerHostActions
    let cache: SurfaceCache

    init(store: UnpeelStore, cache: SurfaceCache, section: ExplorerSectionModel) {
        self.store = store
        self.selection = store.sessionSelection
        self.viewModel = section.viewModel
        self.actions = section.actions
        self.cache = cache
    }

    /// The tree root follows the SELECTED session, never the focused pane
    /// within a split (`ExplorerHostActions.targetSessionID` is for the
    /// paste action; opens use `rootSessionID`, the tree's own session):
    /// `setContext` on a changed root tears down the
    /// watcher, blanks the panel, and rescans, so keying the tree to pane
    /// focus would blank/rebuild it on every click between panes in
    /// different worktrees. `focusedSoloSessionID` also covers the
    /// right-hand project panel's panes (`UnpeelStore.focusedSoloSessionID`),
    /// which would yank the tree to a worktree the main area is not even
    /// showing. Static so the section header resolves the same root.
    static func context(store: UnpeelStore, sessionID: String?) -> ExplorerContext {
        let session = sessionID.flatMap { store.displaySessionsByID[$0] }
        return ExplorerContextResolver.resolve(
            isLocalScope: store.selectedHostScope == .local,
            hasSession: session != nil,
            worktreePath: session?.worktreePath,
            projectPath: session.flatMap { store.displayProjectsByID[$0.projectID]?.path },
            fallbackDirectory: session.flatMap { store.paneWorkingDirectory(for: $0) }
        )
    }

    private var resolvedContext: ExplorerContext {
        Self.context(store: store, sessionID: selection.sessionID)
    }

    static var palette: ExplorerPalette {
        ExplorerPalette(
            text: NSColor(Theme.foreground),
            secondaryText: NSColor(Theme.mutedForeground),
            rowFont: Theme.rowLabelNSFont
        )
    }

    var body: some View {
        ExplorerPanelView(viewModel: viewModel, palette: Self.palette, actionHandler: actions, showsHeader: false)
            .onAppear { sync(resolvedContext) }
            .onChange(of: resolvedContext) { sync($0) }
            // Two sessions in the same worktree resolve to an EQUAL context,
            // so the `onChange` above never fires when switching between
            // them; the open target must still follow the selection or a
            // plugin pane would attach to the previously selected session.
            .onChange(of: selection.sessionID) { actions.rootSessionID = $0 }
            // Collapsed or hidden: persist the tree's state and stop the
            // FSEvents watcher (`setContext` does both); re-expanding
            // re-opens the root and restores the saved expansions.
            .onDisappear { viewModel.setContext(.none) }
            // Quitting does not dismantle the view hierarchy, so
            // `onDisappear` never fires on termination: without this, the
            // selection and scroll offset since the last expand/collapse or
            // context switch (the only other things that persist) are lost.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                viewModel.persistState()
            }
    }

    private func sync(_ context: ExplorerContext) {
        actions.store = store
        actions.rootSessionID = selection.sessionID
        actions.cache = cache
        if case .local(let root, _) = context {
            actions.root = CanonicalPath.resolve(root) ?? root
        } else {
            actions.root = nil
        }
        viewModel.setContext(context)
    }
}
```

Note: `ExplorerPanelHost` is still used by `RootView.swift`'s explorer column until Task 6 deletes it. To keep this task building and running, give RootView a long-lived model (never construct one inline in `body` — that would rebuild the view model and rescan the tree on every render). In `Sources/UnpeelNative/Views/RootView.swift`, inside the existing fork-only explorer property block (next to `@ObservedObject private var explorerState = ExplorerPanelState.shared`), add:

```swift
    @StateObject private var explorerSection = ExplorerSectionModel()
```

and change `ExplorerPanelHost(store: store, cache: cache)` to:

```swift
                        ExplorerPanelHost(store: store, cache: cache, section: explorerSection)
```

(Task 6 deletes the column and this property.)

- [ ] **Step 5: Write `SidebarSectionContents.swift`**

```swift
//
//  SidebarSectionContents.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. The app-specific header pieces for the
//  PROJECTS and EXPLORER sections.
//

import SwiftUI
import UnpeelExplorer

/// PROJECTS header actions: Add Project (local scopes only, same rule as
/// the footer "+") and a `…` menu.
struct ProjectsSectionActions: View {
    @ObservedObject var store: UnpeelStore

    var body: some View {
        HStack(spacing: 8) {
            if store.canPickProjectFolder {
                Button {
                    store.addProjectFolder()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Add Project")
            }
            Menu {
                Button("Collapse All Folders") { store.collapseAllSidebarFolders() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(Theme.mutedForeground)
    }
}

/// The EXPLORER title's accessory: the tree root's folder name, dimmed.
/// Resolved from the store (not the view model) so it stays correct while
/// the tree is collapsed and unmounted.
struct ExplorerSectionTitleAccessory: View {
    @ObservedObject var store: UnpeelStore
    @ObservedObject private var selection: SessionSelectionState

    init(store: UnpeelStore) {
        self.store = store
        self.selection = store.sessionSelection
    }

    var body: some View {
        if let name = ExplorerPanelView.rootName(
            for: ExplorerPanelHost.context(store: store, sessionID: selection.sessionID)
        ) {
            Text(name)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.mutedForeground.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 4)
        }
    }
}
```

- [ ] **Step 6: Build and run the focused tests**

Run: `cd clients/native/UnpeelNative && swift build 2>&1 | grep -E "error|Build complete" | tail -3 && swift test --filter 'ExplorerFocusTests|ExplorerContextResolverTests|ExplorerPanelViewTests' 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Build complete!`; `Executed 26 tests, with 0 failures` (3 + 19 + 4).

- [ ] **Step 7: Commit**

```bash
git add clients/native/UnpeelNative/Sources/UnpeelNative/Views/ExplorerPanelHost.swift clients/native/UnpeelNative/Sources/UnpeelNative/Views/RootView.swift clients/native/UnpeelNative/Sources/UnpeelNative/Views/SidebarSections clients/native/UnpeelNative/Tests/UnpeelNativeTests/ExplorerFocusTests.swift
git commit -m "feat(sidebar): explorer section model, header pieces and focus helper

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Mount the stack in the sidebar; retire the explorer column; ⇧⌘E

**Files:**
- Modify: `Sources/UnpeelNative/Views/SidebarView.swift` (struct `SidebarView`, list-area `ZStack` ~lines 581-660, the swipe-monitor `.background` ~lines 698-729, `projectTreePanel` mask ~line 808, `SidebarSelectionScrollObserver` occlusion ~line 952)
- Modify: `Sources/UnpeelNative/Views/SidebarWorkspaceDots.swift` (`SidebarListPageMetrics` ~line 965, pooled page mask ~line 1827)
- Modify: `Sources/UnpeelNative/Views/SidebarView.swift` (`SidebarListFadeMask` ~line 978)
- Modify: `Sources/UnpeelNative/Views/RootView.swift` (explorer blocks at ~44-48, ~105-125, ~253-275, ~298-304, ~345-349, ~375-379, ~543-590)
- Modify: `Sources/UnpeelNative/AppDelegate.swift` (~553-562, ~694-697, ~750-754)
- Delete: `Sources/UnpeelNative/ExplorerPanelState.swift`, `Tests/UnpeelNativeTests/ExplorerPanelStateTests.swift`
- Modify: `docs/superpowers/specs/2026-09-21-native-file-explorer-design.md` §3.3

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: the shipped feature. `SidebarView` gains a stored property `let cache: SurfaceCache` (declared right after `sessionDragController`), so its call becomes `SidebarView(store:sessionDragController:cache:)`.

Line numbers are from plan time; locate each block by the quoted code, not the number.

- [ ] **Step 1: `SidebarListFadeMask` takes a ramp height.** In `Views/SidebarView.swift`, in `struct SidebarListFadeMask`, replace

```swift
    private static let topMinOpacity: CGFloat = 0
    private static let opaqueAt: CGFloat = 76
```

with

```swift
    private static let topMinOpacity: CGFloat = 0
    // Fork-only: sidebar sections. Was `private static let opaqueAt = 76`;
    // the PROJECTS section passes its short in-section ramp.
    var opaqueAt: CGFloat = 76
```

and in its `body`, replace `.frame(height: Self.opaqueAt)` with `.frame(height: opaqueAt)`. (`topStops` does not use `opaqueAt`; if it does in the current file, turn it into an instance computed property the same way.)

- [ ] **Step 2: Both carousel pages use the in-section geometry.** In `Views/SidebarWorkspaceDots.swift`:

Replace `static let topInset: CGFloat = 48` in `enum SidebarListPageMetrics` with

```swift
    // Fork-only: sidebar sections. Was 48 (rows scrolled up under the
    // traffic-light glass); the PROJECTS section header now sits above.
    static let topInset: CGFloat = SidebarSectionMetrics.projectsTopInset
```

In `SidebarPooledListBody`, replace `.mask(SidebarListFadeMask())` with

```swift
            // Fork-only: sidebar sections — same ramp as the live list.
            .mask(SidebarListFadeMask(opaqueAt: SidebarSectionMetrics.projectsFadeRamp))
```

In `Views/SidebarView.swift` `projectTreePanel`, replace `.mask(SidebarListFadeMask())` with the same two lines (comment + `.mask(SidebarListFadeMask(opaqueAt: SidebarSectionMetrics.projectsFadeRamp))`).

In `SidebarSelectionScrollObserver`, replace `topOcclusion: Theme.titlebarHeight,` with

```swift
                              // Fork-only: sidebar sections — rows are only
                              // occluded by the in-section fade now.
                              topOcclusion: SidebarSectionMetrics.projectsFadeRamp,
```

Leave `SettingsView.swift`'s `SidebarListFadeMask()` untouched (default 76).

- [ ] **Step 3: `SidebarView` owns the explorer section model and takes the cache.** In `struct SidebarView`, directly after `let sessionDragController: SidebarSessionDragController`, add:

```swift
    // Fork-only: sidebar sections. The explorer needs the surface cache for
    // "send path to agent"; the section model keeps the explorer's view
    // model alive while its section is collapsed (it publishes nothing, so
    // owning it never re-renders this body); the layout store is the
    // persisted section layout.
    let cache: SurfaceCache
    @StateObject private var explorerSection = ExplorerSectionModel()
    private let sectionLayout = SidebarSectionLayoutStore.shared
```

`sectionLayout` is deliberately a plain constant, not `@ObservedObject`: observing it here would re-render this heavy tree body on every layout change. `SidebarSectionStack` observes it itself.

- [ ] **Step 4: Replace the list area's `else` branch and move PROJECTS-only modifiers.** In `SidebarView.body`, replace

```swift
                    SidebarListPage(source: .live, store: store) {
                        projectTreePanel
                    }
                    .modifier(SidebarWorkspaceCarousel(
                        pager: workspacePager,
                        store: store
                    ))
                    .transition(.sidebarPanel(fromTrailing: false))
```

with

```swift
                    // Fork-only: sidebar sections. The list area is a stack
                    // of sections — PROJECTS (the upstream carousel list
                    // above, see `projectsSectionContent`) and EXPLORER —
                    // starting under the traffic-light strip.
                    SidebarSectionStack(layoutStore: sectionLayout, sections: sidebarSections)
                        .padding(.top, SidebarSectionMetrics.stackTopInset)
                        .transition(.sidebarPanel(fromTrailing: false))
```

Then delete these three modifiers from the same `ZStack` (they move into `projectsSectionContent`, Step 5): the `.onDrop(of: [.fileURL], isTargeted: $folderDropTargeted) { … }` block, the `.onDrop(of: [.plainText], delegate: SidebarContainerDropDelegate(…))` block, and the `.overlay { SidebarFolderDropHighlight(…) }` block, including their comments. Keep `.animation`, `.frame(maxHeight:)`, `.clipped()`, `.onGeometryChange`, `.onAppear` as they are.

Delete the `.background { if WorkspaceFeature.pickerEnabled, !store.settingsVisible { SidebarWorkspaceSwipeMonitor(…) } }` block on the outer `VStack` (with its comment), and leave in its place:

```swift
        // Fork-only: sidebar sections. The trackpad workspace swipe monitor
        // moved onto the PROJECTS section (`projectsSectionContent`), so a
        // swipe over EXPLORER never switches workspace.
```

- [ ] **Step 5: Add the fork-only section members.** Directly after the end of `body` (before `private var projectTreePanel: some View {`), add:

```swift
    // MARK: - Fork-only: sidebar sections

    /// PROJECTS: the upstream list area unchanged — carousel, Finder-folder
    /// drop, the session-drop catch-all, and the workspace swipe monitor,
    /// now scoped to this section instead of the whole sidebar.
    private var projectsSectionContent: some View {
        SidebarListPage(source: .live, store: store) {
            projectTreePanel
        }
        .modifier(SidebarWorkspaceCarousel(
            pager: workspacePager,
            store: store
        ))
        .onDrop(of: [.fileURL], isTargeted: $folderDropTargeted) { providers in
            guard store.selectedHostScope.isLocalMachine else { return false }
            dragState.folderHoverReset()
            return store.addProjectFolders(from: providers)
        }
        .onDrop(of: [.plainText], delegate: SidebarContainerDropDelegate(
            isDragActive: { [weak dragState] in dragState?.isActive ?? false },
            finish: { [weak dragState] in dragState?.finish() }
        ))
        .overlay {
            SidebarFolderDropHighlight(
                dragState: dragState,
                externallyTargeted: folderDropTargeted
            )
        }
        .background {
            if WorkspaceFeature.pickerEnabled {
                SidebarWorkspaceSwipeMonitor(
                    state: workspacePager,
                    rows: {
                        store.workspacePool.requestImmediateRefresh()
                        return WorkspaceSwitching.orderedRows(store: store)
                    },
                    isScoped: { WorkspaceSwitching.isScoped($0, store: store) },
                    select: { WorkspaceSwitching.select($0, store: store) },
                    cycle: { WorkspaceSwitching.cycle(by: $0, store: store) }
                )
            }
        }
    }

    private var sidebarSections: [SidebarSectionDescriptor] {
        [
            SidebarSectionDescriptor(
                id: .projects,
                accessory: AnyView(EmptyView()),
                actions: AnyView(ProjectsSectionActions(store: store)),
                content: { AnyView(projectsSectionContent) }
            ),
            SidebarSectionDescriptor(
                id: .explorer,
                accessory: AnyView(ExplorerSectionTitleAccessory(store: store)),
                actions: AnyView(ExplorerPanelMenu(
                    viewModel: explorerSection.viewModel,
                    tint: NSColor(Theme.mutedForeground)
                )),
                content: { AnyView(ExplorerPanelHost(store: store, cache: cache, section: explorerSection)) }
            ),
        ]
    }
```

Copy the drop and swipe-monitor code from the blocks you deleted in Step 4 rather than from this plan if they differ in any detail — the move must be byte-for-byte apart from indentation. Add `import UnpeelExplorer` at the top of `SidebarView.swift` if the build reports `cannot find 'ExplorerPanelMenu'`.

- [ ] **Step 6: Retire the explorer column in `RootView.swift`.**

1. Delete the fork-only property block (`@ObservedObject private var explorerState = ExplorerPanelState.shared`, the `@StateObject private var explorerSection` added in Task 5, and the three `@State` explorer properties) with its comment.
2. Delete the fork-only computed properties `explorerWidth`, `explorerShown`, `explorerLeadingInset`, `shownExplorerWidth` with their comments.
3. Replace the `SidebarView(` call's arguments with `store: store, sessionDragController: sessionDragController, cache: cache` and put above the call: `// Fork-only: sidebar sections — the explorer lives in the sidebar and needs the cache.`
4. Delete the whole fork-only explorer column (`ZStack(alignment: .trailing) { if explorerShown { ExplorerPanelHost(…) … } } .frame(width: shownExplorerWidth …) .clipped()`) with its comment.
5. Replace the fork-only content padding block (the comment starting `// Fork-only: file explorer column. Upstream reads` and `.padding(.leading, store.sidebarCollapsed && !explorerShown ? surfaceInset : 0)`) with upstream's line:
   ```swift
                    .padding(.leading, store.sidebarCollapsed ? surfaceInset : 0)
   ```
6. Delete the fork-only `.animation(…, value: explorerShown)` block and the fork-only `.overlay(alignment: .topLeading) { if explorerShown { explorerResizer } }` block.
7. Delete the fork-only `explorerResizer` property.

Afterwards `grep -n "explorer" Sources/UnpeelNative/Views/RootView.swift` must print only the `SidebarView` call's comment. Check that `git diff upstream/main -- clients/native/UnpeelNative/Sources/UnpeelNative/Views/RootView.swift` now shows only that SidebarView call change (plus any other pre-existing fork-only blocks that are not about the explorer — there should be none).

- [ ] **Step 7: ⇧⌘E in `AppDelegate.swift`.**

Replace the body of `toggleExplorerFromMenu()` and its comment with:

```swift
    // Fork-only: sidebar sections. ⇧⌘E reveals and focuses the EXPLORER
    // section, or collapses it when the tree already has focus
    // (`ExplorerFocusCommand` is the decision).
    @objc private func toggleExplorerFromMenu() {
        guard let store else { return }
        let sections = SidebarSectionLayoutStore.shared
        switch currentExplorerCommand() {
        case .collapseExplorer:
            sections.update { $0.settingCollapsed(.explorer, true) }
            let target = ExplorerContextResolver.targetSessionID(
                activePane: store.activeTerminalPane?.sessionID,
                focusedSolo: store.focusedSoloSessionID,
                selected: store.selectedSessionID
            )
            if let target, let pane = surfaceCache.existingPane(for: target) {
                pane.focus()
            } else {
                window?.makeFirstResponder(nil)
            }
        case .revealAndFocus:
            store.sidebarCollapsed = false
            sections.update { $0.revealing(.explorer) }
            ExplorerFocus.focusTree(in: window)
        }
    }

    private func currentExplorerCommand() -> ExplorerCommandAction {
        let layout = SidebarSectionLayoutStore.shared.layout
        return ExplorerFocusCommand.action(
            treeFocused: ExplorerFocus.isTreeFocused(in: window),
            explorerExpanded: layout.isExpanded(.explorer),
            explorerHidden: !layout.isVisible(.explorer),
            sidebarCollapsed: store?.sidebarCollapsed ?? false
        )
    }
```

In `validateMenuItem`, replace the fork-only explorer branch with:

```swift
        // Fork-only: sidebar sections.
        if menuItem.action == #selector(toggleExplorerFromMenu) {
            menuItem.title = ExplorerFocusCommand.menuTitle(for: currentExplorerCommand())
            return window != nil
        }
```

In the View menu construction, change the fork-only comment above `explorerItem` to `// Fork-only: sidebar sections (⇧⌘E).` and keep the item.

- [ ] **Step 8: Delete the old column state.**

```bash
git rm clients/native/UnpeelNative/Sources/UnpeelNative/ExplorerPanelState.swift clients/native/UnpeelNative/Tests/UnpeelNativeTests/ExplorerPanelStateTests.swift
```

Then `grep -rn "ExplorerPanelState" clients/native/UnpeelNative` must print nothing.

- [ ] **Step 9: Update the explorer spec's touchpoint list.** In `docs/superpowers/specs/2026-09-21-native-file-explorer-design.md` §3.3 ("Touchpoints in existing files (the complete list)"), add entries for `Views/SidebarView.swift` (section stack hook; drops and swipe monitor scoped to PROJECTS; fade-mask ramp; row-reveal occlusion) and `Views/SidebarWorkspaceDots.swift` (`SidebarListPageMetrics.topInset`, pooled-page fade ramp), each pointing at `2026-09-23-sidebar-sections-design.md`; change the `RootView.swift` entry to say it now only passes `cache` to `SidebarView` (the explorer column was removed by the sidebar-sections change).

- [ ] **Step 10: Build and run the full gate**

Run: `cd clients/native/UnpeelNative && swift build 2>&1 | grep -E "error|warning: .*(Sidebar|Explorer)|Build complete" | tail -5`
Expected: `Build complete!` with no new warnings in sidebar/explorer files.

Run (repo root): `clients/native/test-native.sh 2>&1 | grep -E "Executed [0-9]+ tests|error:" | tail -2`
Expected: `Executed N tests, with 1 test skipped and 0 failures` (N = 790 − 4 deleted ExplorerPanelState tests + 19 + 8 + 2 + 1 + 3 = 819).

- [ ] **Step 11: Commit**

```bash
git add -A clients/native/UnpeelNative docs/superpowers/specs/2026-09-21-native-file-explorer-design.md
git commit -m "feat(sidebar): projects and explorer as sections of the left sidebar

Replaces the separate explorer column with a PROJECTS / EXPLORER section
stack inside the sidebar. The workspace swipe and Finder-folder drop are
scoped to PROJECTS; the project list's top inset and fade ramp follow the
section header; ⇧⌘E reveals and focuses the explorer or collapses it.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Runtime verification and evidence

**Files:**
- Create: `docs/superpowers/verification/2026-09-23-sidebar-sections.md`
- Create: `docs/superpowers/verification/sidebar-sections/*.png`
- Modify: `docs/superpowers/specs/2026-09-23-sidebar-sections-design.md` (status line; amendments if behaviour differs)

**Interfaces:** none (verification only). This task is done by the controller, not a subagent: it needs synthetic input and screenshots of a real window.

- [ ] **Step 1: Build and launch the dev app** (quit any running "Unpeel Dev" first):

```bash
osascript -e 'quit app "Unpeel Dev"'
UNPEEL_HOME=~/unpeel-dev-explorer-home clients/native/dev-blank.sh
```

Use workspace page 2 of that home (page 1 is the machine Host). Activate the app before any synthetic click. Tools: the scratchpad `ui` / `edgedrag` helpers and `screencapture -x -D <display>`.

- [ ] **Step 2: Run and record every check** from the spec's §6 runtime list (13 items). For each: action, expected, result, screenshot name. Crop screenshots to the window, max 1200 px wide.

- [ ] **Step 3: Write the evidence doc** with the environment, the gate result, the review outcome, the 13-row checklist, and anything not exercised. Set the spec's status to `implemented` and record any behaviour that changed during implementation as an amendment.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/verification/2026-09-23-sidebar-sections.md docs/superpowers/verification/sidebar-sections docs/superpowers/specs/2026-09-23-sidebar-sections-design.md
git commit -m "docs: sidebar sections verification evidence

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
