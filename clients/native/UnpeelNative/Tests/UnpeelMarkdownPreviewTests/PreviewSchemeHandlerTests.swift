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

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-handler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Title\n\ntext".utf8).write(to: root.appendingPathComponent("doc.md"))
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("p.png"))
    }

    override func tearDown() async throws {
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

    func testOversizedImageIs404() throws {
        let big = root.appendingPathComponent("big.png")
        try Data(repeating: 0x61, count: 4_194_305).write(to: big)
        let task = run(big.path)
        XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(task.data.count, 0)
        XCTAssertTrue(task.finished)
    }
}
