import XCTest
@testable import UnpeelMarkdownPreview

final class PreviewResourcePolicyTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private var sibling: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-policy-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        sibling = base.appendingPathComponent("root2")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("# hi".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("img/a.png"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("s.md"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("secret".utf8).write(to: sibling.appendingPathComponent("s.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.md"),
            withDestinationURL: outside.appendingPathComponent("s.md")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func policy() -> PreviewResourcePolicy {
        PreviewResourcePolicy(projectRoot: root.path)
    }

    func testServesMarkdownAndImagesInsideTheRoot() {
        XCTAssertEqual(
            policy().decide(requestPath: root.appendingPathComponent("README.md").path),
            .serve(path: PreviewCanonicalPath.resolve(root.appendingPathComponent("README.md").path)!, mimeType: "text/markdown")
        )
        XCTAssertEqual(
            policy().decide(requestPath: root.appendingPathComponent("img/a.png").path),
            .serve(path: PreviewCanonicalPath.resolve(root.appendingPathComponent("img/a.png").path)!, mimeType: "image/png")
        )
    }

    func testRefusesOutsideTraversalSymlinkEscapeDirectoriesAndOtherTypes() {
        XCTAssertEqual(policy().decide(requestPath: outside.appendingPathComponent("s.md").path), .refuse("outside project root"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("../outside/s.md").path), .refuse("outside project root"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("escape.md").path), .refuse("outside project root"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("img").path), .refuse("not a regular file"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("notes.txt").path), .refuse("type not allowed"))
        XCTAssertEqual(policy().decide(requestPath: root.appendingPathComponent("missing.md").path), .refuse("unresolvable path"))
        XCTAssertEqual(policy().decide(requestPath: sibling.appendingPathComponent("s.md").path), .refuse("outside project root"))
    }

    // Fork-only: markdown preview pane — I2: confines in-page link targets.
    func testDocumentPathIsTheCanonicalPathForAMarkdownFileInsideTheRoot() {
        XCTAssertEqual(
            policy().documentPath(for: root.appendingPathComponent("README.md").path),
            PreviewCanonicalPath.resolve(root.appendingPathComponent("README.md").path)
        )
    }

    func testDocumentPathIsNilOutsideTheRootOrForANonMarkdownOrDirectoryTarget() {
        XCTAssertNil(policy().documentPath(for: outside.appendingPathComponent("s.md").path))
        XCTAssertNil(policy().documentPath(for: root.appendingPathComponent("escape.md").path))
        XCTAssertNil(policy().documentPath(for: root.appendingPathComponent("img/a.png").path))
        XCTAssertNil(policy().documentPath(for: root.appendingPathComponent("img").path))
    }
}
