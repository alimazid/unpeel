# Explorer Open-With Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-click, ⌘↓ and a new "Open" context-menu item open explorer files through `UnpeelStore.openClickedFile` (Unpeel's open-with rules: `.md` → Markdown plugin side pane, else editor); "Open in Editor" stays as the explicit bypass.

**Architecture:** The `UnpeelExplorer` library gains one handler intent, `openFile(path:)`, and routes its three open entry points to it. The app's `ExplorerHostActions` implements it by resolving the explorer's target session and calling `store.openClickedFile`, falling back to the editor when no session can be resolved. Spec: `docs/superpowers/specs/2026-09-22-explorer-open-with-rules-design.md`.

**Tech Stack:** Swift 6 (strict concurrency), AppKit `NSOutlineView`, XCTest. Package: `clients/native/UnpeelNative` (targets `UnpeelExplorer`, `UnpeelNative`, tests `UnpeelExplorerTests`, `UnpeelNativeTests`).

## Global Constraints

- Swift tools 6.0, strict concurrency; macOS 13 deployment floor. `UnpeelExplorer` may import only Foundation/AppKit/SwiftUI/Combine/CoreServices/Quartz/UniformTypeIdentifiers/os.
- No upstream file is edited: the only app-side files touched are the fork-only `ExplorerContextResolver.swift`, `Views/ExplorerPanelHost.swift` and `Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift`. `UnpeelStore.swift`, `RootView.swift`, `AppDelegate.swift` stay untouched.
- Menu titles exactly: "Open" (new), "Open in Editor" (unchanged). For file targets the action list starts `[.open, .openInEditor, .revealInFinder, .quickLook, nil]`; directory-only targets contain neither `.open` nor `.openInEditor`.
- Double-click and ⌘↓ on a **directory** keep Phase 1 behaviour (double-click: nothing in the controller; ⌘↓: expand).
- Logging via `os.Logger`, never `print`; file paths are logged with `privacy: .private`.
- Run tests from `clients/native/UnpeelNative` with `swift test --filter <TestClass>`; the debug bridge must already exist (`ls ../../../crates/target/native-bridge/debug/` — if missing run `../build-rust-bridge.sh debug` from the package directory's parent).
- Commit with plain `git commit -m …` (a repo hook rejects any command line containing `git commit` together with an `-n` flag). Every commit message ends with the line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Never launch or signal `/Applications/Unpeel.app` or its Host processes.

---

### Task 1: Library — `openFile` intent, "Open" menu item, routing of double-click and ⌘↓

**Files:**
- Modify: `clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerPalette.swift` (protocol at the bottom of the file)
- Modify: `clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerOutlineController.swift` (`MenuAction`, `handleDoubleClick`, `menuActions(forTargets:)`, `perform(_:on:)`, `handleKeyCommand(.open)`)
- Test: `clients/native/UnpeelNative/Tests/UnpeelExplorerTests/ExplorerOutlineControllerTests.swift`

**Interfaces:**
- Consumes: existing `ExplorerActionHandler`, `ExplorerOutlineController.MenuAction`, `applied?.entry(at:)`, `filesOnly(_:)`.
- Produces: `ExplorerActionHandler.openFile(path: String)` (Task 2 implements it); `MenuAction.open`; internal `ExplorerOutlineController.doubleClick(onPath:)` test seam.

- [ ] **Step 1: Extend the recording handler and write the failing tests**

In `Tests/UnpeelExplorerTests/ExplorerOutlineControllerTests.swift` replace the `RecordingHandler` class with:

```swift
@MainActor
private final class RecordingHandler: ExplorerActionHandler {
    var canSendToAgent = true
    /// Paths passed to `openFile` (open-with rules).
    var openedWithRules: [String] = []
    /// Paths passed to `openInEditor` (explicit editor bypass).
    var opened: [String] = []
    var sent: [String] = []
    func openFile(path: String) { openedWithRules.append(path) }
    func openInEditor(path: String) { opened.append(path) }
    func sendPathToAgent(path: String) { sent.append(path) }
}
```

Update the two existing menu expectations so files start with `.open`:

- In `testMenuActionsDependOnTheTarget`, the `/r/a.txt` expectation becomes
  `[.open, .openInEditor, .revealInFinder, .quickLook, nil, .sendToAgent, nil, .copyPath, .copyRelativePath, nil, .refresh]`. The `/r/src` expectation is unchanged.
- In `testMenuActionsForTargetsConsidersTheWholeSet`, `expected` starts `.open, .openInEditor, .revealInFinder, .quickLook, nil,`.

Change `testOpenKeyCommandOpensSelectedFiles` so ⌘↓ is asserted to go through the rules, not the editor, and covers two files in selection order:

```swift
    func testOpenKeyCommandOpensSelectedFilesThroughTheRules() {
        let (controller, viewModel, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(showHidden: true), selection: [])
        viewModel.selection = ["/r/.env", "/r/a.txt"]

        XCTAssertTrue(controller.handleKeyCommand(.open))
        XCTAssertEqual(handler.openedWithRules, ["/r/.env", "/r/a.txt"])
        XCTAssertEqual(handler.opened, [])
    }
```

Add these new tests after `testPerformOpenInEditorSkipsDirectories`:

```swift
    /// Double-click is the primary "open" gesture and must go through the
    /// app's open-with rules (`openFile`), never straight to the editor;
    /// a directory double-click stays a no-op here (expansion is on click).
    func testDoubleClickOpensAFileThroughTheRulesAndIgnoresDirectories() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.doubleClick(onPath: "/r/a.txt")
        controller.doubleClick(onPath: "/r/src")
        controller.doubleClick(onPath: "/r/missing.txt")

        XCTAssertEqual(handler.openedWithRules, ["/r/a.txt"])
        XCTAssertEqual(handler.opened, [])
    }

    /// The two menu items are distinct intents: "Open" → rules, "Open in
    /// Editor" → editor. Each must call only its own handler member, and
    /// both skip directories in a mixed target set.
    func testPerformOpenAndOpenInEditorCallDistinctHandlerMembers() {
        let (controller, _, suite) = makeController()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let handler = RecordingHandler()
        controller.actionHandler = handler
        controller.apply(model: sampleModel(), filter: VisibilityFilter(), selection: [])

        controller.perform(.open, on: ["/r/a.txt", "/r/src"])
        XCTAssertEqual(handler.openedWithRules, ["/r/a.txt"])
        XCTAssertEqual(handler.opened, [])

        controller.perform(.openInEditor, on: ["/r/src", "/r/a.txt"])
        XCTAssertEqual(handler.openedWithRules, ["/r/a.txt"])
        XCTAssertEqual(handler.opened, ["/r/a.txt"])
    }

    func testOpenMenuActionTitle() {
        XCTAssertEqual(ExplorerOutlineController.MenuAction.open.title, "Open")
        XCTAssertEqual(ExplorerOutlineController.MenuAction.openInEditor.title, "Open in Editor")
    }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run (from `clients/native/UnpeelNative`): `swift test --filter ExplorerOutlineControllerTests 2>&1 | tail -20`
Expected: compile errors — `RecordingHandler` has an extra method not in the protocol is fine, but `MenuAction.open`, `doubleClick(onPath:)` do not exist ("type 'ExplorerOutlineController.MenuAction' has no member 'open'", "value of type 'ExplorerOutlineController' has no member 'doubleClick'").

- [ ] **Step 3: Add the protocol member**

In `Sources/UnpeelExplorer/ExplorerPalette.swift` replace the protocol with:

```swift
/// What the explorer cannot do on its own; implemented by the host app.
@MainActor
public protocol ExplorerActionHandler: AnyObject {
    var canSendToAgent: Bool { get }
    /// Open with the app's open-with rules (the same routing as ⌘-clicking a
    /// path in a terminal: a plugin side pane for types that have one, else
    /// the editor). Double-click, ⌘↓ and the "Open" menu item use this.
    func openFile(path: String)
    /// Always the configured editor — the explicit bypass ("Open in Editor").
    func openInEditor(path: String)
    func sendPathToAgent(path: String)
}
```

- [ ] **Step 4: Add `MenuAction.open`, route double-click, menu and ⌘↓**

In `Sources/UnpeelExplorer/ExplorerOutlineController.swift`:

Replace the `MenuAction` enum:

```swift
    public enum MenuAction: String, Equatable {
        case open, openInEditor, revealInFinder, quickLook, sendToAgent
        case copyPath, copyRelativePath, refresh, collapse

        var title: String {
            switch self {
            case .open: return "Open"
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
```

Replace `handleDoubleClick`:

```swift
    @objc private func handleDoubleClick() {
        guard let outlineView, outlineView.clickedRow >= 0,
              let entry = entry(for: outlineView.item(atRow: outlineView.clickedRow))
        else { return }
        doubleClick(onPath: entry.path)
    }

    /// Double-click on a file opens it through the app's open-with rules
    /// (`openFile`), never the editor directly. Directories do nothing here:
    /// a single click already toggles them. Internal so tests can drive it —
    /// `NSOutlineView.clickedRow` is read-only and needs a real click.
    func doubleClick(onPath path: String) {
        guard let entry = applied?.entry(at: path), entry.kind == .file else { return }
        actionHandler?.openFile(path: path)
    }
```

In `menuActions(forTargets:)` change the file branch:

```swift
        var actions: [MenuAction?] = hasFile
            ? [.open, .openInEditor, .revealInFinder, .quickLook, nil]
            : [.revealInFinder, nil]
```

and update the doc comment above it so the example reads `must offer "Open"/"Open in Editor"/"Quick Look" (there's a file)`.

In `perform(_:on:)` add the case before `.openInEditor`:

```swift
        case .open:
            filesOnly(paths).forEach { actionHandler?.openFile(path: $0) }
```

In `handleKeyCommand(_:)`, `case .open`, replace `actionHandler?.openInEditor(path: path)` with `actionHandler?.openFile(path: path)`.

- [ ] **Step 5: Run the library tests**

Run: `swift test --filter UnpeelExplorerTests 2>&1 | tail -5`
Expected: `Executed 117 tests, with 0 failures` (114 before + 3 new; one renamed).

Also build the whole package so the app target's now-incomplete `ExplorerHostActions` shows up: `swift build 2>&1 | grep -E "error|warning: .*Explorer" | head`. Expected: exactly one error — `type 'ExplorerHostActions' does not conform to protocol 'ExplorerActionHandler'`. That is Task 2's job; do **not** fix it here and do not run `swift test` without a `--filter` (the app test target will not compile until Task 2).

- [ ] **Step 6: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerPalette.swift \
        clients/native/UnpeelNative/Sources/UnpeelExplorer/ExplorerOutlineController.swift \
        clients/native/UnpeelNative/Tests/UnpeelExplorerTests/ExplorerOutlineControllerTests.swift
git commit -m "feat(explorer): route double-click, ⌘↓ and a new Open item through openFile

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: App — `ExplorerHostActions.openFile` via `UnpeelStore.openClickedFile`

**Files:**
- Modify: `clients/native/UnpeelNative/Sources/UnpeelNative/ExplorerContextResolver.swift`
- Modify: `clients/native/UnpeelNative/Sources/UnpeelNative/Views/ExplorerPanelHost.swift` (class `ExplorerHostActions`, lines 14–81)
- Test: `clients/native/UnpeelNative/Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift`

**Interfaces:**
- Consumes: `ExplorerActionHandler.openFile(path:)` (Task 1); `UnpeelStore.openClickedFile(_ match: ClickablePath.Match, path: String, fromSessionID: String) -> Bool` (`UnpeelStore.swift:10700`, `@discardableResult`); `ClickablePath.Match(path:line:column:)` (`ClickablePath.swift:28`, memberwise init); existing private `targetSessionID` in `ExplorerHostActions`.
- Produces: `ExplorerOpenRoute` and `ExplorerContextResolver.openRoute(targetSessionID:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift`, inside the class:

```swift
    /// `openFile` goes through the open-with rules only when there is a
    /// session to attach a plugin pane to; without one the editor is the
    /// fallback so the gesture never silently does nothing.
    func testOpenRouteNeedsASessionForTheRules() {
        XCTAssertEqual(ExplorerContextResolver.openRoute(targetSessionID: "s1"), .rules(sessionID: "s1"))
        XCTAssertEqual(ExplorerContextResolver.openRoute(targetSessionID: nil), .editor)
        XCTAssertEqual(ExplorerContextResolver.openRoute(targetSessionID: ""), .editor)
    }

    /// With no store attached (the panel before its first body pass) every
    /// handler member must be a safe no-op rather than a crash.
    @MainActor
    func testHostActionsWithoutAStoreAreNoOps() {
        let actions = ExplorerHostActions()
        actions.openFile(path: "/tmp/README.md")
        actions.openInEditor(path: "/tmp/README.md")
        actions.sendPathToAgent(path: "/tmp/README.md")
        XCTAssertFalse(actions.canSendToAgent)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ExplorerContextResolverTests 2>&1 | tail -15`
Expected: compile errors — `ExplorerHostActions` does not conform to `ExplorerActionHandler` (from Task 1) and `openRoute` / `.rules` do not exist.

- [ ] **Step 3: Add the route decision**

Append to `Sources/UnpeelNative/ExplorerContextResolver.swift`, after the last `static func` inside the enum (keep the private `nonBlank` helper where it is; use it):

```swift
    /// How the explorer opens a file. The open-with rules
    /// (`UnpeelStore.openClickedFile`) attach a plugin pane to a CALLER
    /// session, so they need one; with no resolvable target session the
    /// editor is the fallback (never a silent no-op).
    static func openRoute(targetSessionID: String?) -> ExplorerOpenRoute {
        guard let sessionID = nonBlank(targetSessionID) else { return .editor }
        return .rules(sessionID: sessionID)
    }
```

and, at file scope below the enum:

```swift
enum ExplorerOpenRoute: Equatable {
    /// `UnpeelStore.openClickedFile` with this caller session.
    case rules(sessionID: String)
    case editor
}
```

`nonBlank` is the existing `private static func nonBlank(_:) -> String?` at line 79 of the enum; place `openRoute` above it.

- [ ] **Step 4: Implement `openFile` on `ExplorerHostActions`**

In `Sources/UnpeelNative/Views/ExplorerPanelHost.swift`:

Add `import os` after `import AppKit`.

Inside `ExplorerHostActions`, after the `root` property add:

```swift
    private static let logger = Logger(subsystem: "com.unpeel.explorer", category: "host")
```

Replace the `openInEditor` method with both methods:

```swift
    /// Open-with rules, exactly the routine behind a terminal ⌘-click:
    /// registry match by extension (`.md` → Markdown plugin), Settings ▸
    /// Open With override, else the editor; the plugin pane attaches to the
    /// explorer's target session. `openClickedFile` returns `false` only
    /// when the file no longer resolves on disk — the watcher removes the
    /// row moments later, so there is nothing more to do than note it.
    func openFile(path: String) {
        guard let store else {
            openInEditor(path: path)
            return
        }
        switch ExplorerContextResolver.openRoute(targetSessionID: targetSessionID) {
        case .editor:
            openInEditor(path: path)
        case let .rules(sessionID):
            let match = ClickablePath.Match(path: path, line: nil, column: nil)
            if !store.openClickedFile(match, path: path, fromSessionID: sessionID) {
                Self.logger.info("open declined for \(path, privacy: .private)")
            }
        }
    }

    func openInEditor(path: String) {
        store?.openInEditor(path: path)
    }
```

Update the file header comment's "performs the two actions the library cannot" to "three actions … (open through the open-with rules, open in the user's editor, paste into the terminal)".

- [ ] **Step 5: Run the app-side and library tests**

Run: `swift test --filter "ExplorerContextResolverTests|ExplorerPanelStateTests|UnpeelExplorerTests" 2>&1 | tail -5`
Expected: 0 failures.

Then the full native gate from the repo root: `clients/native/test-native.sh 2>&1 | tail -3`
Expected: `Executed <N> tests, with 1 test skipped and 0 failures` (the one skip is upstream's `HostServiceIdentityTests.testStaleWorkerIsRestartedOnceNotInALoop`).

- [ ] **Step 6: Commit**

```bash
cd /Users/alimazid/unpeel
git add clients/native/UnpeelNative/Sources/UnpeelNative/ExplorerContextResolver.swift \
        clients/native/UnpeelNative/Sources/UnpeelNative/Views/ExplorerPanelHost.swift \
        clients/native/UnpeelNative/Tests/UnpeelNativeTests/ExplorerContextResolverTests.swift
git commit -m "feat(explorer): open files through Unpeel's open-with rules from the panel

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Runtime verification and docs (controller runs this, not a subagent)

**Files:**
- Modify: `docs/superpowers/verification/2026-09-21-explorer-phase1.md` (append §7)
- Modify: `docs/superpowers/specs/2026-09-22-explorer-open-with-rules-design.md` (Status line)

- [ ] **Step 1: Build the dev app and link the Markdown plugin into the dev home**

From the repo root, with the four live sessions in `~/unpeel-dev-explorer-home` left alone:
`UNPEEL_HOME=$HOME/unpeel-dev-explorer-home clients/native/dev-blank.sh` (the recipe used for Phase 1). Then link the plugin for that home: `cargo build --manifest-path crates/apps/Cargo.toml -p unpeel-markdown --release` (package name confirmed in `crates/apps/markdown/Cargo.toml`), then `UNPEEL_HOME=$HOME/unpeel-dev-explorer-home clients/native/dist/Unpeel.app/Contents/MacOS/unpeel apps link unpeel.app.markdown crates/apps/target/release/unpeel-markdown` (confirm the app id in `protocol/app-registry.json` and the binary path after the build). Verify with `… unpeel apps list`.

- [ ] **Step 2: Checklist (screenshots to `docs/superpowers/verification/explorer-open-with/`)**

| # | Check | Expected |
|---|---|---|
| 1 | Double-click `README.md` | Markdown plugin pane appears beside the target session's terminal |
| 2 | Double-click `README.md` again | Same pane reused (no second pane) |
| 3 | Select a `.md`, press ⌘↓ | Markdown pane (as 1) |
| 4 | Double-click `src/main.ts` | Editor comes to front; no plugin pane |
| 5 | Context menu on `README.md` | First items: Open, Open in Editor, Reveal in Finder, Quick Look |
| 6 | Open in Editor on `README.md` | Editor, not the plugin |
| 7 | Context menu on a folder | No Open / Open in Editor |
| 8 | `unpeel apps unlink unpeel.app.markdown` (dev home), double-click `README.md` | Unpeel's Install / Use Editor / Always Use Editor alert |
| 9 | Delete a file on disk, then double-click its still-visible row within the watcher's 1.5 s | Nothing opens; no crash; row disappears |

- [ ] **Step 3: Record and commit**

Append `## 7. Open-with rules (2026-09-22)` to the verification doc with the table results and the test count; set the spec's Status to "approved 2026-09-22; implemented". Commit:

```bash
git add docs/superpowers/verification docs/superpowers/specs/2026-09-22-explorer-open-with-rules-design.md
git commit -m "docs: record explorer open-with verification

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
