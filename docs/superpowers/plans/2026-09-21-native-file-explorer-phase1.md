# Native File Explorer — Phase 1 (Core Tree) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toggleable, resizable native file-tree column to the Unpeel Mac app that shows the selected local session's project, lazily loads folders, auto-refreshes from disk, and lets the user open, preview, reveal, copy, send, and drag files.

**Architecture:** A new Foundation/AppKit-only SwiftPM library target `UnpeelExplorer` holds all logic: an immutable `FileTreeModel` (a map of directory path → contents plus an expanded set), a `DirectoryScanner` (listing + git-ignore marking), an FSEvents `FileSystemWatcher`, a `@MainActor ExplorerViewModel`, and an `NSOutlineView`-backed SwiftUI panel. The app target adds one adapter view, one state object, and three small edits to existing files.

**Tech Stack:** Swift 6 (tools 6.0, strict concurrency), SwiftUI + AppKit (`NSOutlineView`, `QLPreviewPanel`), CoreServices FSEvents, XCTest, `git check-ignore`.

Spec: `docs/superpowers/specs/2026-09-21-native-file-explorer-design.md`

## Global Constraints

- Platform floor: macOS 13 (`Package.swift` `.macOS(.v13)`); no API newer than macOS 13 without `#available`.
- `UnpeelExplorer` may import **only** `Foundation`, `AppKit`, `SwiftUI`, `CoreServices`, `Quartz`, `UniformTypeIdentifiers`, `os`. It must never import `UnpeelShared`, `GhosttyTerminal`, `CUnpeelNativeBridge`, or reference `UnpeelStore`.
- Existing files that may be edited — the complete list: `clients/native/UnpeelNative/Package.swift`, `Sources/UnpeelNative/Views/RootView.swift`, `Sources/UnpeelNative/AppDelegate.swift`. **`UnpeelStore.swift` must not be edited.** Everything else is new files.
- Immutability: model types are `struct`s with `let` fields; reducers return new values. Local `var` copies inside a reducer are fine; mutating `self` or an argument is not.
- Every path the explorer reads must be inside the current root after `realpath`. `.git` is never listed.
- All paths compared anywhere go through `CanonicalPath.resolve` (realpath). Do **not** use `URL.resolvingSymlinksInPath()` — it strips `/private`, and FSEvents reports `/private/...`.
- UserDefaults keys are prefixed `unpeel.explorer.`. The app target reads/writes through `AppDefaults.shared` (never `.standard`), so blank-home dev builds stay isolated.
- Panel defaults: hidden on first run; width default 260, min 180, max 520; *Show Hidden Files* off; *Show Git-Ignored Files* off; toggle shortcut ⌘⇧E.
- Directory cap: 10,000 entries, then a trailing "… N more items not shown" row.
- Match surrounding code style: comments state constraints the code cannot show, not narration. No `print`/debug statements.
- Git: work on branch `feat/native-file-explorer`; commit after each task with a conventional-commit message (`feat:`, `test:`, `docs:`, `chore:`); **no** `Co-Authored-By` trailer; never push.
- All commands run from `/Users/alimazid/unpeel/clients/native/UnpeelNative` unless a step says otherwise. The Rust bridge must exist before any `swift build`/`swift test`: run `../build-rust-bridge.sh debug` once if `../../../crates/target/native-bridge/debug/libunpeel_native_bridge.a` is missing.
- Never launch, quit, or signal `/Applications/Unpeel.app`. Runtime checks use `clients/native/dev-blank.sh` only.

## File Structure

New library — `clients/native/UnpeelNative/Sources/UnpeelExplorer/`:

| File | Responsibility |
|---|---|
| `CanonicalPath.swift` | realpath + "is inside root" check |
| `FileEntry.swift` | `FileKind`, `FileEntry`, `DirectoryListing`, `ExplorerError` |
| `DirectoryLoader.swift` | list one directory, sorted, capped, confined |
| `FileTreeModel.swift` | `DirectoryContents`, `VisibilityFilter`, immutable tree + reducers |
| `IgnoreChecking.swift` | `IgnoreChecking`, `GitIgnoreChecker`, `NoIgnoreChecker` |
| `DirectoryScanner.swift` | loader + ignore marking in one call |
| `FileSystemWatcher.swift` | `FileSystemChange`, FSEvents wrapper |
| `ExplorerStateStore.swift` | `RootViewState`, per-root persistence, toggles |
| `ExplorerViewModel.swift` | `ExplorerContext`, `ExplorerServices`, the view model |
| `ExplorerPaths.swift` | relative-path helper |
| `ExplorerKeyCommand.swift` | pure key → command mapping |
| `ExplorerItem.swift` | `NSObject` identity wrapper for outline rows |
| `FileIconProvider.swift` | cached icons by extension |
| `ExplorerPalette.swift` | injected colours/fonts + `ExplorerActionHandler` protocol |
| `ExplorerOutlineController.swift` | data source, delegate, menu, actions |
| `ExplorerNSOutlineView.swift` | key handling + Quick Look |
| `ExplorerOutlineView.swift` | `NSViewRepresentable` |
| `ExplorerPanelView.swift` | SwiftUI header, empty/error states |

Tests — `clients/native/UnpeelNative/Tests/UnpeelExplorerTests/`: `TempTree.swift` (helper) plus one test file per unit.

App target — new: `Sources/UnpeelNative/ExplorerPanelState.swift`, `Sources/UnpeelNative/ExplorerContextResolver.swift`, `Sources/UnpeelNative/Views/ExplorerPanelHost.swift`; tests `Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift`, `Tests/UnpeelNativeTests/ExplorerPanelStateTests.swift`.

---

### Task 1: Library target, canonical paths, directory loader

**Files:**
- Modify: `Package.swift` (targets array)
- Create: `Sources/UnpeelExplorer/CanonicalPath.swift`, `Sources/UnpeelExplorer/FileEntry.swift`, `Sources/UnpeelExplorer/DirectoryLoader.swift`
- Test: `Tests/UnpeelExplorerTests/TempTree.swift`, `Tests/UnpeelExplorerTests/DirectoryLoaderTests.swift`

**Interfaces:**
- Produces: `CanonicalPath.resolve(_:) -> String?`, `CanonicalPath.isInside(_:root:) -> Bool`; `FileKind`; `FileEntry` (fields `path, name, kind, isSymlink, isHidden, isIgnored, isExpandable`, `with(isIgnored:)`); `DirectoryListing(entries:truncatedCount:)`; `ExplorerError.outsideRoot(String)`; `DirectoryLoader(maxEntries:).load(directory:root:) throws -> DirectoryListing`; test helper `TempTree`.

- [ ] **Step 1: Add the targets to `Package.swift`**

In the `targets:` array, add this target immediately before `.executableTarget(name: "UnpeelNative"`:

```swift
        // VS Code-style file explorer (fork-only feature). Foundation/AppKit
        // only: it must build and test without Ghostty or the Rust bridge.
        .target(
            name: "UnpeelExplorer",
            path: "Sources/UnpeelExplorer"
        ),
```

In the `UnpeelNative` executable target's `dependencies:` array add, as the first element:

```swift
                "UnpeelExplorer",
```

After the existing `.testTarget(name: "UnpeelNativeTests", …)` add:

```swift
        .testTarget(
            name: "UnpeelExplorerTests",
            dependencies: ["UnpeelExplorer"],
            path: "Tests/UnpeelExplorerTests"
        ),
```

- [ ] **Step 2: Write the test helper and the failing tests**

`Tests/UnpeelExplorerTests/TempTree.swift`:

```swift
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
```

`Tests/UnpeelExplorerTests/DirectoryLoaderTests.swift`:

```swift
import XCTest
@testable import UnpeelExplorer

final class DirectoryLoaderTests: XCTestCase {
    func testFoldersFirstThenNaturalNameOrder() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("b.txt"); try tree.file("a10.txt"); try tree.file("a2.txt")
        try tree.dir("zeta"); try tree.dir("Alpha")

        let listing = try DirectoryLoader().load(directory: tree.root, root: tree.root)

        XCTAssertEqual(listing.entries.map(\.name), ["Alpha", "zeta", "a2.txt", "a10.txt", "b.txt"])
        XCTAssertEqual(listing.entries.map(\.kind), [.directory, .directory, .file, .file, .file])
        XCTAssertEqual(listing.truncatedCount, 0)
        XCTAssertEqual(listing.entries[2].path, tree.path("a2.txt"))
    }

    func testDotfilesAreMarkedHiddenAndNothingIsIgnoredByTheLoader() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file(".env"); try tree.file("shown.txt")

        let byName = Dictionary(
            uniqueKeysWithValues: try DirectoryLoader()
                .load(directory: tree.root, root: tree.root).entries.map { ($0.name, $0) }
        )

        XCTAssertEqual(byName[".env"]?.isHidden, true)
        XCTAssertEqual(byName["shown.txt"]?.isHidden, false)
        XCTAssertEqual(byName[".env"]?.isIgnored, false)
    }

    func testSymlinkedDirectoryInsideRootIsExpandable() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.dir("real")
        try tree.symlink("link", to: tree.path("real"))

        let link = try XCTUnwrap(
            DirectoryLoader().load(directory: tree.root, root: tree.root)
                .entries.first { $0.name == "link" }
        )

        XCTAssertTrue(link.isSymlink)
        XCTAssertEqual(link.kind, .directory)
        XCTAssertTrue(link.isExpandable)
    }

    func testSymlinkedDirectoryOutsideRootIsNotExpandable() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let outside = try TempTree(); defer { outside.remove() }
        try tree.symlink("escape", to: outside.root)

        let link = try XCTUnwrap(
            DirectoryLoader().load(directory: tree.root, root: tree.root)
                .entries.first { $0.name == "escape" }
        )

        XCTAssertEqual(link.kind, .directory)
        XCTAssertFalse(link.isExpandable)
    }

    func testBrokenSymlinkIsAFile() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.symlink("dangling", to: tree.path("missing"))

        let link = try XCTUnwrap(
            DirectoryLoader().load(directory: tree.root, root: tree.root).entries.first
        )

        XCTAssertEqual(link.kind, .file)
        XCTAssertFalse(link.isExpandable)
    }

    func testLoadingADirectoryOutsideTheRootThrows() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let outside = try TempTree(); defer { outside.remove() }

        XCTAssertThrowsError(try DirectoryLoader().load(directory: outside.root, root: tree.root)) { error in
            XCTAssertEqual(error as? ExplorerError, .outsideRoot(outside.root))
        }
    }

    func testUnreadableDirectoryThrows() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let locked = try tree.dir("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

        XCTAssertThrowsError(try DirectoryLoader().load(directory: locked, root: tree.root))
    }

    func testListingIsCappedAndReportsTheRemainder() throws {
        let tree = try TempTree(); defer { tree.remove() }
        for index in 0..<5 { try tree.file("f\(index).txt") }

        let listing = try DirectoryLoader(maxEntries: 3).load(directory: tree.root, root: tree.root)

        XCTAssertEqual(listing.entries.map(\.name), ["f0.txt", "f1.txt", "f2.txt"])
        XCTAssertEqual(listing.truncatedCount, 2)
    }

    func testCanonicalPathIsInsideRejectsSiblingPrefix() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let inner = try tree.dir("proj")
        let sibling = try tree.dir("proj-other")

        XCTAssertTrue(CanonicalPath.isInside(inner, root: inner))
        XCTAssertFalse(CanonicalPath.isInside(sibling, root: inner))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter UnpeelExplorerTests 2>&1 | tail -20`
Expected: build FAILS — `Sources/UnpeelExplorer` has no sources / `cannot find 'CanonicalPath' in scope`.

- [ ] **Step 4: Implement**

`Sources/UnpeelExplorer/CanonicalPath.swift`:

```swift
import Foundation

/// realpath(3)-based canonicalisation. FSEvents reports real paths
/// (`/private/var/…`) while `URL.resolvingSymlinksInPath()` strips `/private`,
/// so every path the explorer compares goes through here.
public enum CanonicalPath {
    public static func resolve(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `path` resolves to `root` or to something beneath it.
    public static func isInside(_ path: String, root: String) -> Bool {
        guard let resolvedPath = resolve(path), let resolvedRoot = resolve(root) else {
            return false
        }
        if resolvedPath == resolvedRoot { return true }
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolvedPath.hasPrefix(prefix)
    }
}
```

`Sources/UnpeelExplorer/FileEntry.swift`:

```swift
import Foundation

public enum FileKind: String, Sendable, Equatable {
    case file
    case directory
}

/// One row of a directory listing. `kind` follows symlinks (a link to a
/// folder is a `.directory`); `isExpandable` is false for a linked folder
/// whose target lies outside the explorer root.
public struct FileEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let kind: FileKind
    public let isSymlink: Bool
    public let isHidden: Bool
    public let isIgnored: Bool
    public let isExpandable: Bool

    public var id: String { path }

    public init(
        path: String,
        name: String,
        kind: FileKind,
        isSymlink: Bool = false,
        isHidden: Bool = false,
        isIgnored: Bool = false,
        isExpandable: Bool? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isIgnored = isIgnored
        self.isExpandable = isExpandable ?? (kind == .directory)
    }

    public func with(isIgnored: Bool) -> FileEntry {
        FileEntry(
            path: path, name: name, kind: kind, isSymlink: isSymlink,
            isHidden: isHidden, isIgnored: isIgnored, isExpandable: isExpandable
        )
    }
}

public struct DirectoryListing: Sendable, Equatable {
    public let entries: [FileEntry]
    /// Entries beyond the loader's cap that were not included.
    public let truncatedCount: Int

    public init(entries: [FileEntry], truncatedCount: Int = 0) {
        self.entries = entries
        self.truncatedCount = truncatedCount
    }
}

public enum ExplorerError: Error, Equatable, LocalizedError {
    case outsideRoot(String)
    case rootUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .outsideRoot(let path):
            return "“\(path)” is outside the project folder."
        case .rootUnavailable(let path):
            return "“\(path)” could not be opened."
        }
    }
}
```

`Sources/UnpeelExplorer/DirectoryLoader.swift`:

```swift
import Foundation

/// Lists exactly one directory. Never recurses and never reads outside
/// `root`; callers hop off the main thread before calling `load`.
public struct DirectoryLoader: Sendable {
    public static let defaultMaxEntries = 10_000
    public let maxEntries: Int

    public init(maxEntries: Int = DirectoryLoader.defaultMaxEntries) {
        self.maxEntries = maxEntries
    }

    public func load(directory: String, root: String) throws -> DirectoryListing {
        guard CanonicalPath.isInside(directory, root: root) else {
            throw ExplorerError.outsideRoot(directory)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        let sorted = names
            .map { Self.entry(named: $0, in: directory, root: root) }
            .sorted(by: Self.precedes)
        let kept = Array(sorted.prefix(maxEntries))
        return DirectoryListing(entries: kept, truncatedCount: sorted.count - kept.count)
    }

    private static func entry(named name: String, in directory: String, root: String) -> FileEntry {
        let manager = FileManager.default
        let path = (directory as NSString).appendingPathComponent(name)
        let attributes = try? manager.attributesOfItem(atPath: path)
        let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: path, isDirectory: &isDirectory)
        let kind: FileKind = (exists && isDirectory.boolValue) ? .directory : .file
        let expandable = kind == .directory
            && (!isSymlink || CanonicalPath.isInside(path, root: root))
        return FileEntry(
            path: path,
            name: name,
            kind: kind,
            isSymlink: isSymlink,
            isHidden: name.hasPrefix("."),
            isIgnored: false,
            isExpandable: expandable
        )
    }

    /// VS Code's default order: folders first, then natural name order.
    private static func precedes(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind == .directory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter UnpeelExplorerTests 2>&1 | tail -20`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Package.swift clients/native/UnpeelNative/Sources/UnpeelExplorer clients/native/UnpeelNative/Tests/UnpeelExplorerTests
git commit -m "feat: add UnpeelExplorer target with confined directory loader"
```

---

### Task 2: Immutable tree model

**Files:**
- Create: `Sources/UnpeelExplorer/FileTreeModel.swift`
- Test: `Tests/UnpeelExplorerTests/FileTreeModelTests.swift`

**Interfaces:**
- Consumes: `FileEntry`, `DirectoryListing` (Task 1).
- Produces: `DirectoryContents` (`.loading`, `.loaded(DirectoryListing)`, `.failed(String)`); `VisibilityFilter(showHidden:showIgnored:)`; `FileTreeModel` with `root`, `directories`, `expanded`, `init(root:)`, `settingContents(_:for:)`, `expanding(_:)`, `collapsing(_:)`, `collapsingAll()`, `removingDirectory(_:)`, `visibleChildren(of:filter:) -> [FileEntry]`, `truncatedCount(of:) -> Int`, `entry(at:) -> FileEntry?`, `loadedDirectories: Set<String>`, `static parent(of:) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelExplorerTests/FileTreeModelTests.swift`:

```swift
import XCTest
@testable import UnpeelExplorer

final class FileTreeModelTests: XCTestCase {
    private let root = "/r"

    private func dir(_ path: String) -> FileEntry {
        FileEntry(path: path, name: (path as NSString).lastPathComponent, kind: .directory)
    }

    private func file(_ path: String, hidden: Bool = false, ignored: Bool = false) -> FileEntry {
        FileEntry(
            path: path, name: (path as NSString).lastPathComponent, kind: .file,
            isHidden: hidden, isIgnored: ignored
        )
    }

    private func loaded(_ entries: [FileEntry], truncated: Int = 0) -> DirectoryContents {
        .loaded(DirectoryListing(entries: entries, truncatedCount: truncated))
    }

    func testReducersReturnNewValuesAndLeaveTheInputUntouched() {
        let original = FileTreeModel(root: root)
        let snapshot = original

        let changed = original
            .settingContents(loaded([dir("/r/src")]), for: root)
            .expanding("/r/src")

        XCTAssertEqual(original, snapshot)
        XCTAssertTrue(original.directories.isEmpty)
        XCTAssertEqual(changed.expanded, ["/r/src"])
        XCTAssertEqual(changed.loadedDirectories, [root])
    }

    func testCollapsingKeepsDescendantExpansionForReExpand() {
        let model = FileTreeModel(root: root)
            .expanding("/r/src").expanding("/r/src/views")
            .collapsing("/r/src")

        XCTAssertEqual(model.expanded, ["/r/src/views"])
    }

    func testCollapsingAllClearsExpansion() {
        let model = FileTreeModel(root: root).expanding("/r/a").expanding("/r/b").collapsingAll()
        XCTAssertTrue(model.expanded.isEmpty)
    }

    func testReloadingAParentDropsSubtreesOfVanishedFolders() {
        let model = FileTreeModel(root: root)
            .settingContents(loaded([dir("/r/gone"), dir("/r/kept")]), for: root)
            .settingContents(loaded([dir("/r/gone/deep")]), for: "/r/gone")
            .settingContents(loaded([]), for: "/r/gone/deep")
            .settingContents(loaded([]), for: "/r/kept")
            .expanding("/r/gone").expanding("/r/gone/deep").expanding("/r/kept")

        let reloaded = model.settingContents(loaded([dir("/r/kept")]), for: root)

        XCTAssertEqual(reloaded.loadedDirectories, [root, "/r/kept"])
        XCTAssertEqual(reloaded.expanded, ["/r/kept"])
    }

    func testRemovingADirectoryDropsItAndItsDescendants() {
        let model = FileTreeModel(root: root)
            .settingContents(loaded([dir("/r/a")]), for: root)
            .settingContents(loaded([dir("/r/a/b")]), for: "/r/a")
            .settingContents(loaded([]), for: "/r/a/b")
            .expanding("/r/a").expanding("/r/a/b")
            .removingDirectory("/r/a")

        XCTAssertEqual(model.loadedDirectories, [root])
        XCTAssertTrue(model.expanded.isEmpty)
    }

    func testSiblingWithSharedPrefixSurvivesRemoval() {
        let model = FileTreeModel(root: root)
            .settingContents(loaded([]), for: "/r/app")
            .settingContents(loaded([]), for: "/r/app-old")
            .removingDirectory("/r/app")

        XCTAssertEqual(model.loadedDirectories, ["/r/app-old"])
    }

    func testVisibleChildrenHonourTheFilterAndAlwaysHideDotGit() {
        let model = FileTreeModel(root: root).settingContents(
            loaded([
                dir("/r/.git"),
                file("/r/.env", hidden: true),
                file("/r/out.log", ignored: true),
                file("/r/main.swift"),
            ]),
            for: root
        )

        let names: (VisibilityFilter) -> [String] = { model.visibleChildren(of: self.root, filter: $0).map(\.name) }

        XCTAssertEqual(names(VisibilityFilter(showHidden: false, showIgnored: false)), ["main.swift"])
        XCTAssertEqual(names(VisibilityFilter(showHidden: true, showIgnored: false)), [".env", "main.swift"])
        XCTAssertEqual(names(VisibilityFilter(showHidden: false, showIgnored: true)), ["out.log", "main.swift"])
        XCTAssertEqual(names(VisibilityFilter(showHidden: true, showIgnored: true)), [".env", "out.log", "main.swift"])
    }

    func testChildrenOfUnloadedLoadingOrFailedDirectoriesAreEmpty() {
        let model = FileTreeModel(root: root)
            .settingContents(.loading, for: "/r/a")
            .settingContents(.failed("denied"), for: "/r/b")
        let all = VisibilityFilter(showHidden: true, showIgnored: true)

        XCTAssertTrue(model.visibleChildren(of: "/r/a", filter: all).isEmpty)
        XCTAssertTrue(model.visibleChildren(of: "/r/b", filter: all).isEmpty)
        XCTAssertTrue(model.visibleChildren(of: "/r/never", filter: all).isEmpty)
        XCTAssertTrue(model.loadedDirectories.isEmpty)
    }

    func testEntryLookupAndTruncationCount() {
        let model = FileTreeModel(root: root)
            .settingContents(loaded([file("/r/a.txt")], truncated: 7), for: root)

        XCTAssertEqual(model.entry(at: "/r/a.txt")?.name, "a.txt")
        XCTAssertNil(model.entry(at: "/r/missing.txt"))
        XCTAssertEqual(model.truncatedCount(of: root), 7)
        XCTAssertEqual(FileTreeModel.parent(of: "/r/src/a.txt"), "/r/src")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FileTreeModelTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'FileTreeModel' in scope`.

- [ ] **Step 3: Implement**

`Sources/UnpeelExplorer/FileTreeModel.swift`:

```swift
import Foundation

public enum DirectoryContents: Sendable, Equatable {
    case loading
    case loaded(DirectoryListing)
    case failed(String)
}

public struct VisibilityFilter: Sendable, Equatable {
    public let showHidden: Bool
    public let showIgnored: Bool

    public init(showHidden: Bool = false, showIgnored: Bool = false) {
        self.showHidden = showHidden
        self.showIgnored = showIgnored
    }
}

/// The whole tree as a flat map of directory path → contents plus the set of
/// expanded folders. Flat rather than nested so a reload replaces one entry
/// and an `NSOutlineView` row is addressed by its path. Every reducer returns
/// a new model.
public struct FileTreeModel: Sendable, Equatable {
    public let root: String
    public let directories: [String: DirectoryContents]
    public let expanded: Set<String>

    public init(
        root: String,
        directories: [String: DirectoryContents] = [:],
        expanded: Set<String> = []
    ) {
        self.root = root
        self.directories = directories
        self.expanded = expanded
    }

    public static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func isSameOrBelow(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }

    public var loadedDirectories: Set<String> {
        Set(directories.compactMap { path, contents in
            if case .loaded = contents { return path }
            return nil
        })
    }

    /// Replaces one directory's contents. A successful reload also drops the
    /// subtrees (contents and expansion) of child folders that vanished.
    public func settingContents(_ contents: DirectoryContents, for directory: String) -> FileTreeModel {
        var nextDirectories = directories
        nextDirectories[directory] = contents
        guard case .loaded(let listing) = contents else {
            return FileTreeModel(root: root, directories: nextDirectories, expanded: expanded)
        }
        let alive = Set(listing.entries.filter { $0.kind == .directory }.map(\.path))
        let tracked = Set(nextDirectories.keys).union(expanded)
        let orphans = tracked.filter { Self.parent(of: $0) == directory && !alive.contains($0) }
        let survives: (String) -> Bool = { path in
            !orphans.contains { Self.isSameOrBelow(path, $0) }
        }
        return FileTreeModel(
            root: root,
            directories: nextDirectories.filter { survives($0.key) },
            expanded: expanded.filter(survives)
        )
    }

    public func expanding(_ path: String) -> FileTreeModel {
        FileTreeModel(root: root, directories: directories, expanded: expanded.union([path]))
    }

    /// Descendants stay expanded so re-expanding restores the subtree, as in
    /// VS Code.
    public func collapsing(_ path: String) -> FileTreeModel {
        FileTreeModel(root: root, directories: directories, expanded: expanded.subtracting([path]))
    }

    public func collapsingAll() -> FileTreeModel {
        FileTreeModel(root: root, directories: directories, expanded: [])
    }

    public func removingDirectory(_ path: String) -> FileTreeModel {
        FileTreeModel(
            root: root,
            directories: directories.filter { !Self.isSameOrBelow($0.key, path) },
            expanded: expanded.filter { !Self.isSameOrBelow($0, path) }
        )
    }

    public func visibleChildren(of directory: String, filter: VisibilityFilter) -> [FileEntry] {
        guard case .loaded(let listing)? = directories[directory] else { return [] }
        return listing.entries.filter { entry in
            if entry.name == ".git" { return false }
            if entry.isHidden && !filter.showHidden { return false }
            if entry.isIgnored && !filter.showIgnored { return false }
            return true
        }
    }

    public func truncatedCount(of directory: String) -> Int {
        guard case .loaded(let listing)? = directories[directory] else { return 0 }
        return listing.truncatedCount
    }

    public func entry(at path: String) -> FileEntry? {
        guard case .loaded(let listing)? = directories[Self.parent(of: path)] else { return nil }
        return listing.entries.first { $0.path == path }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter FileTreeModelTests 2>&1 | tail -20`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer/FileTreeModel.swift clients/native/UnpeelNative/Tests/UnpeelExplorerTests/FileTreeModelTests.swift
git commit -m "feat: add immutable explorer tree model"
```

---

### Task 3: Git-ignore checking and the directory scanner

**Files:**
- Create: `Sources/UnpeelExplorer/IgnoreChecking.swift`, `Sources/UnpeelExplorer/DirectoryScanner.swift`
- Test: `Tests/UnpeelExplorerTests/DirectoryScannerTests.swift`

**Interfaces:**
- Consumes: `DirectoryLoader`, `DirectoryListing`, `FileEntry.with(isIgnored:)`.
- Produces: `protocol IgnoreChecking: Sendable { func ignoredPaths(among: [String], root: String) -> Set<String> }`; `GitIgnoreChecker()`; `NoIgnoreChecker()`; `DirectoryScanner(loader:ignore:).scan(directory:root:) throws -> DirectoryListing`.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelExplorerTests/DirectoryScannerTests.swift`:

```swift
import XCTest
@testable import UnpeelExplorer

final class DirectoryScannerTests: XCTestCase {
    private func git(_ arguments: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testGitIgnoredFilesAndFoldersAreMarked() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try git(["init", "-q"], in: tree.root)
        try tree.file(".gitignore", "build/\n*.log\n")
        try tree.dir("build"); try tree.file("build/out.o")
        try tree.file("debug.log"); try tree.file("keep.txt")

        let listing = try DirectoryScanner(loader: DirectoryLoader(), ignore: GitIgnoreChecker())
            .scan(directory: tree.root, root: tree.root)
        let ignored = Set(listing.entries.filter(\.isIgnored).map(\.name))

        XCTAssertEqual(ignored, ["build", "debug.log"])
    }

    func testNestedDirectoryUsesTheRepositoryRules() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try git(["init", "-q"], in: tree.root)
        try tree.file(".gitignore", "*.tmp\n")
        try tree.file("src/a.tmp"); try tree.file("src/a.swift")

        let listing = try DirectoryScanner(loader: DirectoryLoader(), ignore: GitIgnoreChecker())
            .scan(directory: tree.path("src"), root: tree.root)

        XCTAssertEqual(listing.entries.filter(\.isIgnored).map(\.name), ["a.tmp"])
    }

    func testOutsideARepositoryNothingIsIgnored() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("debug.log")

        let ignored = GitIgnoreChecker().ignoredPaths(among: [tree.path("debug.log")], root: tree.root)

        XCTAssertTrue(ignored.isEmpty)
    }

    func testEmptyInputSkipsGitEntirely() {
        XCTAssertTrue(GitIgnoreChecker().ignoredPaths(among: [], root: "/nonexistent").isEmpty)
    }

    func testManyPathsDoNotDeadlockThePipes() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try git(["init", "-q"], in: tree.root)
        try tree.file(".gitignore", "*.log\n")
        let paths = (0..<4000).map { tree.path("some/deeply/nested/folder/name/file-\($0).log") }

        let ignored = GitIgnoreChecker().ignoredPaths(among: paths, root: tree.root)

        XCTAssertEqual(ignored.count, 4000)
    }

    func testScannerWithNoIgnoreCheckerLeavesEntriesUnmarked() throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("debug.log")

        let listing = try DirectoryScanner(loader: DirectoryLoader(), ignore: NoIgnoreChecker())
            .scan(directory: tree.root, root: tree.root)

        XCTAssertEqual(listing.entries.map(\.isIgnored), [false])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DirectoryScannerTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'DirectoryScanner' in scope`.

- [ ] **Step 3: Implement**

`Sources/UnpeelExplorer/IgnoreChecking.swift`:

```swift
import Foundation
import os

public protocol IgnoreChecking: Sendable {
    /// The subset of `paths` that git ignores. Empty when `root` is not in a
    /// repository or git is unavailable — ignoring is never a reason to fail
    /// a listing.
    func ignoredPaths(among paths: [String], root: String) -> Set<String>
}

public struct NoIgnoreChecker: IgnoreChecking {
    public init() {}
    public func ignoredPaths(among _: [String], root _: String) -> Set<String> { [] }
}

/// One `git check-ignore -z --stdin` process per call. Exit status 0 = some
/// ignored, 1 = none ignored, anything else (128 = not a repository) = treat
/// as none.
public struct GitIgnoreChecker: IgnoreChecking {
    private static let logger = Logger(subsystem: "com.unpeel.explorer", category: "ignore")

    public init() {}

    public func ignoredPaths(among paths: [String], root: String) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root, "check-ignore", "-z", "--stdin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Self.logger.error("git check-ignore could not start: \(error.localizedDescription, privacy: .public)")
            return []
        }
        // Feed stdin from another thread: git streams results while it reads,
        // so writing everything first would deadlock once a pipe fills.
        let payload = Data(paths.joined(separator: "\0").utf8) + Data([0])
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let ignored = data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
        return Set(ignored)
    }
}
```

`Sources/UnpeelExplorer/DirectoryScanner.swift`:

```swift
import Foundation

/// A directory listing with git-ignore state applied. Ignore rules are
/// re-evaluated on every scan, so there is no cache to invalidate; a changed
/// `.gitignore` is handled by rescanning (see `ExplorerViewModel`).
public struct DirectoryScanner: Sendable {
    private let loader: DirectoryLoader
    private let ignore: any IgnoreChecking

    public init(loader: DirectoryLoader = DirectoryLoader(), ignore: any IgnoreChecking = GitIgnoreChecker()) {
        self.loader = loader
        self.ignore = ignore
    }

    public func scan(directory: String, root: String) throws -> DirectoryListing {
        let listing = try loader.load(directory: directory, root: root)
        let ignored = ignore.ignoredPaths(among: listing.entries.map(\.path), root: root)
        guard !ignored.isEmpty else { return listing }
        return DirectoryListing(
            entries: listing.entries.map { $0.with(isIgnored: ignored.contains($0.path)) },
            truncatedCount: listing.truncatedCount
        )
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DirectoryScannerTests 2>&1 | tail -20`
Expected: `Executed 6 tests, with 0 failures`. If `testGitIgnoredFilesAndFoldersAreMarked` reports `build` missing, git echoed the directory with a trailing slash — normalise by stripping one trailing `/` from each returned path before building the set, and re-run.

- [ ] **Step 5: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer/IgnoreChecking.swift clients/native/UnpeelNative/Sources/UnpeelExplorer/DirectoryScanner.swift clients/native/UnpeelNative/Tests/UnpeelExplorerTests/DirectoryScannerTests.swift
git commit -m "feat: mark git-ignored entries in explorer listings"
```

---

### Task 4: FSEvents watcher

**Files:**
- Create: `Sources/UnpeelExplorer/FileSystemWatcher.swift`
- Test: `Tests/UnpeelExplorerTests/FileSystemWatcherTests.swift`

**Interfaces:**
- Produces: `FileSystemChange(directories: Set<String>, touchedGitignore: Bool)` with `static func from(eventPaths: [String]) -> FileSystemChange`; `FileSystemWatcher(root:latency:handler:)` where `Handler = @Sendable (FileSystemChange) -> Void`, `start()`, `stop()`. The handler runs on a private background queue. `stop()` must not be called from inside the handler.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelExplorerTests/FileSystemWatcherTests.swift`:

```swift
import XCTest
@testable import UnpeelExplorer

final class FileSystemWatcherTests: XCTestCase {
    func testEventPathsMapToTheirParentDirectories() {
        let change = FileSystemChange.from(eventPaths: ["/r/src/a.swift", "/r/src/b.swift", "/r/docs"])

        XCTAssertEqual(change.directories, ["/r/src", "/r/src/a.swift", "/r/src/b.swift", "/r", "/r/docs"])
        XCTAssertFalse(change.touchedGitignore)
    }

    func testGitignoreEventsAreFlagged() {
        XCTAssertTrue(FileSystemChange.from(eventPaths: ["/r/sub/.gitignore"]).touchedGitignore)
    }

    func testTrailingSlashesAreNormalised() {
        XCTAssertEqual(FileSystemChange.from(eventPaths: ["/r/docs/"]).directories, ["/r", "/r/docs"])
    }

    func testCreatingAFileReportsItsDirectory() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let sub = try tree.dir("sub")
        let reported = expectation(description: "change under sub reported")
        reported.assertForOverFulfill = false
        let watcher = FileSystemWatcher(root: tree.root, latency: 0.05) { change in
            if change.directories.contains(sub) { reported.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? tree.file("sub/new.txt", "hello")
        }

        wait(for: [reported], timeout: 10)
    }

    func testStopIsIdempotentAndStopsDelivery() throws {
        let tree = try TempTree(); defer { tree.remove() }
        let unexpected = expectation(description: "no delivery after stop")
        unexpected.isInverted = true
        let watcher = FileSystemWatcher(root: tree.root, latency: 0.05) { _ in unexpected.fulfill() }
        watcher.start()
        watcher.stop()
        watcher.stop()

        try tree.file("late.txt")

        wait(for: [unexpected], timeout: 1)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FileSystemWatcherTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'FileSystemChange' in scope`.

- [ ] **Step 3: Implement**

`Sources/UnpeelExplorer/FileSystemWatcher.swift`:

```swift
import CoreServices
import Foundation

public struct FileSystemChange: Sendable, Equatable {
    /// Directories whose listing may have changed: each event path's parent,
    /// plus the path itself in case it is a directory.
    public let directories: Set<String>
    public let touchedGitignore: Bool

    public init(directories: Set<String>, touchedGitignore: Bool) {
        self.directories = directories
        self.touchedGitignore = touchedGitignore
    }

    public static func from(eventPaths: [String]) -> FileSystemChange {
        let normalised = eventPaths.map { path in
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let directories = normalised.reduce(into: Set<String>()) { result, path in
            result.insert(path)
            result.insert((path as NSString).deletingLastPathComponent)
        }
        let touched = normalised.contains { ($0 as NSString).lastPathComponent == ".gitignore" }
        return FileSystemChange(directories: directories, touchedGitignore: touched)
    }
}

/// One recursive FSEvents stream on the explorer root. `root` must already be
/// canonical (`CanonicalPath.resolve`) so reported paths compare equal to
/// model paths. All stream state is confined to `queue`.
public final class FileSystemWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (FileSystemChange) -> Void

    private let root: String
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.unpeel.explorer.fsevents")
    private var stream: FSEventStreamRef?

    public init(root: String, latency: TimeInterval = 0.15, handler: @escaping Handler) {
        self.root = root
        self.latency = latency
        self.handler = handler
    }

    deinit {
        // No other reference exists here, so tear down without hopping queues.
        teardown()
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
            )
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, eventPaths, _, _ in
                    guard let info else { return }
                    let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
                    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                    guard !paths.isEmpty else { return }
                    watcher.handler(FileSystemChange.from(eventPaths: paths))
                },
                &context,
                [root] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    /// Must not be called from inside the handler (it runs on `queue`).
    public func stop() {
        queue.sync { teardown() }
    }

    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter FileSystemWatcherTests 2>&1 | tail -20`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer/FileSystemWatcher.swift clients/native/UnpeelNative/Tests/UnpeelExplorerTests/FileSystemWatcherTests.swift
git commit -m "feat: add FSEvents watcher for the explorer root"
```

---

### Task 5: Per-root state persistence

**Files:**
- Create: `Sources/UnpeelExplorer/ExplorerStateStore.swift`
- Test: `Tests/UnpeelExplorerTests/ExplorerStateStoreTests.swift`

**Interfaces:**
- Consumes: `VisibilityFilter` (Task 2).
- Produces: `RootViewState(expanded: [String], selection: [String], scrollOffset: Double)` (`Codable`, `Equatable`, `Sendable`); `@MainActor final class ExplorerStateStore` with `static let maxRoots = 50`, `init(defaults: UserDefaults)`, `state(forRoot:) -> RootViewState?`, `save(_:forRoot:now:)`, `var filter: VisibilityFilter { get set }`.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelExplorerTests/ExplorerStateStoreTests.swift`:

```swift
import XCTest
@testable import UnpeelExplorer

@MainActor
final class ExplorerStateStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "unpeel.explorer.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testRoundTripsStatePerRoot() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = RootViewState(expanded: ["/r/a", "/r/a/b"], selection: ["/r/a/b/c.txt"], scrollOffset: 42)

        ExplorerStateStore(defaults: defaults).save(state, forRoot: "/r")

        let reopened = ExplorerStateStore(defaults: defaults)
        XCTAssertEqual(reopened.state(forRoot: "/r"), state)
        XCTAssertNil(reopened.state(forRoot: "/other"))
    }

    func testKeepsOnlyTheMostRecentlyUsedRoots() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExplorerStateStore(defaults: defaults)
        let empty = RootViewState(expanded: [], selection: [], scrollOffset: 0)

        for index in 0..<(ExplorerStateStore.maxRoots + 5) {
            store.save(empty, forRoot: "/r\(index)", now: Date(timeIntervalSince1970: Double(index)))
        }

        XCTAssertNil(store.state(forRoot: "/r0"))
        XCTAssertNil(store.state(forRoot: "/r4"))
        XCTAssertNotNil(store.state(forRoot: "/r5"))
        XCTAssertNotNil(store.state(forRoot: "/r\(ExplorerStateStore.maxRoots + 4)"))
    }

    func testFilterDefaultsOffAndPersists() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExplorerStateStore(defaults: defaults)

        XCTAssertEqual(store.filter, VisibilityFilter(showHidden: false, showIgnored: false))
        store.filter = VisibilityFilter(showHidden: true, showIgnored: false)

        XCTAssertEqual(ExplorerStateStore(defaults: defaults).filter, VisibilityFilter(showHidden: true, showIgnored: false))
    }

    func testCorruptStoredDataIsTreatedAsEmpty() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "unpeel.explorer.roots")

        XCTAssertNil(ExplorerStateStore(defaults: defaults).state(forRoot: "/r"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ExplorerStateStoreTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'ExplorerStateStore' in scope`.

- [ ] **Step 3: Implement**

`Sources/UnpeelExplorer/ExplorerStateStore.swift`:

```swift
import Foundation

public struct RootViewState: Codable, Sendable, Equatable {
    public let expanded: [String]
    public let selection: [String]
    public let scrollOffset: Double

    public init(expanded: [String], selection: [String], scrollOffset: Double) {
        self.expanded = expanded
        self.selection = selection
        self.scrollOffset = scrollOffset
    }
}

/// View state remembered per explorer root, bounded so a long-lived install
/// does not accumulate state for every folder ever browsed.
@MainActor
public final class ExplorerStateStore {
    public static let maxRoots = 50

    private static let rootsKey = "unpeel.explorer.roots"
    private static let showHiddenKey = "unpeel.explorer.showHidden"
    private static let showIgnoredKey = "unpeel.explorer.showIgnored"

    private struct StoredRoot: Codable {
        let state: RootViewState
        let lastUsed: Double
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var filter: VisibilityFilter {
        get {
            VisibilityFilter(
                showHidden: defaults.bool(forKey: Self.showHiddenKey),
                showIgnored: defaults.bool(forKey: Self.showIgnoredKey)
            )
        }
        set {
            defaults.set(newValue.showHidden, forKey: Self.showHiddenKey)
            defaults.set(newValue.showIgnored, forKey: Self.showIgnoredKey)
        }
    }

    public func state(forRoot root: String) -> RootViewState? {
        loadRoots()[root]?.state
    }

    public func save(_ state: RootViewState, forRoot root: String, now: Date = Date()) {
        let updated = loadRoots().merging(
            [root: StoredRoot(state: state, lastUsed: now.timeIntervalSince1970)]
        ) { _, new in new }
        let kept = updated
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
            .prefix(Self.maxRoots)
        let bounded = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: Self.rootsKey)
    }

    private func loadRoots() -> [String: StoredRoot] {
        guard let data = defaults.data(forKey: Self.rootsKey),
              let roots = try? JSONDecoder().decode([String: StoredRoot].self, from: data)
        else { return [:] }
        return roots
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ExplorerStateStoreTests 2>&1 | tail -20`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerStateStore.swift clients/native/UnpeelNative/Tests/UnpeelExplorerTests/ExplorerStateStoreTests.swift
git commit -m "feat: persist explorer view state per root"
```

---

### Task 6: View model

**Files:**
- Create: `Sources/UnpeelExplorer/ExplorerPaths.swift`, `Sources/UnpeelExplorer/ExplorerViewModel.swift`
- Test: `Tests/UnpeelExplorerTests/ExplorerViewModelTests.swift`

**Interfaces:**
- Consumes: `CanonicalPath`, `DirectoryScanner`, `NoIgnoreChecker`, `DirectoryListing`, `FileTreeModel`, `DirectoryContents`, `VisibilityFilter`, `FileSystemWatcher`, `FileSystemChange`, `ExplorerStateStore`, `RootViewState`, `ExplorerError`.
- Produces:
  - `ExplorerPaths.relative(_:to:) -> String`, `ExplorerPaths.depth(_:) -> Int`
  - `enum ExplorerContext: Sendable, Equatable { case none, remote, local(root: String, projectRoot: String) }`
  - `struct ExplorerServices: Sendable { let scan: Scan; let makeWatcher: MakeWatcher; static let live }`
  - `@MainActor final class ExplorerViewModel: ObservableObject` with published `context`, `model`, `rootError`, `selection: [String]`, `filter`, `restoreToken: Int`; `var scrollOffset: Double`; and methods, each returning `Task<Void, Never>` (discardable) unless noted: `setContext(_:)`, `expand(_:)`, `refresh()`, `retry()`, `handleChange(_:)`, `reveal(_:)`; synchronous `collapse(_:)`, `collapseAll()`, `setFilter(_:)`, `persistState()`.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelExplorerTests/ExplorerViewModelTests.swift`:

```swift
import XCTest
@testable import UnpeelExplorer

private final class ScanLog: @unchecked Sendable {
    private let lock = NSLock()
    private var scanned: [String] = []

    func record(_ directory: String) {
        lock.lock(); defer { lock.unlock() }
        scanned.append(directory)
    }

    var directories: [String] {
        lock.lock(); defer { lock.unlock() }
        return scanned
    }
}

@MainActor
final class ExplorerViewModelTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "unpeel.explorer.vmtests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func services(log: ScanLog? = nil, delay: [String: TimeInterval] = [:]) -> ExplorerServices {
        ExplorerServices(
            scan: { directory, root in
                log?.record(directory)
                if let pause = delay[directory] { Thread.sleep(forTimeInterval: pause) }
                return try DirectoryScanner(ignore: NoIgnoreChecker()).scan(directory: directory, root: root)
            },
            makeWatcher: { _, _ in nil }
        )
    }

    private func makeViewModel(
        _ services: ExplorerServices? = nil,
        defaults: UserDefaults? = nil
    ) -> ExplorerViewModel {
        ExplorerViewModel(
            services: services ?? self.services(),
            stateStore: ExplorerStateStore(defaults: defaults ?? makeDefaults())
        )
    }

    private func local(_ tree: TempTree) -> ExplorerContext {
        .local(root: tree.root, projectRoot: tree.root)
    }

    private let everything = VisibilityFilter(showHidden: true, showIgnored: true)

    func testLocalContextLoadsTheRoot() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt"); try tree.dir("src")
        let viewModel = makeViewModel()

        await viewModel.setContext(local(tree)).value

        let model = try XCTUnwrap(viewModel.model)
        XCTAssertEqual(model.root, tree.root)
        XCTAssertEqual(model.visibleChildren(of: tree.root, filter: everything).map(\.name), ["src", "a.txt"])
        XCTAssertNil(viewModel.rootError)
    }

    func testRemoteAndNoneContextsHaveNoModel() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.setContext(.remote).value
        XCTAssertNil(viewModel.model)
        XCTAssertEqual(viewModel.context, .remote)

        await viewModel.setContext(.none).value
        XCTAssertNil(viewModel.model)
    }

    func testMissingRootReportsAnError() async {
        let viewModel = makeViewModel()

        await viewModel.setContext(.local(root: "/definitely/not/here", projectRoot: "/definitely")).value

        XCTAssertNil(viewModel.model)
        XCTAssertNotNil(viewModel.rootError)
    }

    func testExpandLoadsChildrenExactlyOnce() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("src/main.swift")
        let log = ScanLog()
        let viewModel = makeViewModel(services(log: log))
        await viewModel.setContext(local(tree)).value

        await viewModel.expand(tree.path("src")).value
        viewModel.collapse(tree.path("src"))
        await viewModel.expand(tree.path("src")).value

        XCTAssertEqual(log.directories, [tree.root, tree.path("src")])
        XCTAssertEqual(viewModel.model?.expanded, [tree.path("src")])
        XCTAssertEqual(
            viewModel.model?.visibleChildren(of: tree.path("src"), filter: everything).map(\.name),
            ["main.swift"]
        )
    }

    func testExpandingAFileOrUnknownPathDoesNothing() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("a.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.expand(tree.path("a.txt")).value
        await viewModel.expand(tree.path("ghost")).value

        XCTAssertEqual(viewModel.model?.expanded, [])
    }

    func testSwitchingRootsRestoresExpansionSelectionAndScroll() async throws {
        let first = try TempTree(); defer { first.remove() }
        let second = try TempTree(); defer { second.remove() }
        try first.file("src/views/App.swift")
        let defaults = makeDefaults()
        let viewModel = makeViewModel(defaults: defaults)
        await viewModel.setContext(local(first)).value
        await viewModel.expand(first.path("src")).value
        await viewModel.expand(first.path("src/views")).value
        viewModel.selection = [first.path("src/views/App.swift")]
        viewModel.scrollOffset = 120

        await viewModel.setContext(local(second)).value
        XCTAssertEqual(viewModel.model?.expanded, [])
        XCTAssertEqual(viewModel.selection, [])
        let tokenBefore = viewModel.restoreToken

        await viewModel.setContext(local(first)).value

        XCTAssertEqual(viewModel.model?.expanded, [first.path("src"), first.path("src/views")])
        XCTAssertEqual(viewModel.selection, [first.path("src/views/App.swift")])
        XCTAssertEqual(viewModel.scrollOffset, 120)
        XCTAssertGreaterThan(viewModel.restoreToken, tokenBefore)
    }

    func testRestoreSkipsFoldersThatNoLongerExist() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let other = try TempTree(); defer { other.remove() }
        try tree.dir("gone/inner"); try tree.dir("kept")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("gone")).value
        await viewModel.expand(tree.path("gone/inner")).value
        await viewModel.expand(tree.path("kept")).value
        await viewModel.setContext(local(other)).value
        try FileManager.default.removeItem(atPath: tree.path("gone"))

        await viewModel.setContext(local(tree)).value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("kept")])
    }

    func testALoadFromAPreviousRootIsDiscarded() async throws {
        let slow = try TempTree(); defer { slow.remove() }
        let fast = try TempTree(); defer { fast.remove() }
        try slow.file("slow.txt"); try fast.file("fast.txt")
        let viewModel = makeViewModel(services(delay: [slow.root: 0.4]))

        let first = viewModel.setContext(local(slow))
        // Let the slow root's scan actually start, so this exercises the
        // discard in `load`, not just the early generation check in `open`.
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = viewModel.setContext(local(fast))
        await first.value
        await second.value

        XCTAssertEqual(viewModel.model?.root, fast.root)
        XCTAssertEqual(viewModel.model?.visibleChildren(of: fast.root, filter: everything).map(\.name), ["fast.txt"])
        XCTAssertNil(viewModel.model?.directories[slow.root])
    }

    func testChangesReloadOnlyTrackedDirectories() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/old.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value
        try tree.file("new.txt"); try tree.file("sub/new.txt")

        await viewModel.handleChange(
            FileSystemChange(directories: [tree.root, tree.path("sub")], touchedGitignore: false)
        ).value

        XCTAssertEqual(viewModel.model?.visibleChildren(of: tree.root, filter: everything).map(\.name), ["sub", "new.txt"])
        XCTAssertNil(viewModel.model?.directories[tree.path("sub")])
    }

    func testGitignoreChangeRescansEveryTrackedDirectory() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt")
        let log = ScanLog()
        let viewModel = makeViewModel(services(log: log))
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("sub")).value

        await viewModel.handleChange(FileSystemChange(directories: [], touchedGitignore: true)).value

        XCTAssertEqual(log.directories, [tree.root, tree.path("sub"), tree.root, tree.path("sub")])
    }

    func testAVanishedExpandedFolderIsDropped() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("sub")).value
        try FileManager.default.removeItem(atPath: tree.path("sub"))

        await viewModel.handleChange(
            FileSystemChange(directories: [tree.root, tree.path("sub")], touchedGitignore: false)
        ).value

        XCTAssertEqual(viewModel.model?.loadedDirectories, [tree.root])
        XCTAssertEqual(viewModel.model?.expanded, [])
    }

    func testUnreadableFolderFailsInlineAndRetriesOnReExpand() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let locked = try tree.dir("locked")
        try tree.file("locked/secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.expand(locked).value
        guard case .failed? = viewModel.model?.directories[locked] else {
            return XCTFail("expected a failed directory")
        }
        XCTAssertNil(viewModel.rootError)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        viewModel.collapse(locked)
        await viewModel.expand(locked).value

        XCTAssertEqual(viewModel.model?.visibleChildren(of: locked, filter: everything).map(\.name), ["secret.txt"])
    }

    func testRevealExpandsAncestorsAndSelects() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let target = try tree.file("a/b/c.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.reveal(target).value

        XCTAssertEqual(viewModel.model?.expanded, [tree.path("a"), tree.path("a/b")])
        XCTAssertEqual(viewModel.selection, [target])
    }

    func testRevealOutsideTheRootIsIgnored() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value

        await viewModel.reveal("/etc/hosts").value

        XCTAssertEqual(viewModel.selection, [])
    }

    func testCollapseAllAndRefresh() async throws {
        let tree = try TempTree(); defer { tree.remove() }
        try tree.file("sub/a.txt")
        let viewModel = makeViewModel()
        await viewModel.setContext(local(tree)).value
        await viewModel.expand(tree.path("sub")).value
        try tree.file("sub/b.txt")

        await viewModel.refresh().value
        XCTAssertEqual(viewModel.model?.visibleChildren(of: tree.path("sub"), filter: everything).map(\.name), ["a.txt", "b.txt"])

        viewModel.collapseAll()
        XCTAssertEqual(viewModel.model?.expanded, [])
    }

    func testFilterIsPersisted() {
        let defaults = makeDefaults()
        makeViewModel(defaults: defaults).setFilter(VisibilityFilter(showHidden: true, showIgnored: true))

        XCTAssertEqual(makeViewModel(defaults: defaults).filter, VisibilityFilter(showHidden: true, showIgnored: true))
    }

    func testPathHelpers() {
        XCTAssertEqual(ExplorerPaths.relative("/r/src/a.swift", to: "/r"), "src/a.swift")
        XCTAssertEqual(ExplorerPaths.relative("/r", to: "/r"), ".")
        XCTAssertEqual(ExplorerPaths.relative("/r-other/a", to: "/r"), "/r-other/a")
        XCTAssertEqual(ExplorerPaths.depth("/r/src/a.swift"), 3)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ExplorerViewModelTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'ExplorerViewModel' in scope`.

- [ ] **Step 3: Implement**

`Sources/UnpeelExplorer/ExplorerPaths.swift`:

```swift
import Foundation

public enum ExplorerPaths {
    /// `path` relative to `base` when beneath it; otherwise `path` unchanged.
    public static func relative(_ path: String, to base: String) -> String {
        if path == base { return "." }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    public static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }
}
```

`Sources/UnpeelExplorer/ExplorerViewModel.swift`:

```swift
import Combine
import Foundation

public enum ExplorerContext: Sendable, Equatable {
    /// No session is selected.
    case none
    /// The selected session runs on another Host; its files are not local.
    case remote
    case local(root: String, projectRoot: String)
}

public struct ExplorerServices: Sendable {
    public typealias Scan = @Sendable (_ directory: String, _ root: String) throws -> DirectoryListing
    public typealias MakeWatcher = @Sendable (
        _ root: String, _ handler: @escaping FileSystemWatcher.Handler
    ) -> FileSystemWatcher?

    public let scan: Scan
    public let makeWatcher: MakeWatcher

    public init(scan: @escaping Scan, makeWatcher: @escaping MakeWatcher) {
        self.scan = scan
        self.makeWatcher = makeWatcher
    }

    public static let live = ExplorerServices(
        scan: { directory, root in try DirectoryScanner().scan(directory: directory, root: root) },
        makeWatcher: { root, handler in FileSystemWatcher(root: root, handler: handler) }
    )
}

@MainActor
public final class ExplorerViewModel: ObservableObject {
    @Published public private(set) var context: ExplorerContext = .none
    @Published public private(set) var model: FileTreeModel?
    @Published public private(set) var rootError: String?
    @Published public var selection: [String] = []
    @Published public private(set) var filter: VisibilityFilter
    /// Bumped when a root's saved view state has been re-applied, so the
    /// outline knows `scrollOffset` is now meaningful.
    @Published public private(set) var restoreToken = 0
    public var scrollOffset: Double = 0

    private let services: ExplorerServices
    private let stateStore: ExplorerStateStore
    private var watcher: FileSystemWatcher?
    /// Bumped on every context change; a load that finishes under an older
    /// generation belongs to a root that is no longer shown.
    private var generation = 0
    private var isRestoring = false

    public init(services: ExplorerServices = .live, stateStore: ExplorerStateStore) {
        self.services = services
        self.stateStore = stateStore
        filter = stateStore.filter
    }

    // MARK: - Context

    @discardableResult
    public func setContext(_ next: ExplorerContext) -> Task<Void, Never> {
        guard next != context else { return Task {} }
        persistState()
        teardown()
        context = next
        let current = generation
        return Task { await self.open(next, generation: current) }
    }

    @discardableResult
    public func retry() -> Task<Void, Never> {
        let current = context
        teardown()
        let next = generation
        return Task { await self.open(current, generation: next) }
    }

    private func teardown() {
        generation += 1
        watcher?.stop()
        watcher = nil
        model = nil
        rootError = nil
        selection = []
        scrollOffset = 0
    }

    private func open(_ context: ExplorerContext, generation current: Int) async {
        guard current == generation, case .local(let requestedRoot, _) = context else { return }
        guard let root = CanonicalPath.resolve(requestedRoot) else {
            rootError = ExplorerError.rootUnavailable(requestedRoot).localizedDescription
            return
        }
        model = FileTreeModel(root: root).settingContents(.loading, for: root)
        startWatcher(root: root)
        await load(root, generation: current)
        await restoreState(root: root, generation: current)
    }

    private func startWatcher(root: String) {
        watcher = services.makeWatcher(root) { [weak self] change in
            Task { @MainActor [weak self] in
                self?.handleChange(change)
            }
        }
        watcher?.start()
    }

    // MARK: - Loading

    private func load(_ directory: String, generation current: Int) async {
        guard let root = model?.root else { return }
        let scan = services.scan
        let result: Result<DirectoryListing, any Error> = await Task.detached(priority: .userInitiated) {
            Result { try scan(directory, root) }
        }.value
        guard current == generation, let model, model.directories[directory] != nil else { return }
        switch result {
        case .success(let listing):
            self.model = model.settingContents(.loaded(listing), for: directory)
        case .failure(let error) where directory == model.root:
            self.model = nil
            rootError = error.localizedDescription
        case .failure(let error):
            self.model = model.settingContents(.failed(error.localizedDescription), for: directory)
        }
    }

    private func reload(_ directories: Set<String>) async {
        let current = generation
        for directory in directories.sorted(by: { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }) {
            await load(directory, generation: current)
        }
    }

    // MARK: - Expansion

    @discardableResult
    public func expand(_ path: String) -> Task<Void, Never> {
        guard let model, model.entry(at: path)?.isExpandable == true else { return Task {} }
        let expanded = model.expanding(path)
        switch expanded.directories[path] {
        case .loaded?, .loading?:
            self.model = expanded
            persistState()
            return Task {}
        case .failed?, nil:
            self.model = expanded.settingContents(.loading, for: path)
            let current = generation
            return Task {
                await self.load(path, generation: current)
                self.persistState()
            }
        }
    }

    public func collapse(_ path: String) {
        guard let model else { return }
        self.model = model.collapsing(path)
        persistState()
    }

    public func collapseAll() {
        guard let model else { return }
        self.model = model.collapsingAll()
        persistState()
    }

    // MARK: - Refresh

    @discardableResult
    public func refresh() -> Task<Void, Never> {
        guard let model else { return Task {} }
        let tracked = Set(model.directories.keys)
        return Task { await self.reload(tracked) }
    }

    @discardableResult
    public func handleChange(_ change: FileSystemChange) -> Task<Void, Never> {
        guard let model else { return Task {} }
        let tracked = Set(model.directories.keys)
        let targets = change.touchedGitignore ? tracked : tracked.intersection(change.directories)
        guard !targets.isEmpty else { return Task {} }
        return Task { await self.reload(targets) }
    }

    // MARK: - Reveal

    @discardableResult
    public func reveal(_ path: String) -> Task<Void, Never> {
        guard let root = model?.root, path.hasPrefix(root + "/") else { return Task {} }
        let components = ExplorerPaths.relative(path, to: root).split(separator: "/").dropLast()
        let ancestors = components.indices.map { index in
            root + "/" + components[...index].joined(separator: "/")
        }
        return Task {
            for ancestor in ancestors { await self.expand(ancestor).value }
            if self.model?.entry(at: path) != nil { self.selection = [path] }
        }
    }

    // MARK: - Filter and persistence

    public func setFilter(_ next: VisibilityFilter) {
        filter = next
        stateStore.filter = next
    }

    public func persistState() {
        guard !isRestoring, let model else { return }
        stateStore.save(
            RootViewState(expanded: model.expanded.sorted(), selection: selection, scrollOffset: scrollOffset),
            forRoot: model.root
        )
    }

    private func restoreState(root: String, generation current: Int) async {
        guard current == generation, let saved = stateStore.state(forRoot: root) else { return }
        isRestoring = true
        defer { isRestoring = false }
        let shallowFirst = saved.expanded.sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
        for path in shallowFirst {
            guard current == generation else { return }
            await expand(path).value
        }
        guard current == generation, let model else { return }
        selection = saved.selection.filter { model.entry(at: $0) != nil }
        scrollOffset = saved.scrollOffset
        restoreToken += 1
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ExplorerViewModelTests 2>&1 | tail -30`
Expected: `Executed 17 tests, with 0 failures`.

If Swift 6 rejects `components[...index]` on the `dropLast()` slice, materialise first: `let components = Array(ExplorerPaths.relative(path, to: root).split(separator: "/").dropLast())`.

- [ ] **Step 5: Run the whole library suite, then commit**

Run: `swift test --filter UnpeelExplorerTests 2>&1 | tail -5`
Expected: all tests pass, 0 failures.

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerPaths.swift clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerViewModel.swift clients/native/UnpeelNative/Tests/UnpeelExplorerTests/ExplorerViewModelTests.swift
git commit -m "feat: add explorer view model with lazy loading and state restore"
```

---

### Task 7: Outline controller, key commands, icons

**Files:**
- Create: `Sources/UnpeelExplorer/ExplorerKeyCommand.swift`, `Sources/UnpeelExplorer/ExplorerItem.swift`, `Sources/UnpeelExplorer/FileIconProvider.swift`, `Sources/UnpeelExplorer/ExplorerPalette.swift`, `Sources/UnpeelExplorer/ExplorerOutlineController.swift`, `Sources/UnpeelExplorer/ExplorerNSOutlineView.swift`
- Test: `Tests/UnpeelExplorerTests/ExplorerKeyCommandTests.swift`, `Tests/UnpeelExplorerTests/ExplorerOutlineControllerTests.swift`

**Interfaces:**
- Consumes: `ExplorerViewModel`, `FileTreeModel`, `VisibilityFilter`, `FileEntry`, `ExplorerPaths`.
- Produces:
  - `enum ExplorerKeyCommand { quickLook, open, expandOrDescend, collapseOrAscend, copyPath, copyRelativePath, revealInFinder }` + `static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ExplorerKeyCommand?`
  - `final class ExplorerItem: NSObject` with `path`, `role: Role` (`.entry` / `.note(String)`)
  - `@MainActor protocol ExplorerActionHandler: AnyObject { var canSendToAgent: Bool { get }; func openInEditor(path: String); func sendPathToAgent(path: String) }`
  - `@MainActor struct ExplorerPalette { text, secondaryText: NSColor; rowFont: NSFont; static var system }`
  - `@MainActor final class ExplorerOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate` with `init(viewModel:palette:)`, `attach(to:)`, `apply(model:filter:selection:)`, `children(of:) -> [ExplorerItem]`, `menuActions(for: String?) -> [MenuAction?]`, `perform(_:on:)`, `handleKeyCommand(_:) -> Bool`, `var pasteboard: NSPasteboard`, `weak var actionHandler`
  - `@MainActor final class ExplorerNSOutlineView: NSOutlineView` with `keyCommandHandler`, `previewPaths`, `toggleQuickLook()`

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelExplorerTests/ExplorerKeyCommandTests.swift`:

```swift
import AppKit
import XCTest
@testable import UnpeelExplorer

final class ExplorerKeyCommandTests: XCTestCase {
    func testPlainKeys() {
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 49, modifiers: []), .quickLook)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 124, modifiers: []), .expandOrDescend)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 123, modifiers: []), .collapseOrAscend)
    }

    func testArrowKeysCarryNumericPadAndFunctionFlags() {
        XCTAssertEqual(
            ExplorerKeyCommand.from(keyCode: 124, modifiers: [.numericPad, .function]),
            .expandOrDescend
        )
    }

    func testCommandCombinations() {
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 125, modifiers: [.command]), .open)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 8, modifiers: [.command, .option]), .copyPath)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 8, modifiers: [.command, .option, .shift]), .copyRelativePath)
        XCTAssertEqual(ExplorerKeyCommand.from(keyCode: 15, modifiers: [.command, .option]), .revealInFinder)
    }

    func testUnmappedKeysFallThrough() {
        XCTAssertNil(ExplorerKeyCommand.from(keyCode: 125, modifiers: []))
        XCTAssertNil(ExplorerKeyCommand.from(keyCode: 49, modifiers: [.shift]))
        XCTAssertNil(ExplorerKeyCommand.from(keyCode: 8, modifiers: [.command]))
    }
}
```

`Tests/UnpeelExplorerTests/ExplorerOutlineControllerTests.swift`:

```swift
import AppKit
import XCTest
@testable import UnpeelExplorer

@MainActor
private final class RecordingHandler: ExplorerActionHandler {
    var canSendToAgent = true
    var opened: [String] = []
    var sent: [String] = []
    func openInEditor(path: String) { opened.append(path) }
    func sendPathToAgent(path: String) { sent.append(path) }
}

@MainActor
final class ExplorerOutlineControllerTests: XCTestCase {
    private let root = "/r"

    private func makeController() -> (ExplorerOutlineController, ExplorerViewModel, String) {
        let suite = "unpeel.explorer.outlinetests.\(UUID().uuidString)"
        let viewModel = ExplorerViewModel(
            services: ExplorerServices(scan: { _, _ in DirectoryListing(entries: []) }, makeWatcher: { _, _ in nil }),
            stateStore: ExplorerStateStore(defaults: UserDefaults(suiteName: suite)!)
        )
        return (ExplorerOutlineController(viewModel: viewModel, palette: .system), viewModel, suite)
    }

    private func sampleModel(truncated: Int = 0) -> FileTreeModel {
        FileTreeModel(root: root)
            .settingContents(
                .loaded(DirectoryListing(
                    entries: [
                        FileEntry(path: "/r/src", name: "src", kind: .directory),
                        FileEntry(path: "/r/.env", name: ".env", kind: .file, isHidden: true),
                        FileEntry(path: "/r/a.txt", name: "a.txt", kind: .file),
                    ],
                    truncatedCount: truncated
                )),
                for: root
            )
            .settingContents(.failed("Permission denied"), for: "/r/src")
            .expanding("/r/src")
    }

    func testChildrenFollowTheFilter() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        XCTAssertEqual(controller.children(of: root).map(\.path), ["/r/src", "/r/a.txt"])

        controller.apply(model: sampleModel(), filter: VisibilityFilter(showHidden: true), selection: [])
        XCTAssertEqual(controller.children(of: root).map(\.path), ["/r/src", "/r/.env", "/r/a.txt"])
    }

    func testTruncatedAndFailedDirectoriesGetANoteRow() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        controller.apply(model: sampleModel(truncated: 12), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.children(of: root).last?.role, .note("… 12 more items not shown"))
        XCTAssertEqual(controller.children(of: "/r/src").map(\.role), [.note("Permission denied")])
    }

    func testItemsKeepTheirIdentityAcrossReloads() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        let before = controller.children(of: root).first

        let grown = sampleModel().settingContents(
            .loaded(DirectoryListing(entries: [
                FileEntry(path: "/r/src", name: "src", kind: .directory),
                FileEntry(path: "/r/a.txt", name: "a.txt", kind: .file),
                FileEntry(path: "/r/b.txt", name: "b.txt", kind: .file),
            ])),
            for: root
        )
        controller.apply(model: grown, filter: VisibilityFilter(), selection: [])

        XCTAssertTrue(before === controller.children(of: root).first)
        XCTAssertEqual(controller.children(of: root).count, 3)
    }

    func testDataSourceAnswersForAnAttachedOutlineView() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let outline = ExplorerNSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        controller.attach(to: outline)

        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.outlineView(outline, numberOfChildrenOfItem: nil), 2)
        let first = controller.outlineView(outline, child: 0, ofItem: nil)
        XCTAssertEqual((first as? ExplorerItem)?.path, "/r/src")
        XCTAssertTrue(controller.outlineView(outline, isItemExpandable: first))
        let second = controller.outlineView(outline, child: 1, ofItem: nil)
        XCTAssertFalse(controller.outlineView(outline, isItemExpandable: second))
    }

    func testMenuActionsDependOnTheTarget() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        XCTAssertEqual(controller.menuActions(for: nil), [.refresh])
        XCTAssertEqual(
            controller.menuActions(for: "/r/a.txt"),
            [.openInEditor, .revealInFinder, .quickLook, nil, .sendToAgent, nil, .copyPath, .copyRelativePath, nil, .refresh]
        )
        XCTAssertEqual(
            controller.menuActions(for: "/r/src"),
            [.revealInFinder, nil, .sendToAgent, nil, .copyPath, .copyRelativePath, nil, .refresh, .collapse]
        )

        handler.canSendToAgent = false
        XCTAssertFalse(controller.menuActions(for: "/r/a.txt").contains(.sendToAgent))
    }

    func testPerformRoutesToTheHandlerAndPasteboard() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        controller.actionHandler = handler
        controller.pasteboard = pasteboard
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.perform(.openInEditor, on: ["/r/a.txt"])
        controller.perform(.sendToAgent, on: ["/r/a.txt"])
        XCTAssertEqual(handler.opened, ["/r/a.txt"])
        XCTAssertEqual(handler.sent, ["/r/a.txt"])

        controller.perform(.copyPath, on: ["/r/a.txt", "/r/src"])
        XCTAssertEqual(pasteboard.string(forType: .string), "/r/a.txt\n/r/src")

        controller.perform(.copyRelativePath, on: ["/r/a.txt"])
        XCTAssertEqual(pasteboard.string(forType: .string), "a.txt")
    }

    func testOpenKeyCommandOpensSelectedFiles() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])
        viewModel.selection = ["/r/a.txt"]

        XCTAssertTrue(controller.handleKeyCommand(.open))
        XCTAssertEqual(handler.opened, ["/r/a.txt"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "ExplorerKeyCommandTests|ExplorerOutlineControllerTests" 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'ExplorerKeyCommand' in scope`.

- [ ] **Step 3: Implement the small types**

`Sources/UnpeelExplorer/ExplorerKeyCommand.swift`:

```swift
import AppKit

/// Keys the explorer handles itself; everything else (↑ ↓, type-select,
/// ⌘A…) stays with `NSOutlineView`.
public enum ExplorerKeyCommand: Equatable, Sendable {
    case quickLook
    case open
    case expandOrDescend
    case collapseOrAscend
    case copyPath
    case copyRelativePath
    case revealInFinder

    public static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ExplorerKeyCommand? {
        // Arrow keys always carry .numericPad/.function; only these four matter.
        let flags = modifiers.intersection([.command, .option, .shift, .control])
        if flags.isEmpty {
            switch keyCode {
            case 49: return .quickLook
            case 124: return .expandOrDescend
            case 123: return .collapseOrAscend
            default: return nil
            }
        }
        if flags == [.command], keyCode == 125 { return .open }
        if flags == [.command, .option], keyCode == 8 { return .copyPath }
        if flags == [.command, .option, .shift], keyCode == 8 { return .copyRelativePath }
        if flags == [.command, .option], keyCode == 15 { return .revealInFinder }
        return nil
    }
}
```

`Sources/UnpeelExplorer/ExplorerItem.swift`:

```swift
import AppKit

/// `NSOutlineView` tracks expansion and selection by item identity, so each
/// path maps to one long-lived object rather than a fresh value per reload.
public final class ExplorerItem: NSObject {
    public enum Role: Equatable {
        case entry
        /// A non-interactive line: a load failure or "… N more items".
        case note(String)
    }

    public let path: String
    public let role: Role

    public init(path: String, role: Role) {
        self.path = path
        self.role = role
    }

    public override func isEqual(_ object: Any?) -> Bool {
        (object as? ExplorerItem)?.path == path
    }

    public override var hash: Int { path.hashValue }
}
```

`Sources/UnpeelExplorer/FileIconProvider.swift`:

```swift
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
```

`Sources/UnpeelExplorer/ExplorerPalette.swift`:

```swift
import AppKit

/// Colours and fonts injected by the app so the library matches the sidebar
/// without importing the app's theme.
@MainActor
public struct ExplorerPalette {
    public let text: NSColor
    public let secondaryText: NSColor
    public let rowFont: NSFont

    public init(text: NSColor, secondaryText: NSColor, rowFont: NSFont) {
        self.text = text
        self.secondaryText = secondaryText
        self.rowFont = rowFont
    }

    public static var system: ExplorerPalette {
        ExplorerPalette(
            text: .labelColor,
            secondaryText: .secondaryLabelColor,
            rowFont: .systemFont(ofSize: 13, weight: .medium)
        )
    }
}

/// What the explorer cannot do on its own; implemented by the host app.
@MainActor
public protocol ExplorerActionHandler: AnyObject {
    var canSendToAgent: Bool { get }
    func openInEditor(path: String)
    func sendPathToAgent(path: String)
}
```

- [ ] **Step 4: Implement the outline view subclass**

`Sources/UnpeelExplorer/ExplorerNSOutlineView.swift`:

```swift
import AppKit
import Quartz

@MainActor
public final class ExplorerNSOutlineView: NSOutlineView, @preconcurrency QLPreviewPanelDataSource {
    public var keyCommandHandler: ((ExplorerKeyCommand) -> Bool)?
    public var previewPaths: () -> [String] = { [] }

    public override func keyDown(with event: NSEvent) {
        if let command = ExplorerKeyCommand.from(keyCode: event.keyCode, modifiers: event.modifierFlags),
           keyCommandHandler?(command) == true {
            return
        }
        super.keyDown(with: event)
    }

    public func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool { true }

    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    public func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        previewPaths().count
    }

    public func previewPanel(_: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let paths = previewPaths()
        guard paths.indices.contains(index) else { return nil }
        return NSURL(fileURLWithPath: paths[index])
    }
}
```

- [ ] **Step 5: Implement the controller**

`Sources/UnpeelExplorer/ExplorerOutlineController.swift`:

```swift
import AppKit

@MainActor
public final class ExplorerOutlineController: NSObject,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate
{
    public enum MenuAction: String, Equatable {
        case openInEditor, revealInFinder, quickLook, sendToAgent
        case copyPath, copyRelativePath, refresh, collapse

        var title: String {
            switch self {
            case .openInEditor: return "Open in Editor"
            case .revealInFinder: return "Reveal in Finder"
            case .quickLook: return "Quick Look"
            case .sendToAgent: return "Send Path to Agent"
            case .copyPath: return "Copy Path"
            case .copyRelativePath: return "Copy Relative Path"
            case .refresh: return "Refresh"
            case .collapse: return "Collapse"
            }
        }
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("unpeel.explorer.cell")
    private static let noteSuffix = "/\u{0}note"

    public let viewModel: ExplorerViewModel
    public weak var actionHandler: (any ExplorerActionHandler)?
    public var palette: ExplorerPalette
    public var pasteboard: NSPasteboard = .general
    public private(set) weak var outlineView: ExplorerNSOutlineView?

    private let icons = FileIconProvider()
    private var items: [String: ExplorerItem] = [:]
    private var childCache: [String: [ExplorerItem]] = [:]
    private var applied: FileTreeModel?
    private var appliedFilter = VisibilityFilter()
    private var appliedRestoreToken = 0
    /// True while this controller changes the outline view itself, so its
    /// delegate callbacks are not echoed back into the view model.
    private var isApplying = false

    public init(viewModel: ExplorerViewModel, palette: ExplorerPalette) {
        self.viewModel = viewModel
        self.palette = palette
        super.init()
    }

    public func attach(to outlineView: ExplorerNSOutlineView) {
        self.outlineView = outlineView
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(handleClick)
        outlineView.doubleAction = #selector(handleDoubleClick)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.keyCommandHandler = { [weak self] in self?.handleKeyCommand($0) ?? false }
        outlineView.previewPaths = { [weak self] in self?.selectedFilePaths() ?? [] }
    }

    // MARK: - Applying model changes

    public func apply(model: FileTreeModel?, filter: VisibilityFilter, selection: [String]) {
        isApplying = true
        defer { isApplying = false }
        let previous = applied
        let previousFilter = appliedFilter
        applied = model
        appliedFilter = filter
        guard let model else {
            items = [:]
            childCache = [:]
            outlineView?.reloadData()
            return
        }
        if previous?.root != model.root || previousFilter != filter {
            items = [:]
            childCache = [:]
            outlineView?.reloadData()
        } else if let previous {
            let changed = Set(previous.directories.keys).union(model.directories.keys)
                .filter { previous.directories[$0] != model.directories[$0] }
                .sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
            for directory in changed {
                childCache[directory] = nil
                if directory == model.root {
                    outlineView?.reloadItem(nil, reloadChildren: true)
                } else if let item = items[directory] {
                    outlineView?.reloadItem(item, reloadChildren: true)
                }
            }
        }
        syncExpansion(model)
        syncSelection(selection)
    }

    /// Scrolls to the view model's restored offset once per restore.
    public func applyRestoredScrollIfNeeded() {
        guard viewModel.restoreToken != appliedRestoreToken,
              let clipView = outlineView?.enclosingScrollView?.contentView
        else { return }
        appliedRestoreToken = viewModel.restoreToken
        clipView.scroll(to: NSPoint(x: 0, y: viewModel.scrollOffset))
        outlineView?.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    public func noteScrolled(to offset: Double) {
        guard !isApplying else { return }
        viewModel.scrollOffset = offset
    }

    private func syncExpansion(_ model: FileTreeModel) {
        guard let outlineView else { return }
        let shallowFirst = model.expanded.sorted { ExplorerPaths.depth($0) < ExplorerPaths.depth($1) }
        for path in shallowFirst {
            guard let item = items[path], outlineView.row(forItem: item) >= 0,
                  !outlineView.isItemExpanded(item)
            else { continue }
            outlineView.expandItem(item)
        }
        var row = 0
        while row < outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? ExplorerItem,
               outlineView.isItemExpanded(item), !model.expanded.contains(item.path) {
                outlineView.collapseItem(item)
            }
            row += 1
        }
    }

    private func syncSelection(_ selection: [String]) {
        guard let outlineView else { return }
        let rows = IndexSet(
            selection.compactMap { items[$0] }.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 }
        )
        guard rows != outlineView.selectedRowIndexes else { return }
        outlineView.selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: - Rows

    public func children(of directory: String) -> [ExplorerItem] {
        if let cached = childCache[directory] { return cached }
        guard let model = applied else { return [] }
        let entries = model.visibleChildren(of: directory, filter: appliedFilter)
            .map { item(for: $0.path, role: .entry) }
        let built = entries + noteRows(for: directory, in: model)
        childCache[directory] = built
        return built
    }

    private func noteRows(for directory: String, in model: FileTreeModel) -> [ExplorerItem] {
        if case .failed(let message)? = model.directories[directory] {
            return [item(for: directory + Self.noteSuffix, role: .note(message))]
        }
        let hidden = model.truncatedCount(of: directory)
        guard hidden > 0 else { return [] }
        return [item(for: directory + Self.noteSuffix, role: .note("… \(hidden) more items not shown"))]
    }

    private func item(for path: String, role: ExplorerItem.Role) -> ExplorerItem {
        if let existing = items[path], existing.role == role { return existing }
        let created = ExplorerItem(path: path, role: role)
        items[path] = created
        return created
    }

    private func directoryPath(of item: Any?) -> String {
        (item as? ExplorerItem)?.path ?? applied?.root ?? ""
    }

    private func entry(for item: Any?) -> FileEntry? {
        guard let item = item as? ExplorerItem, item.role == .entry else { return nil }
        return applied?.entry(at: item.path)
    }

    // MARK: - NSOutlineViewDataSource

    public func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: directoryPath(of: item)).count
    }

    public func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: directoryPath(of: item))[index]
    }

    public func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        entry(for: item)?.isExpandable ?? false
    }

    public func outlineView(_: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let entry = entry(for: item) else { return nil }
        return NSURL(fileURLWithPath: entry.path)
    }

    // MARK: - NSOutlineViewDelegate

    public func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? ExplorerItem else { return nil }
        let cell = (outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView)
            ?? Self.makeCell()
        cell.textField?.font = palette.rowFont
        switch item.role {
        case .note(let text):
            cell.imageView?.image = nil
            cell.textField?.stringValue = text
            cell.textField?.textColor = palette.secondaryText
            cell.alphaValue = 1
        case .entry:
            let entry = applied?.entry(at: item.path)
            cell.imageView?.image = entry.map(icons.icon(for:))
            cell.textField?.stringValue = entry?.name ?? (item.path as NSString).lastPathComponent
            cell.textField?.textColor = palette.text
            cell.alphaValue = (entry?.isIgnored == true || entry?.isHidden == true) ? 0.5 : 1
            cell.toolTip = entry?.isSymlink == true && entry?.isExpandable == false && entry?.kind == .directory
                ? "This link points outside the project folder."
                : nil
        }
        return cell
    }

    public func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? ExplorerItem)?.role == .entry
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isApplying, let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
        viewModel.expand(item.path)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplying, let item = notification.userInfo?["NSObject"] as? ExplorerItem else { return }
        viewModel.collapse(item.path)
    }

    public func outlineViewSelectionDidChange(_: Notification) {
        guard !isApplying else { return }
        viewModel.selection = selectedPaths()
    }

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellIdentifier
        let image = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Selection helpers

    private func selectedPaths() -> [String] {
        guard let outlineView else { return viewModel.selection }
        return outlineView.selectedRowIndexes.compactMap {
            (outlineView.item(atRow: $0) as? ExplorerItem)?.path
        }
    }

    private func selectedFilePaths() -> [String] {
        viewModel.selection.filter { applied?.entry(at: $0)?.kind == .file }
    }

    /// The clicked row if it is outside the selection, else the selection.
    private func menuTargetPaths() -> [String] {
        guard let outlineView, outlineView.clickedRow >= 0,
              let clicked = outlineView.item(atRow: outlineView.clickedRow) as? ExplorerItem,
              clicked.role == .entry
        else { return [] }
        let selection = selectedPaths()
        return selection.contains(clicked.path) ? selection : [clicked.path]
    }

    // MARK: - Clicks

    @objc private func handleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let item = outlineView.item(atRow: outlineView.clickedRow) as? ExplorerItem,
              entry(for: item)?.isExpandable == true
        else { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        guard modifiers.intersection([.command, .shift]).isEmpty else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    @objc private func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let entry = entry(for: outlineView.item(atRow: outlineView.clickedRow)),
              entry.kind == .file
        else { return }
        actionHandler?.openInEditor(path: entry.path)
    }

    // MARK: - Context menu

    public func menuActions(for path: String?) -> [MenuAction?] {
        guard let path, let entry = applied?.entry(at: path) else { return [.refresh] }
        let send: [MenuAction?] = actionHandler?.canSendToAgent == true ? [.sendToAgent, nil] : []
        let copy: [MenuAction?] = [.copyPath, .copyRelativePath, nil]
        if entry.kind == .file {
            return [.openInEditor, .revealInFinder, .quickLook, nil] + send + copy + [.refresh]
        }
        let collapse: [MenuAction?] = applied?.expanded.contains(path) == true ? [.collapse] : []
        return [.revealInFinder, nil] + send + copy + [.refresh] + collapse
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for action in menuActions(for: menuTargetPaths().first) {
            guard let action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: action.title, action: #selector(performMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MenuAction(rawValue: raw) else { return }
        perform(action, on: menuTargetPaths())
    }

    public func perform(_ action: MenuAction, on paths: [String]) {
        switch action {
        case .openInEditor:
            paths.forEach { actionHandler?.openInEditor(path: $0) }
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        case .quickLook:
            viewModel.selection = paths
            outlineView?.toggleQuickLook()
        case .sendToAgent:
            paths.forEach { actionHandler?.sendPathToAgent(path: $0) }
        case .copyPath:
            copyToPasteboard(paths)
        case .copyRelativePath:
            let root = applied?.root ?? ""
            copyToPasteboard(paths.map { ExplorerPaths.relative($0, to: root) })
        case .refresh:
            viewModel.refresh()
        case .collapse:
            paths.forEach { path in
                if let item = items[path] { outlineView?.collapseItem(item) }
                viewModel.collapse(path)
            }
        }
    }

    private func copyToPasteboard(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Keyboard

    public func handleKeyCommand(_ command: ExplorerKeyCommand) -> Bool {
        let selection = viewModel.selection
        guard !selection.isEmpty else { return false }
        switch command {
        case .quickLook:
            outlineView?.toggleQuickLook()
        case .open:
            for path in selection {
                guard let entry = applied?.entry(at: path) else { continue }
                if entry.kind == .file {
                    actionHandler?.openInEditor(path: path)
                } else if let item = items[path] {
                    outlineView?.expandItem(item)
                }
            }
        case .expandOrDescend:
            return expandOrDescend(selection)
        case .collapseOrAscend:
            return collapseOrAscend(selection)
        case .copyPath:
            perform(.copyPath, on: selection)
        case .copyRelativePath:
            perform(.copyRelativePath, on: selection)
        case .revealInFinder:
            perform(.revealInFinder, on: selection)
        }
        return true
    }

    private func expandOrDescend(_ selection: [String]) -> Bool {
        guard let outlineView, selection.count == 1, let item = items[selection[0]],
              entry(for: item)?.isExpandable == true
        else { return false }
        if !outlineView.isItemExpanded(item) {
            outlineView.expandItem(item)
        } else if let first = children(of: item.path).first, first.role == .entry {
            select(first)
        }
        return true
    }

    private func collapseOrAscend(_ selection: [String]) -> Bool {
        guard let outlineView, selection.count == 1, let item = items[selection[0]] else { return false }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else if let parent = outlineView.parent(forItem: item) as? ExplorerItem {
            select(parent)
        }
        return true
    }

    private func select(_ item: ExplorerItem) {
        guard let outlineView else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }
}
```

- [ ] **Step 6: Run to verify pass**

Run: `swift test --filter "ExplorerKeyCommandTests|ExplorerOutlineControllerTests" 2>&1 | tail -30`
Expected: `Executed 11 tests, with 0 failures`.

Known Swift 6 friction, with the accepted fix for each:
- If the compiler rejects `@preconcurrency QLPreviewPanelDataSource` on the class declaration, move the two data-source methods into `extension ExplorerNSOutlineView: @preconcurrency QLPreviewPanelDataSource { … }`.
- If `notification.userInfo?["NSObject"]` warns about sendability, keep it — the value is only read on the main actor.

- [ ] **Step 7: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer clients/native/UnpeelNative/Tests/UnpeelExplorerTests
git commit -m "feat: add NSOutlineView controller, key commands and context menu"
```

---

### Task 8: SwiftUI panel

**Files:**
- Create: `Sources/UnpeelExplorer/ExplorerOutlineView.swift`, `Sources/UnpeelExplorer/ExplorerPanelView.swift`
- Test: `Tests/UnpeelExplorerTests/ExplorerPanelViewTests.swift`

**Interfaces:**
- Consumes: `ExplorerViewModel`, `ExplorerOutlineController`, `ExplorerNSOutlineView`, `ExplorerPalette`, `ExplorerActionHandler`, `ExplorerContext`.
- Produces: `public struct ExplorerPanelView: View` with `init(viewModel:palette:actionHandler:)`, plus pure statics `ExplorerPanelView.title(for: ExplorerContext) -> String` and `ExplorerPanelView.message(for: ExplorerContext, rootError: String?) -> String?`.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelExplorerTests/ExplorerPanelViewTests.swift`:

```swift
import XCTest
@testable import UnpeelExplorer

@MainActor
final class ExplorerPanelViewTests: XCTestCase {
    func testTitleIsTheRootFolderNameUppercased() {
        XCTAssertEqual(ExplorerPanelView.title(for: .local(root: "/Users/me/my-proj", projectRoot: "/Users/me/my-proj")), "MY-PROJ")
        XCTAssertEqual(ExplorerPanelView.title(for: .none), "EXPLORER")
        XCTAssertEqual(ExplorerPanelView.title(for: .remote), "EXPLORER")
    }

    func testEmptyStateMessages() {
        XCTAssertEqual(
            ExplorerPanelView.message(for: .none, rootError: nil),
            "Select a session to browse its files."
        )
        XCTAssertEqual(
            ExplorerPanelView.message(for: .remote, rootError: nil),
            "The explorer is available for sessions running on this Mac."
        )
        XCTAssertNil(ExplorerPanelView.message(for: .local(root: "/r", projectRoot: "/r"), rootError: nil))
        XCTAssertEqual(
            ExplorerPanelView.message(for: .local(root: "/r", projectRoot: "/r"), rootError: "Gone"),
            "Gone"
        )
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ExplorerPanelViewTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'ExplorerPanelView' in scope`.

- [ ] **Step 3: Implement**

`Sources/UnpeelExplorer/ExplorerOutlineView.swift`:

```swift
import AppKit
import SwiftUI

struct ExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var viewModel: ExplorerViewModel
    let palette: ExplorerPalette
    let actionHandler: (any ExplorerActionHandler)?

    func makeCoordinator() -> ExplorerOutlineController {
        ExplorerOutlineController(viewModel: viewModel, palette: palette)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = ExplorerNSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.style = .fullWidth
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autosaveExpandedItems = false
        // The terminal panes live in this same app, so the local mask matters
        // as much as the external one for "drag a row onto a terminal".
        outline.setDraggingSourceOperationMask([.copy, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .generic, .link], forLocal: false)
        context.coordinator.attach(to: outline)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak coordinator, weak scroll] _ in
            MainActor.assumeIsolated {
                guard let scroll else { return }
                coordinator?.noteScrolled(to: Double(scroll.contentView.bounds.origin.y))
            }
        }
        return scroll
    }

    func updateNSView(_: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.actionHandler = actionHandler
        coordinator.palette = palette
        coordinator.apply(model: viewModel.model, filter: viewModel.filter, selection: viewModel.selection)
        coordinator.applyRestoredScrollIfNeeded()
    }
}
```

`Sources/UnpeelExplorer/ExplorerPanelView.swift`:

```swift
import AppKit
import SwiftUI

public struct ExplorerPanelView: View {
    @ObservedObject private var viewModel: ExplorerViewModel
    private let palette: ExplorerPalette
    private let actionHandler: (any ExplorerActionHandler)?

    public init(
        viewModel: ExplorerViewModel,
        palette: ExplorerPalette,
        actionHandler: (any ExplorerActionHandler)?
    ) {
        self.viewModel = viewModel
        self.palette = palette
        self.actionHandler = actionHandler
    }

    public static func title(for context: ExplorerContext) -> String {
        guard case .local(let root, _) = context else { return "EXPLORER" }
        return (root as NSString).lastPathComponent.uppercased()
    }

    public static func message(for context: ExplorerContext, rootError: String?) -> String? {
        switch context {
        case .none: return "Select a session to browse its files."
        case .remote: return "The explorer is available for sessions running on this Mac."
        case .local: return rootError
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let message = Self.message(for: viewModel.context, rootError: viewModel.rootError) {
                emptyState(message)
            } else {
                ExplorerOutlineView(viewModel: viewModel, palette: palette, actionHandler: actionHandler)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(Self.title(for: viewModel.context))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: palette.secondaryText))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Menu {
                Button("Refresh") { viewModel.refresh() }
                Button("Collapse All") { viewModel.collapseAll() }
                Divider()
                Toggle("Show Hidden Files", isOn: filterBinding(\.showHidden) {
                    VisibilityFilter(showHidden: $0, showIgnored: viewModel.filter.showIgnored)
                })
                Toggle("Show Git-Ignored Files", isOn: filterBinding(\.showIgnored) {
                    VisibilityFilter(showHidden: viewModel.filter.showHidden, showIgnored: $0)
                })
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(Color(nsColor: palette.secondaryText))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(viewModel.model == nil)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func filterBinding(
        _ keyPath: KeyPath<VisibilityFilter, Bool>,
        _ make: @escaping (Bool) -> VisibilityFilter
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.filter[keyPath: keyPath] },
            set: { viewModel.setFilter(make($0)) }
        )
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: palette.secondaryText))
                .multilineTextAlignment(.center)
            if viewModel.rootError != nil {
                Button("Retry") { viewModel.retry() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter UnpeelExplorerTests 2>&1 | tail -10`
Expected: every `UnpeelExplorerTests` test passes, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer clients/native/UnpeelNative/Tests/UnpeelExplorerTests/ExplorerPanelViewTests.swift
git commit -m "feat: add SwiftUI explorer panel around the outline view"
```

---

### Task 9: Wire the panel into the Mac app

**Files:**
- Create: `Sources/UnpeelNative/ExplorerPanelState.swift`, `Sources/UnpeelNative/ExplorerContextResolver.swift`, `Sources/UnpeelNative/Views/ExplorerPanelHost.swift`
- Modify: `Sources/UnpeelNative/Views/RootView.swift` (state declarations near line 40; `appLayout` HStack near lines 221–286; overlays near line 311), `Sources/UnpeelNative/AppDelegate.swift` (View menu near line 552; menu actions near line 672; `validateMenuItem` near line 734)
- Test: `Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift`, `Tests/UnpeelNativeTests/ExplorerPanelStateTests.swift`

**Interfaces:**
- Consumes (library): `ExplorerPanelView`, `ExplorerViewModel`, `ExplorerStateStore`, `ExplorerPalette`, `ExplorerActionHandler`, `ExplorerContext`, `ExplorerPaths`.
- Consumes (app, all existing): `UnpeelStore.selectedSession: SessionEntry?` (fields `projectID`, `worktreePath: String?`), `UnpeelStore.selectedSessionID: String?`, `UnpeelStore.selectedHostScope` (`== .local`), `UnpeelStore.displayProjectsByID: [String: Project]` (`Project.path`), `UnpeelStore.paneWorkingDirectory(for:) -> String?`, `UnpeelStore.openInEditor(path:)`, `UnpeelStore.settingsVisible`, `UnpeelStore.sidebarCollapsed`, `UnpeelStore.showsWindowTitleStrip`, `SurfaceCache.existingPane(for:) -> GhosttyTerminalPane?`, `GhosttyTerminalPane.sendText(_:) -> Bool`, `GhosttyTerminalPane.quoteDropReference(_:) -> String`, `AppDefaults.shared`, `Theme.surfaceInset`, `Theme.titleStripHeight`, `Theme.paneDividerLineHover`, `Theme.foreground`, `Theme.mutedForeground`, `Theme.rowLabelNSFont`.
- Produces: `ExplorerPanelState.shared` (`isVisible`, `width`, `toggle()`, `static clamp(_:)`), `ExplorerContextResolver.resolve(...)`, `ExplorerContextResolver.agentReference(for:root:)`, `ExplorerPanelHost(store:cache:)`.

- [ ] **Step 1: Write the failing tests**

`Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift`:

```swift
import UnpeelExplorer
import XCTest
@testable import UnpeelNative

final class ExplorerContextResolverTests: XCTestCase {
    func testRemoteScopeWinsOverEverything() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: false, hasSession: true,
                worktreePath: "/w", projectPath: "/p", fallbackDirectory: "/c"
            ),
            .remote
        )
    }

    func testNoSessionMeansNoContext() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: false,
                worktreePath: nil, projectPath: "/p", fallbackDirectory: nil
            ),
            .none
        )
    }

    func testWorktreeBeatsProjectButProjectStaysTheProjectRoot() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: true,
                worktreePath: "/p/.worktrees/fix", projectPath: "/p", fallbackDirectory: "/c"
            ),
            .local(root: "/p/.worktrees/fix", projectRoot: "/p")
        )
    }

    func testBlankWorktreeFallsBackToProjectThenDirectory() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: true,
                worktreePath: "  ", projectPath: "/p", fallbackDirectory: "/c"
            ),
            .local(root: "/p", projectRoot: "/p")
        )
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: true,
                worktreePath: nil, projectPath: nil, fallbackDirectory: "/c"
            ),
            .local(root: "/c", projectRoot: "/c")
        )
    }

    func testNothingUsableMeansNoContext() {
        XCTAssertEqual(
            ExplorerContextResolver.resolve(
                isLocalScope: true, hasSession: true,
                worktreePath: nil, projectPath: "", fallbackDirectory: nil
            ),
            .none
        )
    }

    func testAgentReferenceIsRelativeInsideTheRoot() {
        XCTAssertEqual(ExplorerContextResolver.agentReference(for: "/p/src/a b.swift", root: "/p"), "src/a b.swift")
        XCTAssertEqual(ExplorerContextResolver.agentReference(for: "/elsewhere/x", root: "/p"), "/elsewhere/x")
    }
}
```

`Tests/UnpeelNativeTests/ExplorerPanelStateTests.swift`:

```swift
import XCTest
@testable import UnpeelNative

@MainActor
final class ExplorerPanelStateTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "unpeel.explorer.paneltests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testDefaultsAreHiddenAndDefaultWidth() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = ExplorerPanelState(defaults: defaults)

        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.width, 260)
    }

    func testToggleAndWidthPersist() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ExplorerPanelState(defaults: defaults)

        state.toggle()
        state.width = 333

        let reopened = ExplorerPanelState(defaults: defaults)
        XCTAssertTrue(reopened.isVisible)
        XCTAssertEqual(reopened.width, 333)
    }

    func testWidthIsClamped() {
        XCTAssertEqual(ExplorerPanelState.clamp(10), 180)
        XCTAssertEqual(ExplorerPanelState.clamp(300), 300)
        XCTAssertEqual(ExplorerPanelState.clamp(9000), 520)
    }

    func testOutOfRangeStoredWidthIsClampedOnLoad() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5.0, forKey: "unpeel.explorer.width")

        XCTAssertEqual(ExplorerPanelState(defaults: defaults).width, 180)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "ExplorerContextResolverTests|ExplorerPanelStateTests" 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'ExplorerContextResolver' in scope`.

- [ ] **Step 3: Implement the state object and resolver**

`Sources/UnpeelNative/ExplorerPanelState.swift`:

```swift
//
//  ExplorerPanelState.swift
//  UnpeelNative
//
//  Visibility and width of the file explorer column. Kept out of UnpeelStore
//  on purpose: the explorer is a fork-only feature and this keeps upstream
//  merges of the store conflict-free.
//

import Foundation

@MainActor
final class ExplorerPanelState: ObservableObject {
    static let shared = ExplorerPanelState(defaults: AppDefaults.shared)

    static let defaultWidth: Double = 260
    static let minWidth: Double = 180
    static let maxWidth: Double = 520

    private static let visibleKey = "unpeel.explorer.visible"
    private static let widthKey = "unpeel.explorer.width"

    private let defaults: UserDefaults

    @Published var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Self.visibleKey) }
    }

    @Published var width: Double {
        didSet { defaults.set(width, forKey: Self.widthKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Self.visibleKey)
        let stored = defaults.double(forKey: Self.widthKey)
        width = stored > 0 ? Self.clamp(stored) : Self.defaultWidth
    }

    func toggle() {
        isVisible.toggle()
    }

    static func clamp(_ width: Double) -> Double {
        min(maxWidth, max(minWidth, width))
    }
}
```

`Sources/UnpeelNative/ExplorerContextResolver.swift`:

```swift
//
//  ExplorerContextResolver.swift
//  UnpeelNative
//
//  Pure mapping from "what is selected" to what the explorer should show.
//

import Foundation
import UnpeelExplorer

enum ExplorerContextResolver {
    /// The explorer root is the session's worktree when it has one, else its
    /// project folder, else the pane's working directory. Remote scopes never
    /// resolve: their paths live on another machine.
    static func resolve(
        isLocalScope: Bool,
        hasSession: Bool,
        worktreePath: String?,
        projectPath: String?,
        fallbackDirectory: String?
    ) -> ExplorerContext {
        guard isLocalScope else { return .remote }
        guard hasSession else { return .none }
        let project = nonBlank(projectPath)
        guard let root = nonBlank(worktreePath) ?? project ?? nonBlank(fallbackDirectory) else {
            return .none
        }
        return .local(root: root, projectRoot: project ?? root)
    }

    /// What gets pasted into the agent's prompt for `path`: relative to the
    /// explorer root (the agent's checkout) when inside it, else absolute.
    static func agentReference(for path: String, root: String) -> String {
        ExplorerPaths.relative(path, to: root)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
```

- [ ] **Step 4: Run to verify the new tests pass**

Run: `swift test --filter "ExplorerContextResolverTests|ExplorerPanelStateTests" 2>&1 | tail -20`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Add the host view**

`Sources/UnpeelNative/Views/ExplorerPanelHost.swift`:

```swift
//
//  ExplorerPanelHost.swift
//  UnpeelNative
//
//  The only place the file explorer library meets app state: it derives the
//  explorer context from the selected session and performs the two actions
//  the library cannot (open in the user's editor, paste into the terminal).
//

import AppKit
import SwiftUI
import UnpeelExplorer

@MainActor
final class ExplorerHostActions: ExplorerActionHandler {
    weak var store: UnpeelStore?
    weak var cache: SurfaceCache?
    var root: String?

    private var selectedPane: GhosttyTerminalPane? {
        guard let sessionID = store?.selectedSessionID else { return nil }
        return cache?.existingPane(for: sessionID)
    }

    var canSendToAgent: Bool { selectedPane != nil }

    func openInEditor(path: String) {
        store?.openInEditor(path: path)
    }

    /// Same shape as dropping the file on the terminal: a shell-quoted path
    /// and a trailing space, never Enter.
    func sendPathToAgent(path: String) {
        guard let pane = selectedPane else { return }
        let reference = ExplorerContextResolver.agentReference(for: path, root: root ?? "")
        pane.sendText(GhosttyTerminalPane.quoteDropReference(reference) + " ")
    }
}

struct ExplorerPanelHost: View {
    @ObservedObject var store: UnpeelStore
    let cache: SurfaceCache

    @StateObject private var viewModel = ExplorerViewModel(
        stateStore: ExplorerStateStore(defaults: AppDefaults.shared)
    )
    @State private var actions = ExplorerHostActions()

    private var resolvedContext: ExplorerContext {
        let session = store.selectedSession
        return ExplorerContextResolver.resolve(
            isLocalScope: store.selectedHostScope == .local,
            hasSession: session != nil,
            worktreePath: session?.worktreePath,
            projectPath: session.flatMap { store.displayProjectsByID[$0.projectID]?.path },
            fallbackDirectory: session.flatMap { store.paneWorkingDirectory(for: $0) }
        )
    }

    private var palette: ExplorerPalette {
        ExplorerPalette(
            text: NSColor(Theme.foreground),
            secondaryText: NSColor(Theme.mutedForeground),
            rowFont: Theme.rowLabelNSFont
        )
    }

    var body: some View {
        ExplorerPanelView(viewModel: viewModel, palette: palette, actionHandler: actions)
            .onAppear { sync(resolvedContext) }
            .onChange(of: resolvedContext) { sync($0) }
            .onDisappear { viewModel.persistState() }
    }

    private func sync(_ context: ExplorerContext) {
        actions.store = store
        actions.cache = cache
        if case .local(let root, _) = context {
            actions.root = root
        } else {
            actions.root = nil
        }
        viewModel.setContext(context)
    }
}
```

- [ ] **Step 6: Insert the column into `RootView.swift`**

(a) Beside the other `@State` declarations (after `@State private var projectSidebarResizerHovering = false`), add:

```swift
    // Fork-only: file explorer column (UnpeelExplorer).
    @ObservedObject private var explorerState = ExplorerPanelState.shared
    @State private var draggingExplorerWidth: Double?
    @State private var explorerDragStartWidth: Double?
    @State private var explorerResizerHovering = false
```

(b) After the `shownProjectSidebarWidth` computed property, add:

```swift
    private var explorerWidth: Double {
        draggingExplorerWidth ?? explorerState.width
    }

    /// Like the project panel, the explorer slides away under full-content
    /// pages (Settings) instead of being toggled off.
    private var explorerShown: Bool {
        explorerState.isVisible && !store.settingsVisible
    }

    private var shownExplorerWidth: CGFloat {
        explorerShown ? CGFloat(explorerWidth) : 0
    }
```

(c) In `appLayout`, directly after the sidebar block's `.clipped()` and before `ContentArea(`, insert:

```swift
                // Fork-only: file explorer column. Mounted only while shown so
                // a hidden explorer holds no FSEvents stream.
                ZStack(alignment: .trailing) {
                    if explorerShown {
                        ExplorerPanelHost(store: store, cache: cache)
                            .frame(width: CGFloat(explorerWidth))
                            .padding(.top, surfaceInset + (store.showsWindowTitleStrip ? Theme.titleStripHeight : 0))
                            .padding(.bottom, surfaceInset)
                    }
                }
                .frame(width: shownExplorerWidth, alignment: .trailing)
                .clipped()
```

(d) Change the content pane's leading padding so the frame gap is not doubled when the explorer is the leading neighbour. Replace:

```swift
                    .padding(.leading, store.sidebarCollapsed ? surfaceInset : 0)
```

with:

```swift
                    .padding(.leading, store.sidebarCollapsed && !explorerShown ? surfaceInset : 0)
```

(e) After the existing `.animation(…, value: projectSidebarShown)` modifier add:

```swift
        .animation(
            .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.15),
            value: explorerShown
        )
```

(f) After the `.overlay(alignment: .topTrailing) { if projectSidebarShown { projectSidebarResizer } }` modifier add:

```swift
        .overlay(alignment: .topLeading) {
            if explorerShown {
                explorerResizer
            }
        }
```

(g) After the `projectSidebarResizer` computed property, add:

```swift
    /// Trailing-edge handle of the explorer column; same feel as `resizer`.
    private var explorerResizer: some View {
        ZStack {
            if explorerResizerHovering || draggingExplorerWidth != nil {
                Capsule()
                    .fill(Theme.paneDividerLineHover)
                    .frame(width: 3, height: 36)
                    .transition(.opacity)
            }
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .offset(x: shownSidebarWidth + CGFloat(explorerWidth) - 4)
        .animation(.easeInOut(duration: 0.12), value: explorerResizerHovering)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = explorerDragStartWidth ?? explorerWidth
                    explorerDragStartWidth = start
                    draggingExplorerWidth = ExplorerPanelState.clamp(start + value.translation.width)
                }
                .onEnded { _ in
                    if let final = draggingExplorerWidth {
                        explorerState.width = final
                    }
                    draggingExplorerWidth = nil
                    explorerDragStartWidth = nil
                }
        )
        .onHover { inside in
            explorerResizerHovering = inside
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }
```

- [ ] **Step 7: Add the menu item to `AppDelegate.swift`**

(a) In `installMainMenu()`, immediately before `viewItem.submenu = viewMenu`, add:

```swift
        // Fork-only: file explorer column (UnpeelExplorer).
        viewMenu.addItem(.separator())
        let explorerItem = NSMenuItem(
            title: "Show Explorer",
            action: #selector(toggleExplorerFromMenu),
            keyEquivalent: "e"
        )
        explorerItem.keyEquivalentModifierMask = [.command, .shift]
        explorerItem.target = self
        viewMenu.addItem(explorerItem)
```

(b) Beside `increaseTerminalFontSizeFromMenu()`, add:

```swift
    @objc private func toggleExplorerFromMenu() {
        ExplorerPanelState.shared.toggle()
    }
```

(c) At the top of `validateMenuItem(_:)`, before the first `if`, add:

```swift
        if menuItem.action == #selector(toggleExplorerFromMenu) {
            menuItem.title = ExplorerPanelState.shared.isVisible ? "Hide Explorer" : "Show Explorer"
            return window != nil
        }
```

- [ ] **Step 8: Build and run the app-target tests**

Run: `swift build 2>&1 | grep -E "error|Build complete" | head -20`
Expected: `Build complete!` and no `error:` lines.

Run: `swift test --filter "ExplorerContextResolverTests|ExplorerPanelStateTests|UnpeelExplorerTests" 2>&1 | tail -10`
Expected: all pass, 0 failures.

- [ ] **Step 9: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelNative/ExplorerPanelState.swift clients/native/UnpeelNative/Sources/UnpeelNative/ExplorerContextResolver.swift clients/native/UnpeelNative/Sources/UnpeelNative/Views/ExplorerPanelHost.swift clients/native/UnpeelNative/Sources/UnpeelNative/Views/RootView.swift clients/native/UnpeelNative/Sources/UnpeelNative/AppDelegate.swift clients/native/UnpeelNative/Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift clients/native/UnpeelNative/Tests/UnpeelNativeTests/ExplorerPanelStateTests.swift
git commit -m "feat: show the file explorer column in the Mac app (Cmd-Shift-E)"
```

---

### Task 10: Regression gate, coverage, and runtime verification

This task produces evidence, not code. Any defect found here is fixed test-first (add a failing test in the owning task's test file, fix, re-run) and committed as `fix: …`.

**Files:**
- Create: `docs/superpowers/verification/2026-09-21-explorer-phase1.md` (the evidence log, with screenshots under `docs/superpowers/verification/explorer-phase1/`)

- [ ] **Step 1: Full native regression gate**

Run (from repo root): `clients/native/test-native.sh 2>&1 | tail -15`
Expected: the whole Swift suite passes with 0 failures. Record the final summary line in the evidence log. A failure in a test unrelated to the explorer must be reproduced on `main` (`git stash; git checkout main; …`) before it is called pre-existing.

- [ ] **Step 2: Coverage of the library**

Run:

```bash
cd /Users/alimazid/unpeel/clients/native/UnpeelNative
swift test --enable-code-coverage --filter UnpeelExplorerTests 2>&1 | tail -3
xcrun llvm-cov report \
  "$(swift build --show-bin-path)/UnpeelNativePackageTests.xctest/Contents/MacOS/UnpeelNativePackageTests" \
  -instr-profile "$(swift build --show-bin-path)/codecov/default.profdata" \
  -ignore-filename-regex '(Tests|\.build|vendor|Sources/UnpeelNative/|UnpeelShared)' | tail -25
```

Expected: a per-file table for `Sources/UnpeelExplorer/*` and a TOTAL line. Target ≥ 80% lines. If below target, add tests for the uncovered *logic* (model, view model, controller). `ExplorerOutlineView.swift`, `ExplorerPanelView.swift` body code and Quick Look plumbing need a window and are covered by Step 4 instead — report their numbers honestly rather than contorting tests around them.

- [ ] **Step 3: Launch the isolated dev build**

```bash
cd /Users/alimazid/unpeel
mkdir -p ~/unpeel-dev-explorer-fixture/src/views ~/unpeel-dev-explorer-fixture/build
cd ~/unpeel-dev-explorer-fixture && git init -q 2>/dev/null; printf 'build/\n*.log\n' > .gitignore
touch README.md package.json src/main.ts src/views/App.tsx src/views/Nav.tsx build/out.js debug.log .env
cd /Users/alimazid/unpeel
UNPEEL_HOME=~/unpeel-dev-explorer-home clients/native/dev-blank.sh
```

Expected: an app whose menu bar reads **Unpeel Dev** launches. `/Applications/Unpeel.app`, if running, is untouched. If macOS shows a Keychain prompt for `com.unpeel.license`, stop and report it to the user — do not dismiss it on their behalf.

In Unpeel Dev, add `~/unpeel-dev-explorer-fixture` as a project and start a shell session in it.

- [ ] **Step 4: Walk the acceptance checklist**

For each item record PASS/FAIL plus a screenshot (`screencapture -x -o -l <windowID>` or ⇧⌘4) in the evidence log:

1. ⌘⇧E shows the column; View menu item reads "Hide Explorer"; ⌘⇧E again hides it; the state survives quitting and relaunching Unpeel Dev. With a terminal focused, ⌘⇧E still toggles (if the terminal swallows it, record FAIL — the fix is a Ghostty keybind passthrough, handled as a `fix:` task).
2. Header shows `UNPEEL-DEV-EXPLORER-FIXTURE`; rows: `src`, `README.md`, `package.json` — `build`, `debug.log`, `.env`, `.git`, `.gitignore` hidden.
3. `⋯` ▸ Show Hidden Files reveals `.env` and `.gitignore` dimmed, never `.git`. Show Git-Ignored Files reveals `build` and `debug.log` dimmed.
4. Click `src` expands it; click again collapses; the disclosure triangle does the same and does **not** double-toggle. `views` stays expanded across a collapse/expand of `src`.
5. Keyboard: ↑↓ move; → expands then moves to first child; ← collapses then moves to parent; typing `pa` selects `package.json`; Space opens Quick Look for a file; ⌘↓ opens a file in the configured editor; ⌥⌘C puts the absolute path on the clipboard (`pbpaste`); ⇧⌥⌘C the relative path; ⌥⌘R reveals in Finder.
6. Double-click `README.md` opens it in the configured editor.
7. Right-click a file: menu is Open in Editor / Reveal in Finder / Quick Look / Send Path to Agent / Copy Path / Copy Relative Path / Refresh. "Send Path to Agent" types `README.md ` (with trailing space, no Enter) at the shell prompt.
8. Drag `src/views/App.tsx` onto the terminal pane: the quoted path is pasted, no Enter.
9. Auto-refresh: in the session's shell run `touch src/new.ts && mkdir docs && rm package.json`; within ~1 s the tree shows `new.ts` and `docs` and drops `package.json`, with expansion and selection otherwise unchanged.
10. Create a second project/session on another folder; switch between the two sessions: the root re-targets each time and each root's expansion, selection and scroll position come back.
11. Drag the column's trailing edge: clamps at 180 and 520; width survives relaunch. Collapse the left sidebar: the explorer stays usable, clears the traffic lights/title strip, and the content pane keeps exactly one frame gap.
12. Open Settings: the column slides away; close Settings: it returns.
13. Delete the fixture's folder while it is the root (`rm -rf` from another terminal): the panel shows the error with Retry; recreating the folder and pressing Retry recovers.
14. `mkdir big && cd big && for i in $(seq 1 10050); do : > f$i; done` then expand `big`: UI stays responsive and the last row reads `… 50 more items not shown`.
15. With the explorer hidden, `lsof -p <Unpeel Dev pid> | grep -c fsevents` is no higher than before the explorer was first shown (no leaked stream).

- [ ] **Step 5: Write the evidence log and commit**

`docs/superpowers/verification/2026-09-21-explorer-phase1.md` lists: the test-gate summary line, the coverage table, and the 15-item checklist with PASS/FAIL, notes and screenshot paths. Any FAIL is either fixed (linking the `fix:` commit) or listed under "Open issues" with the reason.

```bash
cd /Users/alimazid/unpeel
git add docs/superpowers/verification
git commit -m "docs: record explorer phase 1 verification evidence"
```

- [ ] **Step 6: Clean up**

Quit Unpeel Dev from its own menu (never `killall Unpeel`). Remove `~/unpeel-dev-explorer-fixture` and `~/unpeel-dev-explorer-home` only after the evidence log is committed.

---

## Self-Review Notes

- **Spec coverage:** toggle/width/persistence → Tasks 9, 10; header + toggles + empty/error states → Task 8; root-follows-selection + per-root restore → Tasks 5, 6, 9; lazy loading, stale-load discard → Task 6; FSEvents refresh + `.gitignore` rescan → Tasks 4, 6; confinement + symlink rule + unreadable dirs + 10k cap → Tasks 1, 7; git-ignore → Task 3; icons, keyboard, context menu, Quick Look, copy/reveal/send, drag-out → Tasks 7, 8; three-file touchpoint limit → Task 9; testing + runtime verification + coverage → Task 10.
- **Deliberate refinements of the spec (spec updated to match):** the tree is a flat `[directory path: contents]` map with `FileEntry` rows instead of a nested `FileNode`; ignore rules are re-evaluated per scan rather than cached; a load is discarded when the root changed or its directory is no longer tracked (a merely *collapsed* folder keeps its contents so it keeps refreshing); New File / New Folder live in Phase 2 with the other file operations.
- **Phase 2+ items intentionally absent:** multi-select *operations*, rename, create, delete, move/copy, external drops, undo, git decorations, compact folders, nesting, filter field.
