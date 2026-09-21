import Foundation
@testable import UnpeelExplorer

/// A throwaway directory under the system temp dir, addressed by its
/// realpath so it compares equal to what FSEvents and the loader report.
struct TempTree {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("unpeel-explorer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let real = CanonicalPath.resolve(base.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        root = real
    }

    func path(_ relative: String) -> String {
        (root as NSString).appendingPathComponent(relative)
    }

    @discardableResult
    func file(_ relative: String, _ contents: String = "") throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.write(toFile: target, atomically: true, encoding: .utf8)
        return target
    }

    @discardableResult
    func dir(_ relative: String) throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        return target
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
        try? FileManager.default.removeItem(atPath: root)
    }
}
