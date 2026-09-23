import AppKit
import SwiftUI
import XCTest
@testable import UnpeelNative

/// The maths is in `SidebarSectionLayoutTests`; this covers the one stack
/// behaviour testable without a window: a collapsed or hidden section's
/// content is never built. The visuals are verified at runtime.
@MainActor
final class SidebarSectionStackTests: XCTestCase {
    /// How many times each section's `content()` closure ran.
    @MainActor
    private final class BuildCounter {
        private(set) var counts: [SidebarSectionID: Int] = [:]

        func record(_ id: SidebarSectionID) {
            counts[id, default: 0] += 1
        }

        func reset() {
            counts = [:]
        }

        func builds(_ id: SidebarSectionID) -> Int {
            counts[id, default: 0]
        }
    }

    private func makeStore() -> (SidebarSectionLayoutStore, UserDefaults, String) {
        let suite = "unpeel.sidebarSections.stack.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SidebarSectionLayoutStore(defaults: defaults), defaults, suite)
    }

    private func sections(counting counter: BuildCounter) -> [SidebarSectionDescriptor] {
        SidebarSectionID.allCases.map { id in
            SidebarSectionDescriptor(
                id: id,
                accessory: AnyView(EmptyView()),
                actions: AnyView(EmptyView()),
                content: {
                    counter.record(id)
                    return AnyView(Color.red)
                }
            )
        }
    }

    /// Lays out and renders a stack; `content()` is only called while
    /// SwiftUI evaluates the body, so the render pass is what counts.
    @discardableResult
    private func render(
        _ store: SidebarSectionLayoutStore,
        counter: BuildCounter,
        height: CGFloat
    ) -> NSHostingView<SidebarSectionStack> {
        let host = NSHostingView(rootView: SidebarSectionStack(layoutStore: store, sections: sections(counting: counter)))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        flush(host)
        return host
    }

    /// Lets a store change reach the hosted view, then renders it.
    private func flush(_ host: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        host.display()
    }

    func testDefaultLayoutBuildsEveryExpandedSection() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = BuildCounter()
        render(store, counter: counter, height: 700)
        XCTAssertGreaterThanOrEqual(counter.builds(.projects), 1)
        XCTAssertGreaterThanOrEqual(counter.builds(.explorer), 1)
    }

    func testCollapsedSectionContentIsNeverBuilt() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = BuildCounter()
        let host = render(store, counter: counter, height: 700)
        store.update { $0.settingCollapsed(.explorer, true) }
        counter.reset()
        flush(host)
        XCTAssertEqual(counter.builds(.explorer), 0)
        XCTAssertGreaterThanOrEqual(counter.builds(.projects), 1)
    }

    func testHiddenSectionContentIsNeverBuilt() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = BuildCounter()
        let host = render(store, counter: counter, height: 700)
        store.update { $0.settingHidden(.projects, true) }
        counter.reset()
        flush(host)
        XCTAssertEqual(counter.builds(.projects), 0)
        XCTAssertGreaterThanOrEqual(counter.builds(.explorer), 1)
    }

    /// No trap (e.g. a negative frame) when the headers alone overflow.
    func testTinyHeightLaysOutWithoutTrapping() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        render(store, counter: BuildCounter(), height: 40)
    }
}
