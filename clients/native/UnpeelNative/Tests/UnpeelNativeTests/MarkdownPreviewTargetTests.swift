import Foundation
import XCTest
@testable import UnpeelNative

/// Fork-only: markdown preview pane — I2/M4: `UnpeelStore.markdownPreviewTarget`
/// confines an in-page link's target to the project root, canonically, before
/// it can reach the pane model.
final class MarkdownPreviewTargetTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-target-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("# hi".utf8).write(to: root.appendingPathComponent("doc.md"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("s.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func canonical(_ url: URL) throws -> String {
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func testPathInsideTheRootResolvesToItsCanonicalPath() throws {
        let doc = root.appendingPathComponent("doc.md")
        XCTAssertEqual(
            UnpeelStore.markdownPreviewTarget(path: doc.path, projectRoot: root.path),
            try canonical(doc)
        )
    }

    func testDotDotTraversalOutOfTheRootIsNil() {
        XCTAssertNil(
            UnpeelStore.markdownPreviewTarget(
                path: root.appendingPathComponent("../outside/s.md").path,
                projectRoot: root.path
            )
        )
    }

    func testSymlinkPointingOutsideTheRootIsNil() throws {
        let link = root.appendingPathComponent("escape.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("s.md"))
        XCTAssertNil(UnpeelStore.markdownPreviewTarget(path: link.path, projectRoot: root.path))
    }

    func testSymlinkedFileResolvingInsideTheRootIsCanonical() throws {
        let real = root.appendingPathComponent("real.md")
        try Data("# real".utf8).write(to: real)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(
            UnpeelStore.markdownPreviewTarget(path: link.path, projectRoot: root.path),
            try canonical(real)
        )
    }

    func testTheRootItselfIsNilBecauseADirectoryIsNotADocument() {
        XCTAssertNil(UnpeelStore.markdownPreviewTarget(path: root.path, projectRoot: root.path))
    }
}
