import AppKit
import XCTest
@testable import UnpeelExplorer

final class ExplorerKeyCommandTests: XCTestCase {
    func testPlainKeys() {
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 49, modifiers: []), .quickLook)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 124, modifiers: []), .expandOrDescend)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 123, modifiers: []), .collapseOrAscend)
    }

    func testArrowKeysCarryNumericPadAndFunctionFlags() {
        XCTAssertEqual(
            ExplorerKeyCommand.from(keyCode: 124, modifiers: [.numericPad, .function]),
            .expandOrDescend
        )
    }

    func testCommandCombinations() {
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 125, modifiers: [.command]), .open)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 8, modifiers: [.command, .option]), .copyPath)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 8, modifiers: [.command, .option, .shift]), .copyRelativePath)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 15, modifiers: [.command, .option]), .revealInFinder)
    }

    func testUnmappedKeysFallThrough() {
        XCTAssertNil(ExplorerKeyCommand.from(keyCode: 125, modifiers: []))
        XCTAssertNil(ExplorerKeyCommand.from(keyCode: 49, modifiers: [.shift]))
        XCTAssertNil(ExplorerKeyCommand.from(keyCode: 8, modifiers: [.command]))
    }
}
