import AppKit
import UniformTypeIdentifiers

/// System file-type icons, cached per extension: asking `NSWorkspace` per row
/// is too slow for a 10,000-row folder.
@MainActor
public final class FileIconProvider {
    private static let folderKey = "\u{0}folder"
    private var cache: [String: NSImage] = [:]

    public init() {}

    public func icon(for entry: FileEntry) -> NSImage {
        let fileExtension = (entry.name as NSString).pathExtension.lowercased()
        let key = entry.kind == .directory ? Self.folderKey : fileExtension
        if let cached = cache[key] { return cached }
        let type: UTType = entry.kind == .directory
            ? .folder
            : (UTType(filenameExtension: fileExtension) ?? .data)
        let image = (NSWorkspace.shared.icon(for: type).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        cache[key] = image
        return image
    }
}
