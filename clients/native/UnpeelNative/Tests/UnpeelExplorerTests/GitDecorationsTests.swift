import UnpeelGit
import XCTest
@testable import UnpeelExplorer

final class GitDecorationsTests: XCTestCase {
    private func decorations(_ entries: [GitStatusEntry], workTree: String = "/r") -> GitDecorations {
        GitDecorations(snapshot: GitRepositorySnapshot(
            location: GitRepositoryLocation(workTree: workTree, gitDirectory: workTree + "/.git", commonDirectory: workTree + "/.git"),
            status: GitStatus(head: GitHead(oid: "x", branch: "main"), entries: entries)
        ))
    }

    func testFilesCarryTheirOwnState() {
        let map = decorations([
            GitStatusEntry(path: "a.txt", kind: .modified),
            GitStatusEntry(path: "src/new.swift", kind: .added),
        ])

        XCTAssertEqual(map.kind(at: "/r/a.txt"), .modified)
        XCTAssertEqual(map.kind(at: "/r/src/new.swift"), .added)
        XCTAssertNil(map.kind(at: "/r/clean.txt"))
        XCTAssertNil(map.kind(at: "/elsewhere/a.txt"))
    }

    func testFoldersCarryTheStrongestStateBeneathThem() {
        let map = decorations([
            GitStatusEntry(path: "src/a/new.swift", kind: .untracked),
            GitStatusEntry(path: "src/a/edit.swift", kind: .modified),
            GitStatusEntry(path: "src/b/clash.swift", kind: .conflicted),
            GitStatusEntry(path: "docs/moved.md", originalPath: "old/moved.md", kind: .renamed),
            GitStatusEntry(path: "docs/fresh.md", kind: .added),
        ])

        XCTAssertEqual(map.kind(at: "/r/src/a"), .modified)
        XCTAssertEqual(map.kind(at: "/r/src/b"), .conflicted)
        XCTAssertEqual(map.kind(at: "/r/src"), .conflicted)
        XCTAssertEqual(map.kind(at: "/r/docs"), .renamed)
        XCTAssertNil(map.kind(at: "/r/old"), "a rename's original path is gone from the tree")
        XCTAssertNil(map.kind(at: "/r/old/moved.md"))
    }

    /// A deleted file has no row of its own, but its folder shows it.
    func testADeletedFileCountsTowardItsFolder() {
        let map = decorations([GitStatusEntry(path: "lib/gone.c", kind: .deleted)])

        XCTAssertEqual(map.kind(at: "/r/lib"), .deleted)
    }

    /// git lists an all-untracked folder once; everything inside it is
    /// untracked too.
    func testEverythingInsideAnUntrackedFolderIsUntracked() {
        let map = decorations([GitStatusEntry(path: "fresh", kind: .untracked, isDirectory: true)])

        XCTAssertEqual(map.kind(at: "/r/fresh"), .untracked)
        XCTAssertEqual(map.kind(at: "/r/fresh/deep/one.txt"), .untracked)
        XCTAssertNil(map.kind(at: "/r/freshly.txt"))
    }

    func testAWorktreeElsewhereResolvesAgainstItsOwnWorkTree() {
        let map = decorations([GitStatusEntry(path: "a.txt", kind: .modified)], workTree: "/trees/feature")

        XCTAssertEqual(map.kind(at: "/trees/feature/a.txt"), .modified)
        XCTAssertNil(map.kind(at: "/r/a.txt"))
    }

    func testNoneDecoratesNothing() {
        XCTAssertNil(GitDecorations.none.kind(at: "/r/a.txt"))
        XCTAssertTrue(GitDecorations.none.isEmpty)
        XCTAssertFalse(decorations([GitStatusEntry(path: "a.txt", kind: .modified)]).isEmpty)
    }
}
