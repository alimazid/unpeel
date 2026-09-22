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
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url!
    }

    public static func path(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        return url.path
    }

    /// `https:` images are allowed deliberately (README badges commonly load
    /// from a badge service), matching VS Code's own preview; `http:` is not,
    /// so a plaintext beacon can't run. Everything else is `'none'`: no
    /// script runs in the page (the activate/Escape listeners are injected
    /// as a `WKUserScript` instead, which is not subject to the page CSP),
    /// no fetches, no forms, no framing.
    public static func page(bodyHTML: String, title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src unpeel-preview: https: data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; object-src 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTMLEscaping.escape(title))</title>
        <style>\(stylesheet)</style>
        </head><body>
        <article class="markdown-body">\(bodyHTML)</article>
        </body></html>
        """
    }

    public static func unavailablePage(title: String, message: String) -> String {
        page(bodyHTML: "<p class=\"notice\">\(HTMLEscaping.escape(message))</p>", title: title)
    }

    /// Reports mouse-down (so the pane can become active) and Escape;
    /// nothing else runs in the page. Injected by the web view as a
    /// `WKUserScript` rather than an inline `<script>` tag, since the page's
    /// `script-src 'none'` CSP would otherwise block it.
    public static let userScript = """
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
