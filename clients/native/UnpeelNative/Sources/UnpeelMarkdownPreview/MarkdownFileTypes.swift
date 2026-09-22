import Foundation

/// Mirror of the plugin registry's markdown extensions
/// (`protocol/app-registry.json`); the explorer keeps its own copy.
enum MarkdownFileTypes {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    static func isMarkdown(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
