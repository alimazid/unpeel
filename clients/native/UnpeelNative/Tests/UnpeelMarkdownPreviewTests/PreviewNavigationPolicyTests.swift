import XCTest
@testable import UnpeelMarkdownPreview

final class PreviewNavigationPolicyTests: XCTestCase {
    private let currentPath = "/r/a.md"

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    func testAnchorOnCurrentDocumentIsAllowedInPlace() {
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(
                url: url("unpeel-preview://local/r/a.md#x"), isLinkActivated: true, currentPath: currentPath
            ),
            .allow
        )
    }

    func testLinkToAnotherMarkdownFileOpensAPreview() {
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(
                url: url("unpeel-preview://local/r/b.md"), isLinkActivated: true, currentPath: currentPath
            ),
            .openMarkdown("/r/b.md")
        )
    }

    func testLinkToANonMarkdownSameSchemeResourceIsCancelled() {
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(
                url: url("unpeel-preview://local/r/c.png"), isLinkActivated: true, currentPath: currentPath
            ),
            .cancel
        )
    }

    func testInitialLoadOfTheCurrentPathIsAllowed() {
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(
                url: url("unpeel-preview://local/r/a.md"), isLinkActivated: false, currentPath: currentPath
            ),
            .allow
        )
    }

    func testHTTPSLinkActivatedOpensExternally() {
        let target = url("https://example.com")
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(url: target, isLinkActivated: true, currentPath: currentPath),
            .openExternal(target)
        )
    }

    // Fork-only: markdown preview pane — pins the `mailto:` arm named in the
    // type's own doc comment.
    func testMailtoLinkActivatedOpensExternally() {
        let target = url("mailto:someone@example.com")
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(url: target, isLinkActivated: true, currentPath: currentPath),
            .openExternal(target)
        )
    }

    func testHTTPSNotLinkActivatedIsCancelled() {
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(url: url("https://example.com"), isLinkActivated: false, currentPath: currentPath),
            .cancel
        )
    }

    func testJavascriptSchemeIsCancelled() {
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(url: url("javascript:alert(1)"), isLinkActivated: true, currentPath: currentPath),
            .cancel
        )
    }

    func testFileSchemeIsCancelled() {
        XCTAssertEqual(
            PreviewNavigationPolicy.decide(url: url("file:///etc/hosts"), isLinkActivated: true, currentPath: currentPath),
            .cancel
        )
    }
}
