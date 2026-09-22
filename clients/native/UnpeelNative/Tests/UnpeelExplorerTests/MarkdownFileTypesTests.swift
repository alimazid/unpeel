import XCTest
@testable import UnpeelExplorer

final class MarkdownFileTypesTests: XCTestCase {
    func testRecognisesTheRegistryExtensionsCaseInsensitively() {
        for path in ["/r/a.md", "/r/b.MD", "/r/c.markdown", "/r/d.mdown", "/r/e.mkd"] {
            XCTAssertTrue(MarkdownFileTypes.isMarkdown(path), path)
        }
        for path in ["/r/a.txt", "/r/md", "/r/a.md.bak", "/r/.md"] {
            XCTAssertFalse(MarkdownFileTypes.isMarkdown(path), path)
        }
    }
}
