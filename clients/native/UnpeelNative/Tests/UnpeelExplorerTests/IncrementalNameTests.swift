import XCTest
@testable import UnpeelExplorer

/// VS Code's "simple" `incrementFileName`, the naming behind Duplicate and
/// Keep Both.
final class IncrementalNameTests: XCTestCase {
    func testAFileGainsCopyBeforeItsExtension() {
        XCTAssertEqual(IncrementalName.next("test.js", isFolder: false), "test copy.js")
        XCTAssertEqual(IncrementalName.next("Makefile", isFolder: false), "Makefile copy")
    }

    func testACopyIsNumbered() {
        XCTAssertEqual(IncrementalName.next("test copy.js", isFolder: false), "test copy 2.js")
        XCTAssertEqual(IncrementalName.next("test copy 2.js", isFolder: false), "test copy 3.js")
        XCTAssertEqual(IncrementalName.next("test copy 9.js", isFolder: false), "test copy 10.js")
    }

    func testCopyZeroDropsTheNumber() {
        XCTAssertEqual(IncrementalName.next("test copy 0.js", isFolder: false), "test copy.js")
    }

    func testOnlyTheLastExtensionMoves() {
        XCTAssertEqual(IncrementalName.next("archive.tar.gz", isFolder: false), "archive.tar copy.gz")
    }

    func testADotfileHasNoExtension() {
        XCTAssertEqual(IncrementalName.next(".env", isFolder: false), ".env copy")
        XCTAssertEqual(IncrementalName.next(".eslintrc.json", isFolder: false), ".eslintrc copy.json")
    }

    func testAFolderKeepsItsDots() {
        XCTAssertEqual(IncrementalName.next("v1.2", isFolder: true), "v1.2 copy")
        XCTAssertEqual(IncrementalName.next("v1.2 copy", isFolder: true), "v1.2 copy 2")
    }

    func testAvailableSkipsTakenNames() {
        let taken: Set = ["a.txt", "a copy.txt", "a copy 2.txt"]
        XCTAssertEqual(
            IncrementalName.available(for: "a.txt", isFolder: false, isTaken: taken.contains),
            "a copy 3.txt"
        )
    }
}
