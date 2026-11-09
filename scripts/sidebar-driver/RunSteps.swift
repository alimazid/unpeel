import Foundation

/// One step of a run. `--only` takes its `name`, and a step with `runsByDefault`
/// off runs only when named.
struct RunStep {
    let name: String
    let runsByDefault: Bool
    let run: () -> Void

    init(_ name: String, runsByDefault: Bool = true, run: @escaping () -> Void) {
        self.name = name
        self.runsByDefault = runsByDefault
        self.run = run
    }
}

/// Every step, in the order a run takes them. A name with no step here is refused,
/// so a new scenario adds its step, and no name can be known but never run. The
/// names are what `--only` takes, not the rows of the report: one step can report
/// several scenarios, and one name can have two steps.
let runSteps: [RunStep] = [
    RunStep("toggle-project") {
        runToggles("Small", children: smallChildren, count: clickCount)
        runToggles("Quiet", children: ["~/w/Big/quiet-1"], count: clickCount)
        // Quiet starts collapsed, and an even count leaves it there.
    },
    RunStep("toggle") { runGroupToggles(count: clickCount) },
    RunStep("group-reorder") { runGroupReorder(count: dragCount) },
    RunStep("scrolled-list-reorder", runsByDefault: false) {
        runScrolledReorder("scrolled-list-reorder", session: "~/w/Big/big-05", how: "in a scrolled list", count: dragCount) {
            scrollToBottom()
        }
    },
    RunStep("scrolled-group-drop", runsByDefault: false) { runScrolledGroupDrop(count: dragCount) },
    RunStep("long-list-drop", runsByDefault: false) { runLongListDrop(count: dragCount) },
    RunStep("scrolled-back-reorder", runsByDefault: false) {
        // This doesn't catch a row missing from the drag registry: it stays green
        // with d978306 reverted. scrolled-group-drop and long-list-drop catch that.
        runScrolledReorder("scrolled-back-reorder", session: "~/w/Big/big-28", how: "after scrolling away and back", count: dragCount) {
            scrollToBottom()
            scrollToTop()
        }
    },
    RunStep("far-select", runsByDefault: false) { runFarSelect(count: min(dragCount, 10)) },
    RunStep("scrolled-folder", runsByDefault: false) { runScrolledFolder(count: min(dragCount, 10)) },
    RunStep("list-reorder") { runListReorder(count: dragCount) },
    RunStep("group-drop") { runGroupDrop(count: dragCount) },
    RunStep("out-and-back") { runDragOutAndBack(count: dragCount) },
    RunStep("list-reorder") { checkFoldersUnranked() },
    RunStep("drop-card") { runDropCard(count: min(dragCount, 6)) },
    RunStep("folder-cancel") { runFolderCancel(count: min(dragCount, 6)) },
    RunStep("folder-reorder") { runFolderMoves(count: dragCount) },
    RunStep("cross-project-insert", runsByDefault: false) { runCrossProjectInsert(count: min(dragCount, 6)) },
    RunStep("session-above-folder", runsByDefault: false) {
        setExpanded("Alpha", children: alphaChildren, false)
        setExpanded("Beta", children: betaChildren, false)
        runSessionAboveFolder(count: min(dragCount, 6))
        setExpanded("Alpha", children: alphaChildren, true)
        setExpanded("Beta", children: betaChildren, true)
    },
    RunStep("folder-persisted", runsByDefault: false) { runFolderPersisted() },
    RunStep("pinned-persisted", runsByDefault: false) { runPinnedPersisted() },
    RunStep("folder-pinned") { runPinnedFolders(count: dragCount) },
    RunStep("project-reorder") {
        setExpanded("Small", children: smallChildren, true)
        runProjectReorder(count: dragCount)
    },
]

/// What `--only` takes.
let knownScenarios = Set(runSteps.map(\.name))

func wanted(_ step: RunStep) -> Bool { only?.contains(step.name) ?? step.runsByDefault }
