import Foundation

public struct RootViewState: Codable, Sendable, Equatable {
    public let expanded: [String]
    public let selection: [String]
    public let scrollOffset: Double

    public init(expanded: [String], selection: [String], scrollOffset: Double) {
        self.expanded = expanded
        self.selection = selection
        self.scrollOffset = scrollOffset
    }
}

/// View state remembered per explorer root, bounded so a long-lived install
/// does not accumulate state for every folder ever browsed.
@MainActor
public final class ExplorerStateStore {
    public static let maxRoots = 50

    private static let rootsKey = "unpeel.explorer.roots"
    private static let showHiddenKey = "unpeel.explorer.showHidden"
    private static let showIgnoredKey = "unpeel.explorer.showIgnored"
    /// Fork-only: date modified column.
    private static let sortOrderKey = "unpeel.explorer.sortOrder"

    private struct StoredRoot: Codable {
        let state: RootViewState
        let lastUsed: Double
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var filter: VisibilityFilter {
        get {
            VisibilityFilter(
                showHidden: defaults.bool(forKey: Self.showHiddenKey),
                showIgnored: defaults.bool(forKey: Self.showIgnoredKey)
            )
        }
        set {
            defaults.set(newValue.showHidden, forKey: Self.showHiddenKey)
            defaults.set(newValue.showIgnored, forKey: Self.showIgnoredKey)
        }
    }

    /// Fork-only: date modified column. One order for every root, like the
    /// filter; an unknown stored value reads as `.name`.
    public var sortOrder: ExplorerSortOrder {
        get { defaults.string(forKey: Self.sortOrderKey).flatMap(ExplorerSortOrder.init(rawValue:)) ?? .name }
        set { defaults.set(newValue.rawValue, forKey: Self.sortOrderKey) }
    }

    public func state(forRoot root: String) -> RootViewState? {
        loadRoots()[root]?.state
    }

    public func save(_ state: RootViewState, forRoot root: String, now: Date = Date()) {
        let updated = loadRoots().merging(
            [root: StoredRoot(state: state, lastUsed: now.timeIntervalSince1970)]
        ) { _, new in new }
        let kept = updated
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
            .prefix(Self.maxRoots)
        let bounded = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: Self.rootsKey)
    }

    private func loadRoots() -> [String: StoredRoot] {
        guard let data = defaults.data(forKey: Self.rootsKey),
              let roots = try? JSONDecoder().decode([String: StoredRoot].self, from: data)
        else { return [:] }
        return roots
    }
}
