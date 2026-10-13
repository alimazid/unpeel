import XCTest
@testable import UnpeelExplorer

/// Mirrors VS Code's `validateFileName` / `isValidBasename` on macOS, plus
/// the fork's one addition: a rename never contains a slash.
final class FileNameValidationTests: XCTestCase {
    private let nothingTaken: (String) -> Bool = { _ in false }

    private func error(_ name: String, _ purpose: FileNameValidation.Purpose = .create) -> String? {
        let issue = FileNameValidation.validate(name, purpose: purpose, isTaken: nothingTaken)
        return issue?.severity == .error ? issue?.message : nil
    }

    func testEmptyOrBlankNamesAreErrors() {
        for name in ["", "   ", "\t", "\t\t"] {
            XCTAssertEqual(error(name), "A file or folder name must be provided.", "for \(name.debugDescription)")
        }
    }

    func testALeadingSlashIsAnError() {
        XCTAssertEqual(error("/etc/hosts"), "A file or folder name cannot start with a slash.")
    }

    func testTrailingSlashesAndTabsAreTrimmedBeforeChecking() {
        XCTAssertEqual(FileNameValidation.wellFormed("\tnotes/\t"), "notes")
        XCTAssertEqual(FileNameValidation.wellFormed("notes///"), "notes")
        XCTAssertNil(FileNameValidation.validate("notes/", purpose: .create, isTaken: nothingTaken))
    }

    func testDotSegmentsAreInvalid() {
        for name in [".", "..", "a/../b", "a/./b"] {
            XCTAssertEqual(
                error(name),
                "The name “\(name)” is not valid as a file or folder name. Please choose a different name.",
                "for \(name)"
            )
        }
    }

    func testASegmentOver255BytesIsInvalid() {
        XCTAssertNil(error(String(repeating: "a", count: 255)))
        XCTAssertNotNil(error(String(repeating: "a", count: 256)))
        // 128 two-byte characters: 128 UTF-16 units but 256 UTF-8 bytes,
        // over APFS's limit.
        XCTAssertNotNil(error(String(repeating: "é", count: 128)))
        XCTAssertNotNil(error("ok/" + String(repeating: "b", count: 256)))
    }

    func testANulCharacterIsInvalid() {
        XCTAssertNotNil(error("a\u{0}b"))
    }

    func testATakenNameIsAnError() {
        let issue = FileNameValidation.validate("README.md", purpose: .create, isTaken: { $0 == "README.md" })
        XCTAssertEqual(issue, FileNameIssue(
            severity: .error,
            message: "A file or folder “README.md” already exists at this location. Please choose a different name."
        ))
    }

    func testRenamingToTheCurrentNameIsNotACollision() {
        let issue = FileNameValidation.validate(
            "a.txt", purpose: .rename(currentName: "a.txt"), isTaken: { _ in true }
        )
        XCTAssertNil(issue)
    }

    func testRenameRefusesASlash() {
        XCTAssertEqual(error("a/b.txt", .rename(currentName: "x.txt")), "A file or folder name cannot contain a slash.")
    }

    func testCreateAcceptsANestedPath() {
        XCTAssertNil(FileNameValidation.validate("src/utils/x.ts", purpose: .create, isTaken: nothingTaken))
    }

    func testLeadingOrTrailingWhitespaceIsOnlyAWarning() {
        for name in [" a", "a ", "dir/ b"] {
            let issue = FileNameValidation.validate(name, purpose: .create, isTaken: nothingTaken)
            XCTAssertEqual(issue, FileNameIssue(
                severity: .warning, message: "Leading or trailing whitespace detected in file or folder name."
            ), "for \(name.debugDescription)")
        }
    }

    func testErrorsOutrankTheWhitespaceWarning() {
        let issue = FileNameValidation.validate(" a", purpose: .create, isTaken: { _ in true })
        XCTAssertEqual(issue?.severity, .error)
    }

    func testAColonIsAllowed() {
        // Legal in a POSIX name on macOS (Finder shows it as a slash);
        // VS Code allows it too.
        XCTAssertNil(error("12:30 notes.txt"))
    }
}
