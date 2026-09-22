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
