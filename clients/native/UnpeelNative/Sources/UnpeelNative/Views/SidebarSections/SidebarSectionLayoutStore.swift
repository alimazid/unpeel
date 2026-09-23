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
