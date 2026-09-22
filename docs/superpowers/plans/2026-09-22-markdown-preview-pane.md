# Native Markdown Preview Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opening a Markdown file from the explorer shows a rendered, read-only preview as a native pane in the split layout beside the tree's session, with an Edit button that opens Unpeel's Markdown plugin.

**Architecture:** A new fork-only library target `UnpeelMarkdownPreview` renders Markdown (swift-markdown → HTML) inside a `WKWebView` whose only route to local files is a custom `unpeel-preview://` scheme handler confined to the project root. The pane model gains a transient leaf `PaneContent.markdownPreview(path:)` (stripped before persistence, like the launcher); `UnpeelStore.openMarkdownPreview` inserts or focuses it beside the session; `TerminalPaneView` renders it with the standard pane chrome. The explorer routes markdown files to the preview and everything else to the open-with rules. Spec: `docs/superpowers/specs/2026-09-22-markdown-preview-pane-design.md`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, WebKit (`WKWebView`, `WKURLSchemeHandler`), `swift-markdown` 0.9 (`Markdown` module, cmark-gfm), XCTest. Package `clients/native/UnpeelNative`.

## Global Constraints

- Swift tools 6.0, strict concurrency, macOS 13 floor. `UnpeelMarkdownPreview` may import only Foundation, AppKit, SwiftUI, WebKit, Markdown, os — never app types. `UnpeelExplorer` keeps its Foundation/AppKit-only rule.
- Upstream files edited, the complete list: `Package.swift`, `Sources/UnpeelNative/PaneLayoutState.swift`, `Sources/UnpeelNative/UnpeelStore.swift`, `Sources/UnpeelNative/Views/TerminalPaneView.swift`, `docs/agents/clients/panes.md`. Every edited block is introduced by a `// Fork-only: markdown preview pane` comment. `protocol/pane-layout-operations-v1.json`, `DurablePaneNode`, `PaneLayoutController`, `AppDelegate.swift`, `RootView.swift` are untouched.
- Preview panes are transient: never encoded by `DurablePaneGroup`; never counted toward `maximumSessionLeafCount` (8) or the two-leaf minimum; a group whose last session leaf goes loses its preview leaves.
- Placement: right split, ratio 0.5, beside the tree's session pane; reuse by exact canonical path within the group.
- Local resources are served only through `unpeel-preview://`; a path is served only if its realpath is inside the project root's realpath, it is a regular file, and its extension is in the allowed set. No `file:` base URL; `allowFileAccessFromFileURLs` never set. Files over 4 MB (4_194_304 bytes) are not rendered.
- Markdown extensions (mirror of `protocol/app-registry.json`): `md`, `markdown`, `mdown`, `mkd`.
- Menu titles exactly: "Open", "Open in Markdown Editor", "Open in Editor". For markdown-only file targets the list starts `[.open, .openInMarkdownEditor, .openInEditor, .revealInFinder, .quickLook, nil]`; for other files `[.open, .openInEditor, .revealInFinder, .quickLook, nil]`; mixed sets (markdown + other files) omit `.openInMarkdownEditor`.
- Logging via `os.Logger`, paths `privacy: .private`; no `print`. Comments state constraints the code cannot show.
- Commands run from `/Users/alimazid/unpeel/clients/native/UnpeelNative`; tests with `swift test --filter <TestClass>` (the whole package compiles for any filter). The Rust bridge exists at `crates/target/native-bridge/debug/`. Full gate: `clients/native/test-native.sh` from the repo root (a few minutes) — run once per task before committing.
- Commit with plain `git commit -m …` (never `-n`/`--no-verify`); every message ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Branch `feat/markdown-preview-pane`; never push.
- Never launch, quit, or signal `/Applications/Unpeel.app`.

---

### Task 1: New target `UnpeelMarkdownPreview` with `MarkdownHTMLRenderer`

**Files:**
- Modify: `clients/native/UnpeelNative/Package.swift`
- Create: `clients/native/UnpeelNative/Sources/UnpeelMarkdownPreview/MarkdownHTMLRenderer.swift`
- Create: `clients/native/UnpeelNative/Sources/UnpeelMarkdownPreview/HTMLEscaping.swift`
- Test: `clients/native/UnpeelNative/Tests/UnpeelMarkdownPreviewTests/MarkdownHTMLRendererTests.swift`

**Interfaces:**
- Produces: `public enum MarkdownHTMLRenderer { public static func html(from markdown: String) -> String }` — returns the **body** HTML only; `HTMLEscaping.escape(_:)` and `escapeAttribute(_:)`.

- [ ] **Step 1: Add the dependency and targets to `Package.swift`**

In `dependencies`, after the Sparkle package:

```swift
        // Fork-only: markdown preview pane. Apple's cmark-gfm based parser
        // for the rendered preview; the module is `Markdown`.
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.9.0"),
```

In `targets`, after the `UnpeelExplorer` target:

```swift
        // Rendered Markdown preview pane (fork-only feature). WebKit +
        // swift-markdown only; never imports app types.
        .target(
            name: "UnpeelMarkdownPreview",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/UnpeelMarkdownPreview"
        ),
```

Add `"UnpeelMarkdownPreview",` to the `UnpeelNative` executable target's dependencies right after `"UnpeelExplorer",`. After the `UnpeelExplorerTests` test target add:

```swift
        .testTarget(
            name: "UnpeelMarkdownPreviewTests",
            dependencies: ["UnpeelMarkdownPreview"],
            path: "Tests/UnpeelMarkdownPreviewTests"
        ),
```

- [ ] **Step 2: Write the failing renderer tests**

`Tests/UnpeelMarkdownPreviewTests/MarkdownHTMLRendererTests.swift`:

```swift
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
            render("![alt <x>](img/a b.png \"Title\")"),
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift package resolve 2>&1 | tail -3 && swift test --filter MarkdownHTMLRendererTests 2>&1 | tail -8`
Expected: the package resolves (`swift-markdown` fetched) and the build fails with "cannot find 'MarkdownHTMLRenderer' in scope". If `swift package resolve` fails to fetch the package, stop and report BLOCKED (the spec names an in-repo fallback renderer; that is a design change for the controller).

- [ ] **Step 4: Implement escaping and the renderer**

`Sources/UnpeelMarkdownPreview/HTMLEscaping.swift`:

```swift
import Foundation

enum HTMLEscaping {
    /// Text content: `&`, `<`, `>` (quotes are harmless in text but escaped
    /// too so attribute and text escaping never diverge in tests).
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func escapeAttribute(_ value: String) -> String {
        escape(value)
    }
}
```

`Sources/UnpeelMarkdownPreview/MarkdownHTMLRenderer.swift`:

```swift
import Foundation
import Markdown

/// Markdown → HTML body. Raw HTML in the source is always emitted as escaped
/// text: the preview shows the user's file, never runs it.
public enum MarkdownHTMLRenderer {
    public static func html(from markdown: String) -> String {
        let document = Document(parsing: markdown)
        var walker = HTMLWalker()
        return walker.visit(document)
    }

    /// `#Hello World` → `hello-world`, GitHub's rule minus the uniqueness suffix.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "-" {
                out += "-"
            }
        }
        return out
    }
}

private struct HTMLWalker: MarkupVisitor {
    typealias Result = String

    mutating func defaultVisit(_ markup: any Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    // MARK: Blocks

    mutating func visitDocument(_ document: Document) -> String {
        defaultVisit(document)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = defaultVisit(heading)
        let id = MarkdownHTMLRenderer.slug(heading.plainText)
        return "<h\(heading.level) id=\"\(HTMLEscaping.escapeAttribute(id))\">\(inner)</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(defaultVisit(paragraph))</p>\n"
    }

    mutating func visitBlockQuote(_ quote: BlockQuote) -> String {
        "<blockquote>\n\(defaultVisit(quote))</blockquote>\n"
    }

    mutating func visitCodeBlock(_ block: CodeBlock) -> String {
        let cls = block.language.map { " class=\"language-\(HTMLEscaping.escapeAttribute($0))\"" } ?? ""
        return "<pre><code\(cls)>\(HTMLEscaping.escape(block.code))</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        "<p>\(HTMLEscaping.escape(html.rawHTML.trimmingCharacters(in: .newlines)))</p>\n"
    }

    mutating func visitThematicBreak(_: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul>\n\(defaultVisit(list))</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        return "<ol\(start)>\n\(defaultVisit(list))</ol>\n"
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        // A single-paragraph item renders inline (`<li>text</li>`) like
        // GitHub's tight lists; anything richer keeps its block markup.
        let inner: String
        if item.childCount == 1, let paragraph = item.child(at: 0) as? Paragraph {
            inner = defaultVisit(paragraph)
        } else {
            inner = defaultVisit(item)
        }
        switch item.checkbox {
        case .checked:
            return "<li class=\"task\"><input type=\"checkbox\" disabled checked> \(inner)</li>\n"
        case .unchecked:
            return "<li class=\"task\"><input type=\"checkbox\" disabled> \(inner)</li>\n"
        case nil:
            return "<li>\(inner)</li>\n"
        }
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) -> String {
        alignments = table.columnAlignments
        let head = visit(table.head)
        let body = visit(table.body)
        return "<table>\n<thead>\n\(head)</thead>\n<tbody>\n\(body)</tbody>\n</table>\n"
    }

    private var alignments: [Table.ColumnAlignment?] = []

    mutating func visitTableHead(_ head: Table.Head) -> String {
        "<tr>\(cells(of: head, tag: "th"))</tr>\n"
    }

    mutating func visitTableBody(_ body: Table.Body) -> String {
        defaultVisit(body)
    }

    mutating func visitTableRow(_ row: Table.Row) -> String {
        "<tr>\(cells(of: row, tag: "td"))</tr>\n"
    }

    private mutating func cells(of container: any Markup, tag: String) -> String {
        var out = ""
        for (index, cell) in container.children.enumerated() {
            let align = index < alignments.count ? alignments[index] : nil
            let attr: String
            switch align {
            case .left: attr = " align=\"left\""
            case .center: attr = " align=\"center\""
            case .right: attr = " align=\"right\""
            case nil: attr = ""
            }
            out += "<\(tag)\(attr)>\(defaultVisit(cell))</\(tag)>"
        }
        return out
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) -> String {
        HTMLEscaping.escape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(defaultVisit(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(defaultVisit(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strike: Strikethrough) -> String {
        "<del>\(defaultVisit(strike))</del>"
    }

    mutating func visitInlineCode(_ code: InlineCode) -> String {
        "<code>\(HTMLEscaping.escape(code.code))</code>"
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String {
        HTMLEscaping.escape(html.rawHTML)
    }

    mutating func visitSoftBreak(_: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        let href = HTMLEscaping.escapeAttribute(link.destination ?? "")
        return "<a href=\"\(href)\">\(defaultVisit(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let src = HTMLEscaping.escapeAttribute(image.source ?? "")
        let alt = HTMLEscaping.escapeAttribute(image.plainText)
        let title = image.title.map { " title=\"\(HTMLEscaping.escapeAttribute($0))\"" } ?? ""
        return "<img src=\"\(src)\" alt=\"\(alt)\"\(title)>"
    }
}
```

If `Table.ColumnAlignment`, `ListItem.checkbox`, `Image.title` or `Heading.plainText` differ in name in swift-markdown 0.9, look them up in `.build/checkouts/swift-markdown/Sources/Markdown/` and adapt — do not change the expected HTML in the tests.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter MarkdownHTMLRendererTests 2>&1 | tail -5`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Package.swift clients/native/UnpeelNative/Package.resolved \
        clients/native/UnpeelNative/Sources/UnpeelMarkdownPreview clients/native/UnpeelNative/Tests/UnpeelMarkdownPreviewTests
git commit -m "feat(preview): add UnpeelMarkdownPreview target with a GFM to HTML renderer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(If `Package.resolved` is git-ignored, skip it.)

---

### Task 2: Document template, resource policy and the `unpeel-preview://` scheme handler

**Files:**
- Create: `Sources/UnpeelMarkdownPreview/MarkdownPreviewDocument.swift`
- Create: `Sources/UnpeelMarkdownPreview/PreviewResourcePolicy.swift`
- Create: `Sources/UnpeelMarkdownPreview/PreviewSchemeHandler.swift`
- Create: `Sources/UnpeelMarkdownPreview/PreviewCanonicalPath.swift`
- Test: `Tests/UnpeelMarkdownPreviewTests/MarkdownPreviewDocumentTests.swift`, `PreviewResourcePolicyTests.swift`, `PreviewSchemeHandlerTests.swift`

**Interfaces:**
- Consumes: `MarkdownHTMLRenderer.html(from:)`.
- Produces:
  - `public enum MarkdownPreviewDocument { public static func page(bodyHTML: String, title: String) -> String; public static let scheme = "unpeel-preview"; public static let messageHandlerName = "unpeelPreview"; public static func url(forPath path: String) -> URL }` — `url(forPath:)` yields `unpeel-preview://local<percent-encoded absolute path>`.
  - `public struct PreviewResourcePolicy { public init(projectRoot: String); public enum Decision: Equatable { case serve(path: String, mimeType: String); case refuse(String) }; public func decide(requestPath: String) -> Decision }`.
  - `public final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler { public init(policy: PreviewResourcePolicy) }`.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelMarkdownPreviewTests/MarkdownPreviewDocumentTests.swift`:

```swift
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
```

`Tests/UnpeelMarkdownPreviewTests/PreviewResourcePolicyTests.swift`:

```swift
import XCTest
@testable import UnpeelMarkdownPreview

final class PreviewResourcePolicyTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-policy-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("# hi".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("img/a.png"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("s.md"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.md"),
            withDestinationURL: outside.appendingPathComponent("s.md")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func policy() -> PreviewResourcePolicy {
        PreviewResourcePolicy(projectRoot: root.path)
    }

    func testServesMarkdownAndImagesInsideTheRoot() {
        XCTAssertEqual(
            policy().decide(requestPath: root.appendingPathComponent("README.md").path),
            .serve(path: PreviewCanonicalPath.resolve(root.appendingPathComponent("README.md").path)!, mimeType: "text/markdown")
        )
        XCTAssertEqual(
            policy().decide(requestPath: root.appendingPathComponent("img/a.png").path),
            .serve(path: PreviewCanonicalPath.resolve(root.appendingPathComponent("img/a.png").path)!, mimeType: "image/png")
        )
    }

    func testRefusesOutsideTraversalSymlinkEscapeDirectoriesAndOtherTypes() {
        XCTAssertEqual(policy().decide(requestPath: outside.appendingPathComponent("s.md").path), .refuse("outside project root"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("../outside/s.md").path), .refuse("outside project root"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("escape.md").path), .refuse("outside project root"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("img").path), .refuse("not a regular file"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("notes.txt").path), .refuse("type not allowed"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("missing.md").path), .refuse("not a regular file"))
    }
}
```

`Tests/UnpeelMarkdownPreviewTests/PreviewSchemeHandlerTests.swift`:

```swift
import WebKit
import XCTest
@testable import UnpeelMarkdownPreview

/// Records what the handler sends; `WKURLSchemeTask` is a protocol so a
/// plain object can stand in for WebKit's task.
private final class RecordingTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var data = Data()
    var finished = false
    var error: Error?
    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}

@MainActor
final class PreviewSchemeHandlerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-handler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Title\n\ntext".utf8).write(to: root.appendingPathComponent("doc.md"))
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("p.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(_ path: String) -> RecordingTask {
        let handler = PreviewSchemeHandler(policy: PreviewResourcePolicy(projectRoot: root.path))
        let task = RecordingTask(url: MarkdownPreviewDocument.url(forPath: path))
        handler.webView(WKWebView(), start: task)
        return task
    }

    func testMarkdownIsRenderedAsAFullHTMLPage() {
        let task = run(root.appendingPathComponent("doc.md").path)
        XCTAssertEqual(task.response?.mimeType, "text/html")
        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: task.data, as: UTF8.self)
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"))
        XCTAssertTrue(html.contains("<title>doc.md</title>"))
        XCTAssertTrue(task.finished)
    }

    func testOtherAllowedFilesAreServedRaw() {
        let task = run(root.appendingPathComponent("p.png").path)
        XCTAssertEqual(task.response?.mimeType, "image/png")
        XCTAssertEqual(task.data, Data([1, 2, 3]))
        XCTAssertTrue(task.finished)
    }

    func testRefusedPathsGet404AndNoBytes() {
        let task = run("/etc/hosts")
        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(task.data.count, 0)
        XCTAssertTrue(task.finished)
    }

    func testOversizedMarkdownIsNotRendered() throws {
        let big = root.appendingPathComponent("big.md")
        try Data(repeating: 0x61, count: 4_194_305).write(to: big)
        let task = run(big.path)
        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: task.data, as: UTF8.self).contains("too large to preview"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "MarkdownPreviewDocumentTests|PreviewResourcePolicyTests|PreviewSchemeHandlerTests" 2>&1 | tail -6`
Expected: build failure, missing `MarkdownPreviewDocument`, `PreviewResourcePolicy`, `PreviewSchemeHandler`, `PreviewCanonicalPath`.

- [ ] **Step 3: Implement**

`Sources/UnpeelMarkdownPreview/PreviewCanonicalPath.swift` (a copy of the explorer's helper — `UnpeelMarkdownPreview` does not depend on `UnpeelExplorer`):

```swift
import Foundation

/// `realpath(3)`: resolves symlinks and `..`. Never `URL.resolvingSymlinksInPath()`,
/// which strips `/private` and would disagree with FSEvents paths.
enum PreviewCanonicalPath {
    static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
```

`Sources/UnpeelMarkdownPreview/PreviewResourcePolicy.swift`:

```swift
import Foundation

/// The only gate between the preview's web content and the disk. A request
/// is served when its realpath sits inside the project root's realpath, it
/// is a regular file, and its type is one the preview needs.
public struct PreviewResourcePolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case serve(path: String, mimeType: String)
        case refuse(String)
    }

    static let mimeTypes: [String: String] = [
        "md": "text/markdown", "markdown": "text/markdown", "mdown": "text/markdown", "mkd": "text/markdown",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "svg": "image/svg+xml", "webp": "image/webp", "bmp": "image/bmp", "tiff": "image/tiff", "tif": "image/tiff",
    ]

    private let canonicalRoot: String?

    public init(projectRoot: String) {
        canonicalRoot = PreviewCanonicalPath.resolve(projectRoot)
    }

    public func decide(requestPath: String) -> Decision {
        guard let root = canonicalRoot, let path = PreviewCanonicalPath.resolve(requestPath) else {
            return .refuse("not a regular file")
        }
        guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            return .refuse("outside project root")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .refuse("not a regular file")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard let mime = Self.mimeTypes[ext] else { return .refuse("type not allowed") }
        return .serve(path: path, mimeType: mime)
    }
}
```

Note the ordering: a symlink whose target is outside resolves outside → "outside project root" before the regular-file check; a missing file fails `realpath` → "not a regular file".

`Sources/UnpeelMarkdownPreview/MarkdownPreviewDocument.swift`:

```swift
import Foundation

/// The page around a rendered body, and the `unpeel-preview://local/<path>`
/// URL form that keeps every local reference inside the scheme handler.
public enum MarkdownPreviewDocument {
    public static let scheme = "unpeel-preview"
    public static let host = "local"
    public static let messageHandlerName = "unpeelPreview"
    public static let maximumBytes = 4_194_304

    public static func url(forPath path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        return components.url!
    }

    public static func path(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return url.path
    }

    public static func page(bodyHTML: String, title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTMLEscaping.escape(title))</title>
        <style>\(stylesheet)</style>
        </head><body>
        <article class="markdown-body">\(bodyHTML)</article>
        <script>\(script)</script>
        </body></html>
        """
    }

    public static func unavailablePage(title: String, message: String) -> String {
        page(bodyHTML: "<p class=\"notice\">\(HTMLEscaping.escape(message))</p>", title: title)
    }

    /// Reports mouse-down (so the pane can become active), Escape, and
    /// answers scroll-position queries; nothing else runs in the page.
    static let script = """
    document.addEventListener('mousedown', () => {
      webkit.messageHandlers.unpeelPreview.postMessage({type: 'activate'});
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') { webkit.messageHandlers.unpeelPreview.postMessage({type: 'escape'}); }
    });
    """

    static let stylesheet = """
    :root { color-scheme: light dark; --fg: #1f2328; --bg: #ffffff; --muted: #59636e; --border: #d1d9e0; --code-bg: #f6f8fa; --link: #0969da; }
    @media (prefers-color-scheme: dark) { :root { --fg: #e6edf3; --bg: #0d1117; --muted: #9198a1; --border: #3d444d; --code-bg: #161b22; --link: #4493f8; } }
    html, body { margin: 0; background: var(--bg); color: var(--fg); }
    .markdown-body { font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; padding: 20px 28px 48px; max-width: 900px; margin: 0 auto; word-wrap: break-word; }
    .markdown-body h1, .markdown-body h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
    .markdown-body h1 { font-size: 1.9em; margin: .6em 0 .5em; } .markdown-body h2 { font-size: 1.5em; margin: 1.2em 0 .6em; }
    .markdown-body h3 { font-size: 1.25em; } .markdown-body h4 { font-size: 1.05em; }
    .markdown-body a { color: var(--link); text-decoration: none; } .markdown-body a:hover { text-decoration: underline; }
    .markdown-body code { font: 0.9em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code-bg); padding: .15em .35em; border-radius: 5px; }
    .markdown-body pre { background: var(--code-bg); padding: 14px 16px; border-radius: 8px; overflow: auto; }
    .markdown-body pre code { background: none; padding: 0; }
    .markdown-body blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: 4px solid var(--border); }
    .markdown-body table { border-collapse: collapse; margin: 1em 0; } .markdown-body th, .markdown-body td { border: 1px solid var(--border); padding: 6px 12px; }
    .markdown-body th { background: var(--code-bg); }
    .markdown-body img { max-width: 100%; }
    .markdown-body hr { border: 0; border-top: 2px solid var(--border); margin: 1.5em 0; }
    .markdown-body li.task { list-style: none; margin-left: -1.3em; }
    .markdown-body input[type=checkbox] { margin-right: .4em; }
    .markdown-body .notice { color: var(--muted); font-style: italic; }
    """
}
```

`Sources/UnpeelMarkdownPreview/PreviewSchemeHandler.swift`:

```swift
import Foundation
import WebKit
import os

/// Serves `unpeel-preview://local/<path>`: markdown files as rendered pages,
/// images raw, everything the policy refuses as an empty 404. Runs on the
/// main thread (WebKit calls scheme handlers there); reads are small by
/// construction (`maximumBytes`).
@MainActor
public final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let logger = Logger(subsystem: "com.unpeel.explorer", category: "preview")
    private let policy: PreviewResourcePolicy

    public init(policy: PreviewResourcePolicy) {
        self.policy = policy
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let path = MarkdownPreviewDocument.path(from: url) else {
            respond(task, url: task.request.url, status: 404, mimeType: "text/plain", data: Data())
            return
        }
        switch policy.decide(requestPath: path) {
        case let .refuse(reason):
            Self.logger.info("preview refused \(path, privacy: .private): \(reason, privacy: .public)")
            respond(task, url: url, status: 404, mimeType: "text/plain", data: Data())
        case let .serve(resolved, mime):
            guard let data = FileManager.default.contents(atPath: resolved) else {
                respond(task, url: url, status: 404, mimeType: "text/plain", data: Data())
                return
            }
            let name = (resolved as NSString).lastPathComponent
            if mime == "text/markdown" {
                let html: String
                if data.count > MarkdownPreviewDocument.maximumBytes {
                    html = MarkdownPreviewDocument.unavailablePage(
                        title: name, message: "\(name) is too large to preview (over 4 MB). Open it in the editor instead."
                    )
                } else {
                    html = MarkdownPreviewDocument.page(
                        bodyHTML: MarkdownHTMLRenderer.html(from: String(decoding: data, as: UTF8.self)),
                        title: name
                    )
                }
                respond(task, url: url, status: 200, mimeType: "text/html", data: Data(html.utf8))
            } else {
                respond(task, url: url, status: 200, mimeType: mime, data: data)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL?, status: Int, mimeType: String, data: Data) {
        let response = HTTPURLResponse(
            url: url ?? URL(string: "\(MarkdownPreviewDocument.scheme)://\(MarkdownPreviewDocument.host)/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType + (mimeType.hasPrefix("text/") ? "; charset=utf-8" : ""), "Content-Length": "\(data.count)"]
        )!
        task.didReceive(response)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }
}
```

`HTTPURLResponse.mimeType` derives from the Content-Type header, so the tests' `response?.mimeType == "text/html"` holds.

Concurrency note: if the compiler rejects the `@MainActor` class satisfying `WKURLSchemeHandler`'s requirements ("main actor-isolated instance method cannot satisfy nonisolated requirement"), declare both `webView(_:start:)` / `webView(_:stop:)` as `nonisolated` and wrap their bodies in `MainActor.assumeIsolated { … }` — WebKit calls scheme handlers on the main thread, and the policy is `Sendable`. Keep the tests unchanged.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "MarkdownPreviewDocumentTests|PreviewResourcePolicyTests|PreviewSchemeHandlerTests" 2>&1 | tail -5`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelMarkdownPreview clients/native/UnpeelNative/Tests/UnpeelMarkdownPreviewTests
git commit -m "feat(preview): page template, root-confined resource policy and scheme handler

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: File observer, web view and the pane body view

**Files:**
- Create: `Sources/UnpeelMarkdownPreview/MarkdownFileObserver.swift`
- Create: `Sources/UnpeelMarkdownPreview/MarkdownPreviewWebView.swift`
- Create: `Sources/UnpeelMarkdownPreview/MarkdownPreviewPaneView.swift`
- Test: `Tests/UnpeelMarkdownPreviewTests/MarkdownFileObserverTests.swift`

**Interfaces:**
- Consumes: `MarkdownPreviewDocument`, `PreviewSchemeHandler`, `PreviewResourcePolicy`.
- Produces:
  - `public final class MarkdownFileObserver { public init(path: String, debounce: TimeInterval = 0.15, onChange: @escaping @MainActor () -> Void); public func start(); public func stop() }`
  - `public struct MarkdownPreviewPaneView: View { public init(path: String, projectRoot: String, onEdit: @escaping () -> Void, onActivate: @escaping () -> Void, onEscape: @escaping () -> Void, onOpenMarkdown: @escaping (String) -> Void) }` — the whole pane body including a slim toolbar with the **Edit** button.

- [ ] **Step 1: Write the failing observer test**

`Tests/UnpeelMarkdownPreviewTests/MarkdownFileObserverTests.swift`:

```swift
import XCTest
@testable import UnpeelMarkdownPreview

@MainActor
final class MarkdownFileObserverTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-observer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("doc.md")
        try Data("one".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testWriteFiresOnceAfterDebounce() throws {
        let fired = expectation(description: "change")
        var count = 0
        let observer = MarkdownFileObserver(path: file.path, debounce: 0.05) {
            count += 1
            if count == 1 { fired.fulfill() }
        }
        observer.start()
        defer { observer.stop() }
        try Data("two".utf8).write(to: file)
        try Data("three".utf8).write(to: file)
        wait(for: [fired], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(count, 1)
    }

    func testAtomicReplaceIsObservedAndTheObserverReArms() throws {
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        var count = 0
        let observer = MarkdownFileObserver(path: file.path, debounce: 0.05) {
            count += 1
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
        }
        observer.start()
        defer { observer.stop() }
        // Editors save atomically: write a sibling, then rename over the file.
        let temp = file.deletingLastPathComponent().appendingPathComponent("doc.md.tmp")
        try Data("atomic".utf8).write(to: temp)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        wait(for: [first], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try Data("again".utf8).write(to: file)
        wait(for: [second], timeout: 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter MarkdownFileObserverTests 2>&1 | tail -4`
Expected: "cannot find 'MarkdownFileObserver' in scope".

- [ ] **Step 3: Implement the observer**

`Sources/UnpeelMarkdownPreview/MarkdownFileObserver.swift`:

```swift
import Foundation

/// Watches ONE file with a vnode DispatchSource. Atomic saves replace the
/// inode (the source then reports `.delete`/`.rename`), so after such an
/// event the observer closes its descriptor and re-opens the path a moment
/// later; the callback is debounced so a burst of writes yields one reload.
@MainActor
public final class MarkdownFileObserver {
    private let path: String
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var pending: DispatchWorkItem?

    public init(path: String, debounce: TimeInterval = 0.15, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        guard source == nil else { return }
        arm()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        disarm()
    }

    private func arm() {
        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                self.disarm()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.arm()
                }
            }
            self.scheduleChange()
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    private func disarm() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit {
        // Cancelling closes the descriptor through the cancel handler.
        source?.cancel()
    }
}
```

- [ ] **Step 4: Run the observer tests**

Run: `swift test --filter MarkdownFileObserverTests 2>&1 | tail -4`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Implement the web view and pane body**

`Sources/UnpeelMarkdownPreview/MarkdownPreviewWebView.swift`:

```swift
import AppKit
import SwiftUI
import WebKit

/// The rendered document. Loads `unpeel-preview://local/<path>` so every
/// relative image and link resolves through the scheme handler; reloads
/// keep the scroll position; link clicks never navigate the web view itself.
struct MarkdownPreviewWebView: NSViewRepresentable {
    let path: String
    let projectRoot: String
    /// Bumped by the owner to request a reload (file changed).
    let reloadToken: Int
    let onActivate: () -> Void
    let onEscape: () -> Void
    let onOpenMarkdown: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            PreviewSchemeHandler(policy: PreviewResourcePolicy(projectRoot: projectRoot)),
            forURLScheme: MarkdownPreviewDocument.scheme
        )
        configuration.userContentController.add(
            context.coordinator, name: MarkdownPreviewDocument.messageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: MarkdownPreviewDocument.url(forPath: path)))
        context.coordinator.lastReloadToken = reloadToken
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.reloadKeepingScroll(webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: MarkdownPreviewDocument.messageHandlerName
        )
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownPreviewWebView
        var lastReloadToken = 0
        private var pendingScrollY: Double?

        init(_ parent: MarkdownPreviewWebView) {
            self.parent = parent
        }

        func reloadKeepingScroll(_ webView: WKWebView) {
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                self?.pendingScrollY = value as? Double
                webView.reload()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let y = pendingScrollY else { return }
            pendingScrollY = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(y))")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            switch url.scheme {
            case MarkdownPreviewDocument.scheme:
                if action.navigationType == .linkActivated,
                   let target = MarkdownPreviewDocument.path(from: url),
                   MarkdownFileTypes.isMarkdown(target)
                {
                    parent.onOpenMarkdown(target)
                    return decisionHandler(.cancel)
                }
                // The initial load, reloads and in-page anchors.
                decisionHandler(action.navigationType == .linkActivated ? .cancel : .allow)
            case "http", "https", "mailto":
                if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            default:
                decisionHandler(.cancel)
            }
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "activate": parent.onActivate()
            case "escape": parent.onEscape()
            default: break
            }
        }
    }
}

/// Mirror of the plugin registry's markdown extensions
/// (`protocol/app-registry.json`); the explorer keeps its own copy.
public enum MarkdownFileTypes {
    public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public static func isMarkdown(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
```

In-page anchor clicks (`#heading`) are `linkActivated` to the same document with a fragment; allow them: change the first case's final line to `decisionHandler(action.navigationType == .linkActivated && url.fragment == nil ? .cancel : .allow)`.

`Sources/UnpeelMarkdownPreview/MarkdownPreviewPaneView.swift`:

```swift
import SwiftUI

/// Pane body: a slim toolbar (file name, Edit) above the rendered document.
/// The pane header itself belongs to the app; this view owns only what is
/// specific to previews. Reloads on disk changes; shows a notice once the
/// file is gone (the app drops the pane on its next validation).
public struct MarkdownPreviewPaneView: View {
    public let path: String
    public let projectRoot: String
    public let onEdit: () -> Void
    public let onActivate: () -> Void
    public let onEscape: () -> Void
    public let onOpenMarkdown: (String) -> Void

    @State private var reloadToken = 0
    @State private var observer: MarkdownFileObserver?
    @State private var missing = false

    public init(
        path: String,
        projectRoot: String,
        onEdit: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onOpenMarkdown: @escaping (String) -> Void
    ) {
        self.path = path
        self.projectRoot = projectRoot
        self.onEdit = onEdit
        self.onActivate = onActivate
        self.onEscape = onEscape
        self.onOpenMarkdown = onOpenMarkdown
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Preview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit", action: onEdit)
                    .controlSize(.small)
                    .help("Open in the Markdown plugin")
                    .accessibilityIdentifier("markdown-preview-edit")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            if missing {
                Text("\((path as NSString).lastPathComponent) is no longer available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownPreviewWebView(
                    path: path,
                    projectRoot: projectRoot,
                    reloadToken: reloadToken,
                    onActivate: onActivate,
                    onEscape: onEscape,
                    onOpenMarkdown: onOpenMarkdown
                )
            }
        }
        .onAppear(perform: startObserving)
        .onDisappear { observer?.stop(); observer = nil }
    }

    private func startObserving() {
        guard observer == nil else { return }
        let observer = MarkdownFileObserver(path: path) {
            if FileManager.default.fileExists(atPath: path) {
                missing = false
                reloadToken += 1
            } else {
                missing = true
            }
        }
        observer.start()
        self.observer = observer
    }
}
```

- [ ] **Step 6: Build the package and run the target's tests**

Run: `swift build 2>&1 | grep -E "error|warning: .*UnpeelMarkdownPreview" | head; swift test --filter UnpeelMarkdownPreviewTests 2>&1 | tail -3`
Expected: no errors; `Executed 20 tests, with 0 failures` (10 + 8 + 2).

- [ ] **Step 7: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelMarkdownPreview clients/native/UnpeelNative/Tests/UnpeelMarkdownPreviewTests
git commit -m "feat(preview): live-reloading WKWebView pane body with root-confined navigation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Pane model — transient `.markdownPreview` leaf

**Files:**
- Modify: `Sources/UnpeelNative/PaneLayoutState.swift` (`PaneContent` :9-22; `PaneNode.sessionLeaves/containsLauncher` :122-127; `hashStructure` :266-283; `insertSession(_:splitting:edge:)` :583-611; after `insertLauncher(projectID:beside:at:)` :~719; `detachPane` :770-772; `reconcile(eligibleSessionIDs:)` :922-925; `canonicalize` :1001-1009 and :1032-1034; `DurablePaneGroup.init?` :1172-1181)
- Test: `Tests/UnpeelNativeTests/PaneLayoutStateTests.swift` (append)

**Interfaces:**
- Produces: `PaneContent.markdownPreview(path: String)`, `PaneContent.markdownPreviewPath: String?`, `PaneContent.isTransient: Bool`, `PaneNode.containsTransientLeaf: Bool`, `PaneLayoutState.insertMarkdownPreview(path:beside:at:newGroupID:newRepresentativePaneID:newPaneID:) throws -> PaneLocation`, `PaneLayoutState.location(ofMarkdownPreview:inGroupContaining:) -> PaneLocation?`.

- [ ] **Step 1: Write the failing tests** (append inside `PaneLayoutStateTests`)

```swift
    // MARK: - Fork-only: markdown preview leaves

    private let previewPath = "/r/README.md"

    func testInsertMarkdownPreviewBesideSoloSessionCreatesGroupOnTheRight() throws {
        var state = PaneLayoutState(groups: [])
        let location = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let group = try XCTUnwrap(state.group(id: location.groupID))
        XCTAssertEqual(group.sessionIDs, ["s1"])
        XCTAssertEqual(group.root.leaves.map(\.content), [.session(id: "s1"), .markdownPreview(path: previewPath)])
        guard case let .split(split) = group.root else { return XCTFail("expected a split") }
        XCTAssertEqual(split.direction, .horizontal)
        XCTAssertEqual(split.ratio, 0.5)
        XCTAssertEqual(group.representativeSessionID, "s1")
    }

    func testInsertMarkdownPreviewBesideGroupedSessionSplitsThatLeaf() throws {
        var state = twoPaneState()
        let location = try state.insertMarkdownPreview(path: previewPath, beside: "s2", at: .right)
        XCTAssertEqual(location.groupID, groupID)
        let group = try XCTUnwrap(state.group(id: groupID))
        XCTAssertEqual(group.root.leaves.map(\.content), [.session(id: "s1"), .session(id: "s2"), .markdownPreview(path: previewPath)])
        XCTAssertEqual(group.root.sessionLeaves.count, 2)
    }

    func testLocationOfMarkdownPreviewFindsOnlyWithinTheSessionsGroup() throws {
        var state = twoPaneState()
        let inserted = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        XCTAssertEqual(state.location(ofMarkdownPreview: previewPath, inGroupContaining: "s2"), inserted)
        XCTAssertNil(state.location(ofMarkdownPreview: "/r/other.md", inGroupContaining: "s1"))
        XCTAssertNil(state.location(ofMarkdownPreview: previewPath, inGroupContaining: "s9"))
    }

    func testPreviewLeavesDoNotCountTowardTheSessionCap() throws {
        var state = PaneLayoutState(groups: [])
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        for index in 2...PaneLayoutState.maximumSessionLeafCount {
            try state.insertSession("s\(index)", beside: "s1", at: .right)
        }
        XCTAssertEqual(state.groups[0].root.sessionLeaves.count, PaneLayoutState.maximumSessionLeafCount)
        XCTAssertThrowsError(try state.insertSession("s99", beside: "s1", at: .right))
        _ = try state.insertMarkdownPreview(path: "/r/more.md", beside: "s1", at: .right)
    }

    func testDetachingTheLastSessionDissolvesTheGroupWithItsPreviews() throws {
        var state = PaneLayoutState(groups: [])
        let location = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let sessionPane = try XCTUnwrap(state.location(ofSession: "s1"))
        let change = try state.detachPane(sessionPane.paneID)
        XCTAssertTrue(change.dissolved)
        XCTAssertTrue(state.groups.isEmpty)
        XCTAssertNil(state.location(ofPane: location.paneID))
    }

    func testDetachingAPreviewKeepsASessionPlusPreviewGroupOtherwiseDissolves() throws {
        var state = PaneLayoutState(groups: [])
        let first = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let second = try state.insertMarkdownPreview(path: "/r/b.md", beside: "s1", at: .right)
        XCTAssertFalse(try state.detachPane(second.paneID).dissolved)
        XCTAssertEqual(state.groups.count, 1)
        XCTAssertTrue(try state.detachPane(first.paneID).dissolved)
        XCTAssertTrue(state.groups.isEmpty)
    }

    func testReconcileDropsPreviewsWhenTheirGroupLosesItsSessions() throws {
        var state = PaneLayoutState(groups: [])
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let changes = state.reconcile(eligibleSessionIDs: [])
        XCTAssertEqual(changes.map(\.dissolved), [true])
        XCTAssertTrue(state.groups.isEmpty)

        var kept = PaneLayoutState(groups: [])
        _ = try kept.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        XCTAssertTrue(kept.reconcile(eligibleSessionIDs: ["s1"]).isEmpty)
        XCTAssertEqual(kept.groups.count, 1)
    }

    func testDurableLayoutStripsPreviewLeaves() throws {
        var state = twoPaneState()
        _ = try state.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        let durable = try XCTUnwrap(DurablePaneGroup(group: state.groups[0]))
        XCTAssertEqual(durable.root.paneNode().leaves.map(\.content), [.session(id: "s1"), .session(id: "s2")])

        var solo = PaneLayoutState(groups: [])
        _ = try solo.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right)
        XCTAssertNil(DurablePaneGroup(group: solo.groups[0]))
    }

    func testStructuralIdentityDistinguishesPreviewPaths() throws {
        var a = PaneLayoutState(groups: [])
        _ = try a.insertMarkdownPreview(path: previewPath, beside: "s1", at: .right, newGroupID: groupID, newRepresentativePaneID: paneA, newPaneID: paneB)
        var b = PaneLayoutState(groups: [])
        _ = try b.insertMarkdownPreview(path: "/r/b.md", beside: "s1", at: .right, newGroupID: groupID, newRepresentativePaneID: paneA, newPaneID: paneB)
        XCTAssertNotEqual(a.groups[0].root.structuralIdentity, b.groups[0].root.structuralIdentity)
    }

    func testCanonicalizeDedupesPreviewPathsAndKeepsSessionPlusPreview() {
        let state = PaneLayoutState(groups: [
            PaneGroup(
                id: groupID,
                representativePaneID: paneA,
                root: .split(PaneSplit(
                    direction: .horizontal, ratio: 0.5,
                    left: .leaf(Pane(id: paneA, content: .session(id: "s1"))),
                    right: .split(PaneSplit(
                        direction: .horizontal, ratio: 0.5,
                        left: .leaf(Pane(id: paneB, content: .markdownPreview(path: previewPath))),
                        right: .leaf(Pane(id: paneC, content: .markdownPreview(path: previewPath)))
                    ))
                ))
            ),
        ])
        XCTAssertEqual(state.groups.count, 1)
        XCTAssertEqual(state.groups[0].root.leaves.map(\.id), [paneA, paneB])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PaneLayoutStateTests 2>&1 | tail -6`
Expected: compile errors — `markdownPreview` is not a member, `insertMarkdownPreview` and `location(ofMarkdownPreview:inGroupContaining:)` not found.

- [ ] **Step 3: Extend `PaneContent` and `PaneNode`**

Replace the `PaneContent` enum (:9-22) with:

```swift
enum PaneContent: Equatable, Sendable {
    case session(id: String)
    case launcher(projectID: String)
    // Fork-only: markdown preview pane. A rendered, read-only view of one
    // file; transient like the launcher (never persisted, never counted as
    // a session leaf).
    case markdownPreview(path: String)

    var sessionID: String? {
        guard case let .session(id) = self else { return nil }
        return id
    }

    var isLauncher: Bool {
        if case .launcher = self { return true }
        return false
    }

    // Fork-only: markdown preview pane
    var markdownPreviewPath: String? {
        guard case let .markdownPreview(path) = self else { return nil }
        return path
    }

    /// Leaves that keep a lone session grouped but never persist.
    var isTransient: Bool {
        switch self {
        case .session: return false
        case .launcher, .markdownPreview: return true
        }
    }
}
```

After `containsLauncher` (:125-127) add:

```swift
    // Fork-only: markdown preview pane
    var containsTransientLeaf: Bool {
        leaves.contains { $0.content.isTransient }
    }
```

In `hashStructure` (:271-276) add the case:

```swift
            case let .markdownPreview(path):
                hasher.combine("preview:\(path)")
```

- [ ] **Step 4: Grouping rule — four sites**

Each site currently reads `sessionLeaves.count >= 2 || (sessionLeaves.count == 1 && <hasLauncher/containsLauncher>)`. Change the launcher term to the transient one, keeping everything else:

- `detachPane` (:770-771): `|| (sessionLeaves.count == 1 && newRoot.containsTransientLeaf)` with a `// Fork-only: markdown preview pane` line above.
- `reconcile(eligibleSessionIDs:)` (:922-925): add `let hasTransient = newRoot?.containsTransientLeaf ?? false` next to `hasLauncher` and use `hasTransient` in `canRemainGrouped` (keep `hasLauncher` for the snapshot logic below it).
- `canonicalize` (:1032-1034): use `root.containsTransientLeaf` in `canRemainGrouped`.
- `canonicalize` leaf filter switch (:1001-1009): add
  ```swift
                    // Fork-only: markdown preview pane — one leaf per path.
                    case let .markdownPreview(path):
                        keep = !path.isEmpty && !candidatePreviewPaths.contains(path)
                        if keep { candidatePreviewPaths.insert(path) }
  ```
  with `var candidatePreviewPaths = Set<String>()` declared beside `var hasLauncher = false`.

`DurablePaneGroup.init?` (:1177-1179): strip every transient leaf: change `where pane.content.isLauncher` to `where pane.content.isTransient` (comment: `// Fork-only: markdown preview pane — previews are transient too`).

`validateCapacity` is unchanged: previews are not session leaves and not launchers, so they never count.

- [ ] **Step 5: Insertion and lookup**

Refactor `insertSession(_:splitting:edge:newPaneID:)` (:583-611) so the leaf-splitting body is shared. Replace it with:

```swift
    @discardableResult
    mutating func insertSession(
        _ sessionID: String,
        splitting targetPaneID: String,
        edge: PaneEdge,
        newPaneID: String? = nil
    ) throws -> PaneLocation {
        try validateNewSession(sessionID)
        return try insertLeaf(.session(id: sessionID), splitting: targetPaneID, edge: edge, newPaneID: newPaneID, checkCapacity: true)
    }

    /// Splits `targetPaneID`'s leaf with a new leaf of `content`. Session
    /// leaves check the cap; transient leaves (Fork-only: markdown preview
    /// pane) do not, because they never count as sessions.
    private mutating func insertLeaf(
        _ content: PaneContent,
        splitting targetPaneID: String,
        edge: PaneEdge,
        newPaneID: String?,
        checkCapacity: Bool
    ) throws -> PaneLocation {
        guard let location = location(ofPane: targetPaneID) else {
            throw PaneLayoutError.paneNotFound(targetPaneID)
        }
        let groupIndex = try index(ofGroup: location.groupID)
        if checkCapacity {
            try validateCapacity(ofGroupAt: groupIndex)
        }

        let pane = Pane(id: newPaneID ?? PaneStableID.make(), content: content)
        guard let root = groups[groupIndex].root.splittingLeaf(
            targetPaneID, adding: pane, edge: edge
        ) else {
            throw PaneLayoutError.paneNotFound(targetPaneID)
        }
        // Adding a real Session while a launcher is open is an intentional
        // layout mutation; its geometry becomes the new basis.
        groups[groupIndex].preLauncherRoot = nil
        groups[groupIndex].root = root
        return PaneLocation(groupID: groups[groupIndex].id, paneID: pane.id)
    }
```

After `insertLauncher(projectID:beside:at:…)` (ends ~:719) add:

```swift
    // MARK: Fork-only: markdown preview pane

    /// Splits the target session's leaf, or creates a session + preview
    /// group when that session is currently solo. Same shape as the
    /// launcher's `beside:` insertion; previews never count toward the cap.
    @discardableResult
    mutating func insertMarkdownPreview(
        path: String,
        beside targetSessionID: String,
        at edge: PaneEdge,
        newGroupID: String? = nil,
        newRepresentativePaneID: String? = nil,
        newPaneID: String? = nil
    ) throws -> PaneLocation {
        guard !targetSessionID.isEmpty else {
            throw PaneLayoutError.invalidSessionID
        }
        if let target = location(ofSession: targetSessionID) {
            return try insertLeaf(
                .markdownPreview(path: path),
                splitting: target.paneID,
                edge: edge,
                newPaneID: newPaneID,
                checkCapacity: false
            )
        }
        let representative = Pane(
            id: newRepresentativePaneID ?? PaneStableID.make(),
            content: .session(id: targetSessionID)
        )
        let preview = Pane(
            id: newPaneID ?? PaneStableID.make(),
            content: .markdownPreview(path: path)
        )
        let split = PaneSplit(
            direction: edge.splitDirection,
            ratio: 0.5,
            left: edge.newLeafIsLeftChild ? .leaf(preview) : .leaf(representative),
            right: edge.newLeafIsLeftChild ? .leaf(representative) : .leaf(preview)
        )
        let group = PaneGroup(
            id: newGroupID ?? PaneStableID.make(),
            representativePaneID: representative.id,
            root: .split(split)
        )
        groups.append(group)
        return PaneLocation(groupID: group.id, paneID: preview.id)
    }

    func location(ofMarkdownPreview path: String, inGroupContaining sessionID: String) -> PaneLocation? {
        guard let group = group(containingSession: sessionID),
              let pane = group.root.leaves.first(where: { $0.content.markdownPreviewPath == path })
        else { return nil }
        return PaneLocation(groupID: group.id, paneID: pane.id)
    }
```

(`group(containingSession:)` exists — it is what `validatedPaneGroup` calls.)

- [ ] **Step 6: Fix the exhaustive switches the compiler reports**

Build: `swift build 2>&1 | grep -E "error" | head`. Expected errors are the remaining exhaustive switches: `PresentedPane.id` (TerminalPaneView.swift:732), `paneSlot` (:1058), `UnpeelStore.validatedPaneGroup` (:12232). Add **temporary** minimal arms so the package compiles — Task 5 replaces them:
- `PresentedPane.id`: `case .markdownPreview: return "preview:\(paneID)"` (this one is final).
- `paneSlot`: `case .markdownPreview: unavailablePane(pane)` (temporary).
- `validatedPaneGroup`: `case let .markdownPreview(path): if !FileManager.default.fileExists(atPath: path) { root = root?.removingLeaf(pane.id) }` and change the `guard sessionLeaves.count >= 2 || (sessionLeaves.count == 1 && root.containsLauncher)` to use `root.containsTransientLeaf` (both final). Mark each with `// Fork-only: markdown preview pane`.

- [ ] **Step 7: Run the layout tests, then the conformance and full gate**

Run: `swift test --filter "PaneLayoutStateTests|PaneLayoutOperationsConformanceTests|PaneLayoutControllerTests" 2>&1 | tail -4`
Expected: 0 failures (the conformance fixture never contains preview leaves, so it is unaffected).
Then from the repo root: `clients/native/test-native.sh 2>&1 | tail -3` → `0 failures`.

- [ ] **Step 8: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelNative/PaneLayoutState.swift \
        clients/native/UnpeelNative/Sources/UnpeelNative/UnpeelStore.swift \
        clients/native/UnpeelNative/Sources/UnpeelNative/Views/TerminalPaneView.swift \
        clients/native/UnpeelNative/Tests/UnpeelNativeTests/PaneLayoutStateTests.swift
git commit -m "feat(panes): transient markdownPreview leaf in the pane model

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Store entry point and pane rendering

**Files:**
- Modify: `Sources/UnpeelNative/UnpeelStore.swift` (near `openPaneLauncher` :11927; `validatedPaneGroup` already extended in Task 4)
- Modify: `Sources/UnpeelNative/Views/TerminalPaneView.swift` (`paneSlot` :1058; after `launcherPane` :1338; `paneMenu` launcher branch :~1829)
- Test: `Tests/UnpeelNativeTests/TerminalPaneClosePolicyTests.swift` (append one test)

**Interfaces:**
- Consumes: `PaneLayoutState.insertMarkdownPreview`, `location(ofMarkdownPreview:inGroupContaining:)`, `MarkdownPreviewPaneView`, `UnpeelStore.openClickedFile`, `paneHeader`, `paneCardChrome`, `frameBackground`, `activatePane`, `detachPane`.
- Produces: `UnpeelStore.openMarkdownPreview(path: String, besideSession sessionID: String)`, `UnpeelStore.markdownPreviewProjectRoot(for sessionID: String) -> String?`.

- [ ] **Step 1: Write the failing close-policy test** (append to `TerminalPaneClosePolicyTests`)

```swift
    // Fork-only: markdown preview pane — ⌘W on a preview only detaches it.
    func testMarkdownPreviewCloseDetachesThePane() {
        XCTAssertEqual(
            terminalPaneCloseAction(for: .markdownPreview(path: "/r/a.md"), canArchiveSession: true),
            .detachPane
        )
    }
```

Run: `swift test --filter TerminalPaneClosePolicyTests 2>&1 | tail -3` → it passes already (the guard on `sessionID` covers it); keep it as the regression guard and move on.

- [ ] **Step 2: Store entry point**

In `UnpeelStore.swift`, directly above `func openPaneLauncher(` (:11927) add:

```swift
    // MARK: Fork-only: markdown preview pane

    /// Shows `path` rendered beside `sessionID`'s pane: the group's existing
    /// preview for that path is focused, otherwise a new leaf splits the
    /// session's pane to the right (the placement plugin panes use). The
    /// path arrives canonical from the explorer's own scan.
    func openMarkdownPreview(path: String, besideSession sessionID: String) {
        guard selectedHostScope == .local,
              !path.isEmpty,
              displaySessionsByID[sessionID] != nil
        else { return }
        let location = paneLayoutState.location(ofMarkdownPreview: path, inGroupContaining: sessionID)
            ?? mutatePaneLayout { state in
                try state.insertMarkdownPreview(path: path, beside: sessionID, at: .right)
            }
        guard let location else { return }
        paneLayoutController.setPendingReveal(groupID: location.groupID, paneID: location.paneID)
        setActiveTerminalPane(groupID: location.groupID, paneID: location.paneID, sessionID: nil)
    }

    /// The root the preview may serve resources from: the session's worktree,
    /// else its project folder, else the pane's working directory — the same
    /// precedence as the explorer's tree root.
    func markdownPreviewProjectRoot(for sessionID: String) -> String? {
        guard let session = displaySessionsByID[sessionID] else { return nil }
        if let worktree = session.worktreePath, !worktree.isEmpty { return worktree }
        if let project = displayProjectsByID[session.projectID]?.path, !project.isEmpty { return project }
        return paneWorkingDirectory(for: session)
    }
```

If `mutatePaneLayout`'s closure type does not accept `try` on `insertMarkdownPreview` as written, mirror exactly how `openPaneLauncher` calls it (`mutatePaneLayout({ state -> PaneLocation in ... })`).

- [ ] **Step 3: Render the pane**

In `TerminalPaneView.swift` add `import UnpeelMarkdownPreview` after the existing imports (with `// Fork-only: markdown preview pane`).

Replace the temporary `paneSlot` arm with:

```swift
        // Fork-only: markdown preview pane
        case let .markdownPreview(path):
            markdownPreviewPane(pane, path: path)
```

After `launcherPane` (ends :1338) add:

```swift
    // MARK: Fork-only: markdown preview pane

    /// Rendered, read-only view of one file. Transient like the launcher.
    /// The project root the preview may read from follows the group's
    /// representative session (the tree the file was opened from).
    private func markdownPreviewPane(
        _ pane: PresentedPane,
        path: String
    ) -> some View {
        let background = frameBackground(representative)
        let fileName = (path as NSString).lastPathComponent
        let projectRoot = store.markdownPreviewProjectRoot(for: representative.id)
            ?? (path as NSString).deletingLastPathComponent
        return VStack(spacing: 0) {
            paneHeader(
                pane: pane,
                entry: nil,
                title: fileName,
                background: background
            )
            ZStack {
                Color(nsColor: background)
                    .opacity(transparency.surfaceOpacity)
                MarkdownPreviewPaneView(
                    path: path,
                    projectRoot: projectRoot,
                    onEdit: {
                        store.openClickedFile(
                            ClickablePath.Match(path: path, line: nil, column: nil),
                            path: path,
                            fromSessionID: representative.id
                        )
                    },
                    onActivate: { activatePane(pane.paneID) },
                    onEscape: {
                        if let sessionPane = group?.root.sessionLeaves.first(where: { $0.content.sessionID == representative.id }) {
                            activatePane(sessionPane.id)
                        }
                    },
                    onOpenMarkdown: { target in
                        store.openMarkdownPreview(path: target, besideSession: representative.id)
                    }
                )
            }
            .frame(maxHeight: .infinity)
        }
        .modifier(paneCardChrome(background: background, paneID: pane.paneID))
        .transition(.identity)
    }
```

In `paneMenu`, before the `if let group {` block (:~1872), add a branch for previews so the menu has an editor verb:

```swift
        // Fork-only: markdown preview pane
        if case let .markdownPreview(path) = pane.content {
            menu.addItem(controller.item("Open in Markdown Editor") {
                store.openClickedFile(
                    ClickablePath.Match(path: path, line: nil, column: nil),
                    path: path,
                    fromSessionID: representative.id
                )
            })
        }
```

Note the launcher branch is `} else if case .launcher = pane.content {` — add the preview block as a separate `if` after that chain, not as another `else if`, so a single edit block suffices.

- [ ] **Step 4: Build and run the gate**

Run: `swift build 2>&1 | grep -E "error|warning: .*(TerminalPaneView|UnpeelStore).*[Pp]review" | head` → none. Then `clients/native/test-native.sh 2>&1 | tail -3` from the repo root → 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelNative/UnpeelStore.swift \
        clients/native/UnpeelNative/Sources/UnpeelNative/Views/TerminalPaneView.swift \
        clients/native/UnpeelNative/Tests/UnpeelNativeTests/TerminalPaneClosePolicyTests.swift
git commit -m "feat(panes): open and render markdown preview panes beside a session

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Explorer routing and menu

**Files:**
- Create: `Sources/UnpeelExplorer/MarkdownFileTypes.swift`
- Modify: `Sources/UnpeelExplorer/ExplorerPalette.swift` (protocol), `Sources/UnpeelExplorer/ExplorerOutlineController.swift` (`MenuAction`, `menuActions(forTargets:)`, `perform`)
- Modify: `Sources/UnpeelNative/Views/ExplorerPanelHost.swift` (`ExplorerHostActions`)
- Test: `Tests/UnpeelExplorerTests/ExplorerOutlineControllerTests.swift`, `Tests/UnpeelExplorerTests/MarkdownFileTypesTests.swift`

**Interfaces:**
- Consumes: `UnpeelStore.openMarkdownPreview(path:besideSession:)`, `ExplorerHostActions.rootSessionID`, `openRoute(sessionID:)`.
- Produces: `ExplorerActionHandler.openMarkdownEditor(path:)`, `MenuAction.openInMarkdownEditor`, `MarkdownFileTypes.isMarkdown(_:)` (explorer copy).

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelExplorerTests/MarkdownFileTypesTests.swift`:

```swift
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
```

In `ExplorerOutlineControllerTests.swift`: add `var editedInMarkdown: [String] = []` and `func openMarkdownEditor(path: String) { editedInMarkdown.append(path) }` to `RecordingHandler`; extend `sampleModel` root listing with `FileEntry(path: "/r/README.md", name: "README.md", kind: .file)` inserted before `a.txt` (update `testChildrenFollowTheFilter`'s expectations to include `"/r/README.md"` after `"/r/src"` and before `"/r/a.txt"` — directories first, then files in the listing's order), then add:

```swift
    func testMenuOffersMarkdownEditorOnlyForMarkdownOnlyFileTargets() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.actionHandler = RecordingHandler()
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(
            Array(controller.menuActions(for: "/r/README.md").prefix(6)),
            [.open, .openInMarkdownEditor, .openInEditor, .revealInFinder, .quickLook, nil]
        )
        XCTAssertEqual(
            Array(controller.menuActions(for: "/r/a.txt").prefix(5)),
            [.open, .openInEditor, .revealInFinder, .quickLook, nil]
        )
        XCTAssertFalse(controller.menuActions(forTargets: ["/r/README.md", "/r/a.txt"]).contains(.openInMarkdownEditor))
        XCTAssertFalse(controller.menuActions(forTargets: ["/r/README.md", "/r/src"]).contains(.openInMarkdownEditor))
    }

    func testPerformOpenInMarkdownEditorOnlyForwardsMarkdownFiles() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.perform(.openInMarkdownEditor, on: ["/r/README.md", "/r/a.txt", "/r/src"])
        XCTAssertEqual(handler.editedInMarkdown, ["/r/README.md"])
        XCTAssertEqual(handler.openedWithRules, [])
        XCTAssertEqual(handler.opened, [])
        XCTAssertEqual(ExplorerOutlineController.MenuAction.openInMarkdownEditor.title, "Open in Markdown Editor")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "MarkdownFileTypesTests|ExplorerOutlineControllerTests" 2>&1 | tail -6`
Expected: compile errors (`MarkdownFileTypes`, `.openInMarkdownEditor`, protocol conformance of `RecordingHandler` fails only after Step 3).

- [ ] **Step 3: Library changes**

`Sources/UnpeelExplorer/MarkdownFileTypes.swift`:

```swift
import Foundation

/// Mirror of the plugin registry's markdown extensions
/// (`protocol/app-registry.json`). `UnpeelMarkdownPreview` keeps its own
/// copy; the two targets do not depend on each other.
public enum MarkdownFileTypes {
    public static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public static func isMarkdown(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
```

`ExplorerPalette.swift` protocol: add after `openFile`:

```swift
    /// Always the Markdown plugin pane (Unpeel's editor for `.md`), for the
    /// context-menu item shown on markdown files.
    func openMarkdownEditor(path: String)
```

`ExplorerOutlineController.swift`:
- `MenuAction`: add `openInMarkdownEditor` after `open` in the case list, title `"Open in Markdown Editor"`.
- `menuActions(forTargets:)`: every target must be a markdown file for the editor item to appear — a directory or a non-markdown file in the set hides it:
  ```swift
        // Fork-only: markdown preview pane — the plugin verb only when EVERY
        // target is a markdown file (a directory or other file hides it).
        let markdownOnly = resolved.allSatisfy {
            $0.entry.kind == .file && MarkdownFileTypes.isMarkdown($0.path)
        }
        var actions: [MenuAction?] = hasFile
            ? (markdownOnly
                ? [.open, .openInMarkdownEditor, .openInEditor, .revealInFinder, .quickLook, nil]
                : [.open, .openInEditor, .revealInFinder, .quickLook, nil])
            : [.revealInFinder, nil]
  ```
  (`resolved` is non-empty here because of the guard above it.)
- `perform`: add `case .openInMarkdownEditor: filesOnly(paths).filter(MarkdownFileTypes.isMarkdown).forEach { actionHandler?.openMarkdownEditor(path: $0) }`.

- [ ] **Step 4: App wiring**

In `ExplorerPanelHost.swift`, replace `openFile` and add `openMarkdownEditor`:

```swift
    /// Markdown opens as a rendered preview pane beside the tree's session
    /// (Fork-only: markdown preview pane); everything else goes through the
    /// open-with rules, exactly the routine behind a terminal ⌘-click.
    func openFile(path: String) {
        if MarkdownFileTypes.isMarkdown(path), let store, let sessionID = rootSessionID {
            store.openMarkdownPreview(path: path, besideSession: sessionID)
            return
        }
        openMarkdownEditor(path: path)
    }

    /// The open-with rules: registry match by extension (`.md` → Markdown
    /// plugin), Settings ▸ Open With override, else the editor; the plugin
    /// pane attaches to the TREE's session (`rootSessionID`). `openClickedFile`
    /// returns `false` when the file no longer resolves locally (the watcher
    /// removes the row moments later) or, in remote scope — where this panel
    /// shows no tree anyway — when no plugin claims the type; either way
    /// there is nothing more to do than note it.
    func openMarkdownEditor(path: String) {
        guard let store else {
            openInEditor(path: path)
            return
        }
        switch ExplorerContextResolver.openRoute(sessionID: rootSessionID) {
        case .editor:
            openInEditor(path: path)
        case let .rules(sessionID):
            let match = ClickablePath.Match(path: path, line: nil, column: nil)
            if !store.openClickedFile(match, path: path, fromSessionID: sessionID) {
                Self.logger.info("open declined for \(path, privacy: .private)")
            }
        }
    }
```

(The body of the old `openFile` moves into `openMarkdownEditor` unchanged; `openFile` now delegates to it for non-markdown files.) Add to `ExplorerContextResolverTests.testHostActionsWithoutAStoreAreNoOps` a call `actions.openMarkdownEditor(path: "/tmp/README.md")`.

- [ ] **Step 5: Run the explorer suites and the full gate**

Run: `swift test --filter "UnpeelExplorerTests|ExplorerContextResolverTests" 2>&1 | tail -4` → 0 failures. Then `clients/native/test-native.sh 2>&1 | tail -3` → 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer clients/native/UnpeelNative/Tests/UnpeelExplorerTests \
        clients/native/UnpeelNative/Sources/UnpeelNative/Views/ExplorerPanelHost.swift \
        clients/native/UnpeelNative/Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift
git commit -m "feat(explorer): open markdown as a preview pane, plugin via Open in Markdown Editor

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Docs, spec amendments and runtime verification (controller runs this)

**Files:**
- Modify: `docs/agents/clients/panes.md` (a paragraph under the pane content model), `docs/superpowers/specs/2026-09-21-native-file-explorer-design.md` (§3.3 touchpoints list + the "pane-layout contract" non-goal), `docs/superpowers/specs/2026-09-22-explorer-open-with-rules-design.md` (note: markdown now previews), `docs/superpowers/verification/2026-09-22-markdown-preview-pane.md` (new)

- [ ] **Step 1: Docs**

`panes.md`: after the sentence introducing `.launcher(projectID:)`, add a paragraph: "Fork-only: `.markdownPreview(path:)` is a second transient leaf — a rendered, read-only Markdown view opened from the file explorer beside a session. Like the launcher it is stripped before persistence, never counts as a session leaf, and keeps a lone session grouped; a group that loses its last session leaf drops its previews. The durable schema and `protocol/pane-layout-operations-v1.json` are unchanged."

Explorer spec §3.3: add the three layout files, `Package.swift`'s new target, `panes.md`; amend the non-goal to "no change to the *persisted* pane-layout contract". Open-with spec: add a line under Behaviour: "Since 2026-09-22 (preview pane spec) markdown files open in the native preview pane; the plugin is reached through Open in Markdown Editor or the preview's Edit button."

- [ ] **Step 2: Runtime checklist** (dev build, `UNPEEL_HOME=~/unpeel-dev-explorer-home`, Markdown plugin linked; quit the running "Unpeel Dev" first — `dev-blank.sh` only execs)

| # | Check | Expected |
|---|---|---|
| 1 | Double-click `README.md` | Preview pane right of the session pane, rendered headings/list, title chip = file name |
| 2 | Double-click `README.md` again | Existing preview focused, no new pane |
| 3 | Double-click `notes.md` | Second preview pane |
| 4 | Edit button | Markdown plugin pane opens; type in it → preview updates within ~1 s, scroll kept |
| 5 | ⌘W with the preview focused | Only the preview closes |
| 6 | Close the session pane (⌘W on it → archive/remove) | Its previews disappear |
| 7 | `rm notes.md` while previewed | Pane shows "notes.md is no longer available" then drops |
| 8 | `![](img/a.png)` inside the root | Image renders |
| 9 | `![](../outside.png)` / absolute path outside root | Broken image, nothing served (log line) |
| 10 | Click an `http` link | Default browser opens, preview unchanged |
| 11 | Click a relative `other.md` link | New preview pane for it |
| 12 | Toggle system appearance | Preview re-styles light/dark |
| 13 | Drag the divider | No flicker/blank frames |
| 14 | Quit and relaunch | Previews gone; session layout intact |
| 15 | Context menu on `README.md` | Open, Open in Markdown Editor, Open in Editor, Reveal in Finder, Quick Look, … |

- [ ] **Step 3: Record and commit**

Write the verification doc with results and screenshots under `docs/superpowers/verification/markdown-preview-pane/`; set the spec Status to "implemented".

```bash
git add docs
git commit -m "docs: markdown preview pane — docs, spec amendments and verification

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
