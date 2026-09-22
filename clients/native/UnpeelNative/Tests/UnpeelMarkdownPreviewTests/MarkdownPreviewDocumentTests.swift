import XCTest
@testable import UnpeelMarkdownPreview

final class MarkdownPreviewDocumentTests: XCTestCase {
    func testPageWrapsBodyWithTitleAndSingleStylesheet() {
        let page = MarkdownPreviewDocument.page(bodyHTML: "<p>x</p>", title: "A <b> file")
        XCTAssertTrue(page.hasPrefix("<!doctype html>"))
        XCTAssertTrue(page.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(page.contains("<title>A &lt;b&gt; file</title>"))
        XCTAssertEqual(page.components(separatedBy: "<style>").count - 1, 1)
        XCTAssertTrue(page.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(page.contains("<article class=\"markdown-body\"><p>x</p></article>"))
        XCTAssertTrue(page.contains("webkit.messageHandlers.unpeelPreview.postMessage"))
    }

    func testURLForPathPercentEncodesAndRoundTrips() {
        let url = MarkdownPreviewDocument.url(forPath: "/Users/me/My Docs/a#b.md")
        XCTAssertEqual(url.scheme, "unpeel-preview")
        XCTAssertEqual(url.host, "local")
        XCTAssertEqual(url.path, "/Users/me/My Docs/a#b.md")
        XCTAssertEqual(MarkdownPreviewDocument.path(from: url), "/Users/me/My Docs/a#b.md")
    }
}
