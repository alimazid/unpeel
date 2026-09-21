import AppKit
import SwiftUI
import XCTest
@testable import UnpeelExplorer

/// Row-label legibility, measured under real appearances rather than
/// assumed: the palette the app injects is an appearance-dynamic `NSColor`
/// round-tripped through SwiftUI's `Color`.
@MainActor
final class ExplorerRowColorTests: XCTestCase {
    private static let lightText = NSColor(srgbRed: 0x11 / 255, green: 0x12 / 255, blue: 0x17 / 255, alpha: 1)
    private static let darkText = NSColor(srgbRed: 0xF3 / 255, green: 0xF5 / 255, blue: 0xFB / 255, alpha: 1)

    /// `Theme.foreground` is `Color(nsColor: tintedDynamicNSColor(...))` and
    /// the panel host converts it back with `NSColor(_:)`. That round trip
    /// must keep the colour dynamic — if it resolved eagerly in a light
    /// environment the dark panel would draw near-black text.
    func testSwiftUIRoundTripKeepsTheColorAppearanceDynamic() {
        let dynamic = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? Self.lightText : Self.darkText
        }
        let roundTripped = NSColor(Color(nsColor: dynamic))

        XCTAssertEqual(resolve(roundTripped, under: .aqua), resolve(Self.lightText, under: .aqua))
        XCTAssertEqual(resolve(roundTripped, under: .darkAqua), resolve(Self.darkText, under: .darkAqua))
    }

    /// Unselected, selected-unemphasized and selected-emphasized rows, in
    /// both appearances, must all clear the WCAG AA 4.5:1 body-text bar
    /// against the fill actually behind them.
    func testRowLabelsStayLegibleInEverySelectionState() {
        for (appearance, backdrop) in [
            (NSAppearance.Name.darkAqua, NSColor(srgbRed: 0x12 / 255, green: 0x13 / 255, blue: 0x14 / 255, alpha: 1)),
            (.aqua, NSColor.white),
        ] {
            let harness = ColorHarness(appearance: appearance)
            defer { harness.teardown() }
            harness.apply(selecting: "/r/a.txt")

            let selected = harness.cell(atRow: 0)
            let unselected = harness.cell(atRow: 1)
            XCTAssertEqual(selected?.backgroundStyle, .emphasized, "\(appearance.rawValue): row 0 not emphasized")

            assertContrast(
                of: unselected, on: backdrop, under: appearance, label: "\(appearance.rawValue) unselected"
            )
            assertContrast(
                of: selected, on: selectionFill(emphasized: true, under: appearance),
                under: appearance, label: "\(appearance.rawValue) selected-emphasized"
            )

            // The window losing key turns the same row unemphasized.
            harness.removeEmphasis(fromRow: 0)
            let unemphasized = harness.cell(atRow: 0)
            XCTAssertEqual(
                unemphasized?.backgroundStyle, .normal,
                "\(appearance.rawValue): row 0 still emphasized"
            )
            assertContrast(
                of: unemphasized, on: selectionFill(emphasized: false, under: appearance),
                under: appearance, label: "\(appearance.rawValue) selected-unemphasized"
            )
        }
    }

    // MARK: - Helpers

    private func assertContrast(
        of cell: ExplorerRowCellView?,
        on backdrop: NSColor,
        under appearance: NSAppearance.Name,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let color = cell?.textField?.textColor else {
            return XCTFail("\(label): no label colour", file: file, line: line)
        }
        let text = resolve(color, under: appearance)
        let ratio = contrastRatio(text, resolve(backdrop, under: appearance))
        XCTAssertGreaterThan(
            ratio, 4.5,
            "\(label): contrast \(String(format: "%.2f", ratio)):1 for \(hex(text)) on \(hex(resolve(backdrop, under: appearance)))",
            file: file, line: line
        )
    }

    private func selectionFill(emphasized: Bool, under appearance: NSAppearance.Name) -> NSColor {
        emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
    }

    private func resolve(_ color: NSColor, under name: NSAppearance.Name) -> NSColor {
        var resolved = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private func hex(_ color: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int(color.redComponent * 255),
               Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let first = relativeLuminance(a)
        let second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    @MainActor
    private final class ColorHarness {
        private let window: NSWindow
        private let outline: ExplorerNSOutlineView
        private let controller: ExplorerOutlineController
        private let suite: String

        init(appearance: NSAppearance.Name) {
            suite = "unpeel.explorer.colortests.\(UUID().uuidString)"
            let viewModel = ExplorerViewModel(
                services: ExplorerServices(scan: { _, _ in DirectoryListing(entries: []) }, makeWatcher: { _, _ in nil }),
                stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!)
            )
            // The palette the app injects: one dynamic colour per token.
            let dynamic = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? lightText : darkText
            }
            controller = ExplorerOutlineController(
                viewModel: viewModel,
                palette: ExplorerPalette(
                    text: NSColor(Color(nsColor: dynamic)),
                    secondaryText: .secondaryLabelColor,
                    rowFont: .systemFont(ofSize: 13)
                )
            )
            outline = ExplorerOutlineView.makeOutlineView()
            controller.attach(to: outline)
            let scroll = ExplorerOutlineView.makeScrollView(documentView: outline)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.appearance = NSAppearance(named: appearance)
            scroll.frame = window.contentView!.bounds
            window.contentView?.addSubview(scroll)
            window.makeKeyAndOrderFront(nil)
        }

        func apply(selecting path: String) {
            let model = FileTreeModel(root: "/r").settingContents(
                .loaded(DirectoryListing(entries: [
                    FileEntry(path: "/r/a.txt", name: "a.txt", kind: .file),
                    FileEntry(path: "/r/b.txt", name: "b.txt", kind: .file),
                ])),
                for: "/r"
            )
            controller.apply(model: model, filter: VisibilityFilter(), selection: [path])
            layout()
        }

        /// What AppKit itself does when the window stops being key.
        func removeEmphasis(fromRow row: Int) {
            outline.rowView(atRow: row, makeIfNecessary: true)?.isEmphasized = false
            layout()
        }

        func cell(atRow row: Int) -> ExplorerRowCellView? {
            outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ExplorerRowCellView
        }

        private func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }

        func teardown() {
            window.orderOut(nil)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }
}

private let lightText = NSColor(srgbRed: 0x11 / 255, green: 0x12 / 255, blue: 0x17 / 255, alpha: 1)
private let darkText = NSColor(srgbRed: 0xF3 / 255, green: 0xF5 / 255, blue: 0xFB / 255, alpha: 1)
