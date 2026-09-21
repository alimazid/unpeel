import AppKit
import UniformTypeIdentifiers

/// System file-type icons, cached per extension: asking `NSWorkspace` per row
/// is too slow for a 10,000-row folder.
@MainActor
public final class FileIconProvider {
    private static let folderKey = "\u{0}folder"
    /// Files with no extension (`Makefile`, `LICENSE`, `Dockerfile`, …) all
    /// share one generic-document icon under this one sentinel key, rather
    /// than each computing its own key from an empty `pathExtension` — that
    /// would still work by accident (empty string keys aren't ambiguous
    /// with each other), but a named bucket makes the "no extension" case
    /// deliberate instead of incidental.
    private static let noExtensionKey = "\u{0}no-extension"
    private var cache: [String: NSImage] = [:]

    public init() {}

    public func icon(for entry: FileEntry) -> NSImage {
        let key = Self.cacheKey(for: entry)
        if let cached = cache[key] { return cached }
        let image = (NSWorkspace.shared.icon(for: Self.type(for: entry)).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        cache[key] = image
        return image
    }

    static func cacheKey(for entry: FileEntry) -> String {
        guard entry.kind != .directory else { return folderKey }
        let fileExtension = (entry.name as NSString).pathExtension.lowercased()
        return fileExtension.isEmpty ? noExtensionKey : fileExtension
    }

    private static func type(for entry: FileEntry) -> UTType {
        guard entry.kind != .directory else { return .folder }
        let fileExtension = (entry.name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return .data }
        return UTType(filenameExtension: fileExtension) ?? .data
    }
}
