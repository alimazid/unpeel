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
    static let defaultWeights: [SidebarSectionID: Double] = [.projects: 0.4, .explorer: 0.6, .gitHistory: 0.4]
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

    /// GIT HISTORY starts collapsed: until it is opened, the sidebar looks
    /// as it did before the section existed, and no git process runs.
    static let `default` = SidebarSectionLayout(
        order: SidebarSectionID.allCases,
        hidden: [],
        collapsed: [.gitHistory],
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
    /// appended visible, with their default weight and their fresh-install
    /// collapse state (so GIT HISTORY joins an existing sidebar collapsed);
    /// a record that hides every section shows them all again.
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
        let appended = SidebarSectionID.allCases.filter { !order.contains($0) }
        order += appended

        func ids(_ raws: [String]) -> Set<SidebarSectionID> {
            Set(raws.compactMap(SidebarSectionID.init(rawValue:)))
        }
        let collapsed = ids(stored.collapsed)
            .union(appended.filter { Self.default.collapsed.contains($0) })
        var hidden = ids(stored.hidden)
        if hidden.count >= order.count { hidden = [] }

        var weights: [SidebarSectionID: Double] = [:]
        for (raw, value) in stored.weights {
            if let id = SidebarSectionID(rawValue: raw), value.isFinite, value > 0 {
                weights[id] = value
            }
        }
        return SidebarSectionLayout(order: order, hidden: hidden, collapsed: collapsed, weights: weights)
    }
}
