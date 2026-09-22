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
