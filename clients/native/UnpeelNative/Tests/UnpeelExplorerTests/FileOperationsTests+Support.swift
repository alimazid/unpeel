import Foundation
import XCTest
@testable import UnpeelExplorer

/// A Trash that is a plain folder outside the tree, so tests never fill the
/// user's real Trash. Items keep their name; a clash gets a numbered name,
/// as the Finder's Trash does.
struct FolderTrash: Trasher {
    let folder: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("unpeel-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        folder = try XCTUnwrap(CanonicalPath.resolve(base.path))
    }

    func trash(_ path: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        var target = (folder as NSString).appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: target) {
            target = (folder as NSString).appendingPathComponent("\(name) \(counter)")
            counter += 1
        }
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }

    var contents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder).sorted()) ?? []
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: folder)
    }
}

/// A Trash that always fails, like a volume without one.
struct NoTrash: Trasher {
    func trash(_ path: String) throws -> String {
        throw CocoaError(.featureUnsupported, userInfo: [NSFilePathErrorKey: path])
    }
}

extension TempTree {
    func exists(_ relative: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path(relative), isDirectory: &isDirectory)
    }

    func isDirectory(_ relative: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path(relative), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func contents(_ relative: String) -> String? {
        try? String(contentsOfFile: path(relative), encoding: .utf8)
    }

    func names(_ relative: String = "") -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: relative.isEmpty ? root : path(relative)).sorted()) ?? []
    }

    func linkDestination(_ relative: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path(relative))
    }

    /// A step as a short, identity-free line relative to the tree, so tests
    /// can assert on a record's shape.
    func describe(_ step: FileOperationStep) -> String {
        let relative = { (path: String) in ExplorerPaths.relative(path, to: self.root) }
        switch step {
        case let .created(path, _, onlyIfEmpty):
            return "created \(relative(path))" + (onlyIfEmpty ? " (if empty)" : "")
        case let .moved(from, to, _):
            return "moved \(relative(from)) -> \(relative(to))"
        case let .trashed(original, _, _, _):
            return "trashed \(relative(original))"
        }
    }

    func describe(_ record: FileOperationRecord?) -> [String] {
        record?.steps.map(describe) ?? []
    }
}
