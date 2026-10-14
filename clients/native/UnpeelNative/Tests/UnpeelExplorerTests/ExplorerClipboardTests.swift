import AppKit
import XCTest
@testable import UnpeelExplorer

/// Duplicate, Cut, Copy, Paste and the Collision Prompt.
@MainActor
final class ExplorerClipboardTests: ExplorerOperationTestCase {
    private func pasteboardPaths() -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (urls as? [URL])?.map(\.path) ?? []
    }

    func testCopyWritesFileURLsThatPasteCopiesIntoTheTargetFolder() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt", "A"); try tree.dir("dest")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)

        controller.perform(.copy, on: [tree.path("a.txt")])
        XCTAssertEqual(pasteboardPaths(), [tree.path("a.txt")])
        controller.perform(.paste, on: [tree.path("dest")])
        await settle(controller, viewModel)

        XCTAssertEqual(tree.contents("dest/a.txt"), "A")
        XCTAssertEqual(tree.contents("a.txt"), "A")
        XCTAssertEqual(viewModel.selection, [tree.path("dest/a.txt")])
        XCTAssertEqual(viewModel.undoActionTitle, "Undo Paste")
    }

    func testAPastedItemBelowTheVisibleRowsIsScrolledIntoView() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        for index in 0..<40 { try tree.file(String(format: "f%02d.txt", index)) }
        let other = try TempTree(); defer { other.remove() }
        try other.file("zz.txt")
        let (controller, outline, viewModel) = await windowed(tree)
        XCTAssertEqual(outline.visibleRect.minY, 0)
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(fileURLWithPath: other.path("zz.txt"))])

        controller.perform(.paste, on: [])
        await settle(controller, viewModel)

        let row = try XCTUnwrap(controller.items[tree.path("zz.txt")].map { outline.row(forItem: $0) })
        XCTAssertEqual(viewModel.selection, [tree.path("zz.txt")])
        XCTAssertTrue(outline.visibleRect.contains(outline.rect(ofRow: row)), "the pasted row is scrolled into view")
    }

    func testFilesCopiedElsewhereArePastedAsCopies() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let finder = try TempTree(); defer { finder.remove() }
        try finder.file("from-finder.txt", "F")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(fileURLWithPath: finder.path("from-finder.txt"))])

        controller.perform(.paste, on: [])
        await settle(controller, viewModel)

        XCTAssertEqual(tree.contents("from-finder.txt"), "F")
        XCTAssertTrue(finder.exists("from-finder.txt"))
    }

    func testCutThenPasteMovesOnceAndDimsUntilThen() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.dir("dest")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)

        controller.perform(.cut, on: [tree.path("a.txt")])
        XCTAssertTrue(controller.isCut(tree.path("a.txt")))
        controller.perform(.paste, on: [tree.path("dest")])
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names("dest"), ["a.txt"])
        XCTAssertFalse(tree.exists("a.txt"))
        XCTAssertFalse(controller.isCut(tree.path("a.txt")))

        controller.perform(.paste, on: [])
        await settle(controller, viewModel)
        XCTAssertEqual(tree.names(), ["dest"], "a cut is pasted once only")
    }

    func testACutPasteThatMovedNothingStaysCut() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("dest/a.txt")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        controller.collisionPrompt = ScriptedPrompt([CollisionAnswer(.skip)])

        controller.perform(.cut, on: [tree.path("a.txt")])
        controller.perform(.paste, on: [tree.path("dest")])
        await settle(controller, viewModel)

        XCTAssertTrue(controller.isCut(tree.path("a.txt")), "skipped, so still cut")
        XCTAssertEqual(controller.pasteableFiles, [tree.path("a.txt")])
    }

    func testTwoSourcesOfOneNameKeepBoth() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a/x.txt", "A"); try tree.file("b/x.txt", "B"); try tree.dir("dest")
        let prompt = ScriptedPrompt([])
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        controller.collisionPrompt = prompt

        await controller.transfer([tree.path("a/x.txt"), tree.path("b/x.txt")], into: tree.path("dest"),
                                  copying: true, as: .paste).value
        await settle(controller, viewModel)

        XCTAssertEqual(prompt.asked, [])
        XCTAssertEqual(tree.contents("dest/x.txt"), "A")
        XCTAssertEqual(tree.contents("dest/x copy.txt"), "B")
    }

    func testReplaceNeverTrashesWhatTheSamePastePutThere() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a/x.txt", "A"); try tree.file("b/x.txt", "B"); try tree.file("dest/x.txt", "old")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        controller.collisionPrompt = ScriptedPrompt([CollisionAnswer(.replace, appliesToAll: true)])

        await controller.transfer([tree.path("a/x.txt"), tree.path("b/x.txt")], into: tree.path("dest"),
                                  copying: true, as: .paste).value
        await settle(controller, viewModel)

        XCTAssertEqual(tree.contents("dest/x.txt"), "A")
        XCTAssertEqual(tree.contents("dest/x copy.txt"), "B")
        XCTAssertEqual(trash.contents, ["x.txt"], "only the old one")
    }

    func testCopyingSomethingElseClearsTheCut() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)

        controller.perform(.cut, on: [tree.path("a.txt")])
        pasteboard.clearContents()
        pasteboard.setString("elsewhere", forType: .string)

        XCTAssertFalse(controller.isCut(tree.path("a.txt")))
        controller.menuNeedsUpdate(NSMenu())
        XCTAssertNil(controller.cutState, "the dimming goes the next time the tree is used")
    }

    func testPastingACopyIntoItsOwnFolderKeepsBothWithoutAsking() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let prompt = ScriptedPrompt([])
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        controller.collisionPrompt = prompt

        controller.perform(.copy, on: [tree.path("a.txt")])
        controller.perform(.paste, on: [tree.path("a.txt")])
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names(), ["a copy.txt", "a.txt"])
        XCTAssertEqual(prompt.asked, [])
    }

    func testACollisionAsksAndHonoursEachAnswer() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt", "new A"); try tree.file("src/b.txt", "new B"); try tree.file("src/c.txt", "new C")
        try tree.file("dest/a.txt", "old A"); try tree.file("dest/b.txt", "old B"); try tree.file("dest/c.txt", "old C")
        let prompt = ScriptedPrompt([CollisionAnswer(.replace), CollisionAnswer(.keepBoth), CollisionAnswer(.skip)])
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        controller.collisionPrompt = prompt

        await controller.transfer(
            [tree.path("src/a.txt"), tree.path("src/b.txt"), tree.path("src/c.txt")],
            into: tree.path("dest"), copying: true, as: .paste
        ).value
        await settle(controller, viewModel)

        XCTAssertEqual(prompt.asked, ["a.txt (2 more)", "b.txt (1 more)", "c.txt (0 more)"])
        XCTAssertEqual(tree.contents("dest/a.txt"), "new A")
        XCTAssertEqual(tree.contents("dest/b.txt"), "old B")
        XCTAssertEqual(tree.contents("dest/b copy.txt"), "new B")
        XCTAssertEqual(tree.contents("dest/c.txt"), "old C")
        XCTAssertEqual(trash.contents, ["a.txt"])

        await viewModel.undo().value
        XCTAssertEqual(tree.contents("dest/a.txt"), "old A", "undo restores the replaced item")
        XCTAssertFalse(tree.exists("dest/b copy.txt"))
    }

    func testApplyToAllAnswersTheRest() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/a.txt"); try tree.file("src/b.txt"); try tree.file("dest/a.txt"); try tree.file("dest/b.txt")
        let prompt = ScriptedPrompt([CollisionAnswer(.keepBoth, appliesToAll: true)])
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        controller.collisionPrompt = prompt

        await controller.transfer(
            [tree.path("src/a.txt"), tree.path("src/b.txt")], into: tree.path("dest"), copying: false, as: .move
        ).value
        await settle(controller, viewModel)

        XCTAssertEqual(prompt.asked, ["a.txt (1 more)"])
        XCTAssertEqual(tree.names("dest"), ["a copy.txt", "a.txt", "b copy.txt", "b.txt"])
        XCTAssertEqual(tree.names("src"), [])
    }

    func testAFolderPastedIntoItsOwnDescendantIsRefused() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("a/b")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        await viewModel.expand(tree.path("a")).value
        sync(controller, viewModel)

        controller.perform(.copy, on: [tree.path("a")])
        controller.perform(.paste, on: [tree.path("a/b")])
        await settle(controller, viewModel)

        XCTAssertEqual(viewModel.operationMessage, "“a” can’t be moved or copied into itself.")
        XCTAssertEqual(tree.names("a/b"), [])
    }

    func testDuplicateCopiesBesideAndIsOneUndoStep() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.file("b.txt")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)

        controller.perform(.duplicate, on: [tree.path("a.txt"), tree.path("b.txt")])
        await settle(controller, viewModel)

        XCTAssertEqual(tree.names(), ["a copy.txt", "a.txt", "b copy.txt", "b.txt"])
        XCTAssertEqual(Set(viewModel.selection), [tree.path("a copy.txt"), tree.path("b copy.txt")])
        await viewModel.undo().value
        XCTAssertEqual(tree.names(), ["a.txt", "b.txt"])
    }

    func testTheContextMenusPasteIsEnabledOnlyWithFiles() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = await opened(tree)
        let (controller, _) = attach(viewModel)
        let menu = NSMenu()
        controller.rebuildMenuItems(menu, forTargets: [tree.path("a.txt")])
        let paste = try XCTUnwrap(menu.items.first { $0.title == "Paste" })

        XCTAssertFalse(controller.validateMenuItem(paste))
        controller.perform(.copy, on: [tree.path("a.txt")])
        XCTAssertTrue(controller.validateMenuItem(paste))
    }
}

/// Answers the Collision Prompt from a script and records what it was asked.
@MainActor
final class ScriptedPrompt: CollisionPrompting {
    private var answers: [CollisionAnswer]
    private(set) var asked: [String] = []

    init(_ answers: [CollisionAnswer]) {
        self.answers = answers
    }

    func answer(forExisting name: String, isFolder _: Bool, copying _: Bool, remaining: Int) async -> CollisionAnswer {
        asked.append("\(name) (\(remaining) more)")
        return answers.isEmpty ? CollisionAnswer(.skip) : answers.removeFirst()
    }
}
