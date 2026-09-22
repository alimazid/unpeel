import XCTest
@testable import UnpeelMarkdownPreview

final class MarkdownHTMLRendererTests: XCTestCase {
    private func render(_ md: String) -> String {
        MarkdownHTMLRenderer.html(from: md)
    }

    func testHeadingsGetLevelsAndSlugIDs() {
        XCTAssertEqual(render("# Hello World"), "<h1 id=\"hello-world\">Hello World</h1>\n")
        XCTAssertEqual(render("### A/B c"), "<h3 id=\"ab-c\">A/B c</h3>\n")
    }

    func testParagraphsAndInlineStyles() {
        XCTAssertEqual(
            render("Some *em* and **strong** and `code` and ~~gone~~."),
            "<p>Some <em>em</em> and <strong>strong</strong> and <code>code</code> and <del>gone</del>.</p>\n"
        )
    }

    func testListsIncludingTaskItems() {
        let html = render("- [x] done\n- [ ] todo\n- plain\n\n1. one\n2. two")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked> done</li>"))
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled> todo</li>"))
        XCTAssertTrue(html.contains("<li>plain</li>"))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("<li>two</li>"))
    }

    func testOrderedListStartIndex() {
        XCTAssertTrue(render("3. three\n4. four").contains("<ol start=\"3\">"))
    }

    func testFencedCodeKeepsLanguageAndEscapes() {
        XCTAssertEqual(
            render("```swift\nlet a = \"<b>\"\n```"),
            "<pre><code class=\"language-swift\">let a = &quot;&lt;b&gt;&quot;\n</code></pre>\n"
        )
    }

    func testBlockQuoteThematicBreakAndLineBreaks() {
        XCTAssertEqual(render("> quoted"), "<blockquote>\n<p>quoted</p>\n</blockquote>\n")
        XCTAssertEqual(render("---"), "<hr>\n")
        XCTAssertEqual(render("a  \nb"), "<p>a<br>\nb</p>\n")
        XCTAssertEqual(render("a\nb"), "<p>a\nb</p>\n")
    }

    func testLinksAndImagesEscapeAttributes() {
        XCTAssertEqual(
            render("[t](https://x.y/?a=1&b=\"2\")"),
            "<p><a href=\"https://x.y/?a=1&amp;b=&quot;2&quot;\">t</a></p>\n"
        )
        XCTAssertEqual(
            render("![alt <x>](<img/a b.png> \"Title\")"),
            "<p><img src=\"img/a b.png\" alt=\"alt &lt;x&gt;\" title=\"Title\"></p>\n"
        )
    }

    func testTablesWithAlignment() {
        let html = render("| a | b |\n|:--|--:|\n| 1 | 2 |")
        XCTAssertTrue(html.hasPrefix("<table>\n<thead>\n<tr><th align=\"left\">a</th><th align=\"right\">b</th></tr>\n</thead>\n<tbody>\n<tr><td align=\"left\">1</td><td align=\"right\">2</td></tr>\n</tbody>\n</table>\n"))
    }

    func testRawHTMLIsEscapedNeverRendered() {
        XCTAssertEqual(render("<script>alert(1)</script>"), "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n")
        XCTAssertEqual(render("a <b>bold</b> c"), "<p>a &lt;b&gt;bold&lt;/b&gt; c</p>\n")
    }

    func testEmptyDocumentRendersEmptyString() {
        XCTAssertEqual(render(""), "")
    }
}
