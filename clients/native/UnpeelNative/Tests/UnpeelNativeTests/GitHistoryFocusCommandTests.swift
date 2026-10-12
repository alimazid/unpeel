import AppKit
import UnpeelGit
import XCTest
@testable import UnpeelNative

/// Fork-only: git support. ⌃⇧G is ⇧⌘E's decision applied to GIT HISTORY.
@MainActor
final class GitHistoryFocusCommandTests: XCTestCase {
    func testCollapsesOnlyWhenFocusedExpandedVisibleAndSidebarOpen() {
        XCTAssertEqual(
            SidebarSectionFocusCommand.action(focused: true, expanded: true, hidden: false, sidebarCollapsed: false),
            .collapse
        )
    }

    func testEveryOtherStateRevealsAndFocuses() {
        let states: [(focused: Bool, expanded: Bool, hidden: Bool, sidebarCollapsed: Bool, name: String)] = [
            (false, true, false, true, "sidebar collapsed"),
            (false, true, true, false, "section hidden"),
            (false, false, false, false, "section collapsed"),
            (false, true, false, false, "expanded, unfocused"),
            (true, false, false, false, "focus left behind in a collapsed section"),
            (true, true, true, false, "hidden while focused"),
            (true, true, false, true, "sidebar collapsed while focused"),
        ]
        for state in states {
            XCTAssertEqual(
                SidebarSectionFocusCommand.action(
                    focused: state.focused, expanded: state.expanded,
                    hidden: state.hidden, sidebarCollapsed: state.sidebarCollapsed
                ),
                .revealAndFocus,
                state.name
            )
        }
    }

    func testMenuTitlesNameTheSection() {
        XCTAssertEqual(SidebarSectionFocusCommand.menuTitle(for: .collapse, section: .gitHistory), "Hide Git History")
        XCTAssertEqual(SidebarSectionFocusCommand.menuTitle(for: .revealAndFocus, section: .gitHistory), "Show Git History")
        XCTAssertEqual(SidebarSectionFocusCommand.menuTitle(for: .collapse, section: .explorer), "Hide Explorer")
        XCTAssertEqual(SidebarSectionFocusCommand.menuTitle(for: .revealAndFocus, section: .explorer), "Show Explorer")
    }

    func testFindsTheHistoryList() {
        let root = NSView()
        let middle = NSView()
        let list = GitHistoryNSOutlineView()
        root.addSubview(NSView())
        root.addSubview(middle)
        middle.addSubview(list)

        XCTAssertTrue(GitHistoryFocus.list(in: root) === list)
        XCTAssertNil(GitHistoryFocus.list(in: NSView()))
    }

    func testHistoryFocusFollowsTheFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let list = GitHistoryNSOutlineView()
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col")))
        let other = NSTextView()
        window.contentView?.addSubview(list)
        window.contentView?.addSubview(other)

        XCTAssertTrue(window.makeFirstResponder(list))
        XCTAssertTrue(GitHistoryFocus.isListFocused(in: window))
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertFalse(GitHistoryFocus.isListFocused(in: window))
    }

    /// ⌃⇧G sits next to ⇧⌘E in the View menu, which keeps its own chord.
    /// No other menu item uses a control chord on G (Find Next / Previous
    /// are ⌘G / ⇧⌘G), and the terminal surface binds no control chords at
    /// all (`GhosttySurfaceKeybindTests`), so a focused terminal lets the
    /// chord through to the menu.
    func testViewMenuItemsCarryTheirChords() {
        let items = AppDelegate.sidebarSectionMenuItems(target: nil)

        XCTAssertEqual(items.map(\.title), ["Show Explorer", "Show Git History"])
        XCTAssertEqual(items[0].keyEquivalent, "e")
        XCTAssertEqual(items[0].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(items[1].keyEquivalent, "g")
        XCTAssertEqual(items[1].keyEquivalentModifierMask, [.control, .shift])
        XCTAssertFalse(GhosttyTerminalPane.surfaceKeybinds.contains { $0.contains("ctrl") })
    }
}
