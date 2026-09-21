//
//  ExplorerPanelState.swift
//  UnpeelNative
//
//  Visibility and width of the file explorer column. Kept out of UnpeelStore
//  on purpose: the explorer is a fork-only feature and this keeps upstream
//  merges of the store conflict-free.
//

import Foundation

@MainActor
final class ExplorerPanelState: ObservableObject {
    static let shared = ExplorerPanelState(defaults: AppDefaults.shared)

    static let defaultWidth: Double = 260
    static let minWidth: Double = 180
    static let maxWidth: Double = 520

    private static let visibleKey = "unpeel.explorer.visible"
    private static let widthKey = "unpeel.explorer.width"

    private let defaults: UserDefaults

    @Published var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Self.visibleKey) }
    }

    @Published var width: Double {
        didSet { defaults.set(width, forKey: Self.widthKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Self.visibleKey)
        let stored = defaults.double(forKey: Self.widthKey)
        width = stored > 0 ? Self.clamp(stored) : Self.defaultWidth
    }

    func toggle() {
        isVisible.toggle()
    }

    static func clamp(_ width: Double) -> Double {
        min(maxWidth, max(minWidth, width))
    }
}
