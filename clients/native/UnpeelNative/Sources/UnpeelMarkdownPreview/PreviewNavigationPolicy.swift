import Foundation

/// Where a navigation attempt inside the preview web view should go. Pure
/// data so the routing logic is testable without a live `WKNavigationAction`.
public enum PreviewNavigationDecision: Equatable {
    case allow
    case cancel
    case openMarkdown(String)
    case openExternal(URL)
}

/// Decides what a navigation inside the preview should do, given only the
/// destination URL, whether a link was clicked (vs. the initial load, a
/// reload, or a script-driven redirect), and the path of the document
/// currently shown.
public enum PreviewNavigationPolicy {
    /// `currentPath` is the document shown; a same-scheme link to ANOTHER
    /// markdown file opens a preview, a link to the same path (anchors) is
    /// allowed in place, http(s)/mailto clicks go to the system, all else
    /// cancels.
    public static func decide(url: URL, isLinkActivated: Bool, currentPath: String) -> PreviewNavigationDecision {
        // Schemes are case-insensitive (RFC 3986); WebKit normally lowercases
        // them, but a hand-written `UNPEEL-PREVIEW:` link must not fall to
        // the default branch and be cancelled.
        switch url.scheme?.lowercased() {
        case MarkdownPreviewDocument.scheme:
            guard isLinkActivated else { return .allow }
            let target = MarkdownPreviewDocument.path(from: url)
            if let target, target != currentPath, MarkdownFileTypes.isMarkdown(target) {
                return .openMarkdown(target)
            } else if target == currentPath {
                return .allow
            } else {
                return .cancel
            }
        case "http", "https", "mailto":
            return isLinkActivated ? .openExternal(url) : .cancel
        default:
            return .cancel
        }
    }
}
