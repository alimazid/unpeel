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
        // Injected as a user script, not an inline `<script>` tag: user
        // scripts run outside the page's `script-src 'none'` CSP.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: MarkdownPreviewDocument.userScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
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
            switch PreviewNavigationPolicy.decide(
                url: url,
                isLinkActivated: action.navigationType == .linkActivated,
                currentPath: parent.path
            ) {
            case .allow:
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case let .openMarkdown(target):
                parent.onOpenMarkdown(target)
                decisionHandler(.cancel)
            case let .openExternal(url):
                NSWorkspace.shared.open(url)
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
