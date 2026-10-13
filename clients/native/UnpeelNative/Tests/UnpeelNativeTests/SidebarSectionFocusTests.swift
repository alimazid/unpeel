import AppKit
import UnpeelExplorer
import XCTest
@testable import UnpeelNative

@MainActor
final class SidebarSectionFocusTests: XCTestCase {
    func testFindsANestedOutline() {
        let root = NSView()
        let middle = NSView()
        let outline = ExplorerNSOutlineView()
        root.addSubview(NSView())
        root.addSubview(middle)
        middle.addSubview(outline)
        XCTAssertTrue(SidebarSectionFocus.list(of: .explorer, in: root) === outline)
    }

    func testNoOutlineGivesNil() {
        let root = NSView()
        root.addSubview(NSView())
        XCTAssertNil(SidebarSectionFocus.list(of: .explorer, in: root))
        XCTAssertNil(SidebarSectionFocus.list(of: .explorer, in: nil))
    }

    func testTreeFocusFollowsTheFirstResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let outline = ExplorerNSOutlineView()
        // NSTableView (and NSOutlineView) only accepts first responder once
        // it has at least one column — true of the real panel, which adds
        // its column before the tree is ever shown, but not of a bare
        // instance built directly in a test.
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col")))
        let other = NSTextView()
        window.contentView?.addSubview(outline)
        window.contentView?.addSubview(other)

        XCTAssertTrue(window.makeFirstResponder(outline))
        XCTAssertTrue(SidebarSectionFocus.isFocused(.explorer, in: window))
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertFalse(SidebarSectionFocus.isFocused(.explorer, in: window))
        XCTAssertFalse(SidebarSectionFocus.isFocused(.explorer, in: nil))
    }
}
