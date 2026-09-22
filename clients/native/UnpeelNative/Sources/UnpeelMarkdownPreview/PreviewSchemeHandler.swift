import Foundation
import WebKit
import os

/// Serves `unpeel-preview://local/<path>`: markdown files as rendered pages,
/// images raw, everything the policy refuses as an empty 404. Runs on the
/// main thread (WebKit calls scheme handlers there); nothing larger than
/// `MarkdownPreviewDocument.maximumBytes` is ever read, for any served type.
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
            // Fork-only: markdown preview pane — M5: a refused sub-resource
            // (an image, say) stays a silent 404, but a refused markdown
            // document is what the pane itself is showing — tell the user
            // why instead of leaving a blank card.
            if MarkdownFileTypes.isMarkdown(path) {
                let name = (path as NSString).lastPathComponent
                let html = MarkdownPreviewDocument.unavailablePage(
                    title: name,
                    message: "\(name) cannot be previewed: it is outside the project or not a regular file."
                )
                respond(task, url: url, status: 200, mimeType: "text/html", data: Data(html.utf8))
            } else {
                respond(task, url: url, status: 404, mimeType: "text/plain", data: Data())
            }
        case let .serve(resolved, mime):
            let name = (resolved as NSString).lastPathComponent
            // Fail closed: no readable size means no read at all.
            guard let size = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.size] as? NSNumber else {
                respond(task, url: url, status: 404, mimeType: "text/plain", data: Data())
                return
            }
            if size.int64Value > Int64(MarkdownPreviewDocument.maximumBytes) {
                if mime == "text/markdown" {
                    let html = MarkdownPreviewDocument.unavailablePage(
                        title: name, message: "\(name) is too large to preview (over 4 MB). Open it in the editor instead."
                    )
                    respond(task, url: url, status: 200, mimeType: "text/html", data: Data(html.utf8))
                } else {
                    respond(task, url: url, status: 404, mimeType: "text/plain", data: Data())
                }
                return
            }
            guard let data = FileManager.default.contents(atPath: resolved) else {
                respond(task, url: url, status: 404, mimeType: "text/plain", data: Data())
                return
            }
            if mime == "text/markdown" {
                let html = MarkdownPreviewDocument.page(
                    bodyHTML: MarkdownHTMLRenderer.html(from: String(decoding: data, as: UTF8.self)),
                    title: name
                )
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
