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
