import AppKit
import XCTest
@testable import UnpeelExplorer

@MainActor
final class FileIconProviderTests: XCTestCase {
    private func file(_ name: String) -> FileEntry {
        FileEntry(path: "/r/\(name)", name: name, kind: .file)
    }

    private func directory(_ name: String) -> FileEntry {
        FileEntry(path: "/r/\(name)", name: name, kind: .directory)
    }

    /// Extensionless files (`Makefile`) share one deliberate "no extension"
    /// bucket rather than an accidental empty-string key, and that bucket
    /// must not collide with a real extension's key.
    func testExtensionlessAndExtensionedFilesGetDifferentCacheKeys() {
        XCTAssertNotEqual(FileIconProvider.cacheKey(for: file("Makefile")), FileIconProvider.cacheKey(for: file("notes.txt")))
    }

    func testExtensionlessFilesShareOneKeyRegardlessOfName() {
        XCTAssertEqual(FileIconProvider.cacheKey(for: file("Makefile")), FileIconProvider.cacheKey(for: file("Dockerfile")))
    }

    func testExtensionKeysAreCaseInsensitiveAndDistinctFromDirectories() {
        XCTAssertEqual(FileIconProvider.cacheKey(for: file("A.TXT")), FileIconProvider.cacheKey(for: file("a.txt")))
        XCTAssertNotEqual(FileIconProvider.cacheKey(for: directory("txt")), FileIconProvider.cacheKey(for: file("a.txt")))
    }

    func testIconIsCachedByExtension() {
        let provider = FileIconProvider()
        let first = provider.icon(for: file("a.txt"))
        let second = provider.icon(for: file("b.txt"))
        XCTAssertTrue(first === second)
    }
}
