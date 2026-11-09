import Foundation

/// One step of a run. `--only` takes its `name`, and a step with `runsByDefault`
/// off runs only when named.
struct ScenarioStep {
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
let scenarioSteps: [ScenarioStep] = [
    ScenarioStep("toggle-project") {
        runToggles("Small", children: smallChildren, count: clickCount)
        runToggles("Quiet", children: ["~/w/Big/quiet-1"], count: clickCount)
        // Quiet starts collapsed, and an even count leaves it there.
    },
    ScenarioStep("toggle") {
        runToggles("Inner", children: innerChildren, count: clickCount)
        if !Set(labels(readRows())).isSuperset(of: innerChildren), let inner = readRows().first(where: { $0.label == "Inner" }) {
            click(press(inner.frame))
            Thread.sleep(forTimeInterval: 0.7)
        }
        runToggles("Beta", children: betaChildren, count: clickCount)
        runToggles("Alpha", children: alphaChildren, count: clickCount)
        // Leave all three open for the drags, whatever state the toggles ended in.
        for (group, children) in [("Alpha", alphaChildren), ("Inner", innerChildren), ("Beta", betaChildren)] {
            let rows = readRows()
            if !Set(labels(rows)).isSuperset(of: children), let header = rows.first(where: { $0.label == group }) {
                click(press(header.frame))
                Thread.sleep(forTimeInterval: 0.8)
            }
        }
    },
    ScenarioStep("group-reorder") { runGroupReorder(count: dragCount) },
    ScenarioStep("scrolled-list-reorder", runsByDefault: false) {
        runScrolledReorder("scrolled-list-reorder", session: "~/w/Big/big-05", how: "in a scrolled list", count: dragCount) {
            scrollToBottom()
        }
    },
    ScenarioStep("scrolled-group-drop", runsByDefault: false) { runScrolledGroupDrop(count: dragCount) },
    ScenarioStep("long-list-drop", runsByDefault: false) { runLongListDrop(count: dragCount) },
    ScenarioStep("scrolled-back-reorder", runsByDefault: false) {
        // This doesn't catch a row missing from the drag registry: it stays green
        // with d978306 reverted. scrolled-group-drop and long-list-drop catch that.
        runScrolledReorder("scrolled-back-reorder", session: "~/w/Big/big-28", how: "after scrolling away and back", count: dragCount) {
            scrollToBottom()
            scrollToTop()
        }
    },
    ScenarioStep("far-select", runsByDefault: false) { runFarSelect(count: min(dragCount, 10)) },
    ScenarioStep("scrolled-folder", runsByDefault: false) { runScrolledFolder(count: min(dragCount, 10)) },
    ScenarioStep("list-reorder") { runListReorder(count: dragCount) },
    ScenarioStep("group-drop") { runGroupDrop(count: dragCount) },
    ScenarioStep("out-and-back") { runDragOutAndBack(count: dragCount) },
    ScenarioStep("list-reorder") { checkFoldersUnranked() },
    ScenarioStep("drop-card") { runDropCard(count: min(dragCount, 6)) },
    ScenarioStep("folder-cancel") { runFolderCancel(count: min(dragCount, 6)) },
    ScenarioStep("folder-reorder") {
        runOpenFolderMoves(count: dragCount)
        setExpanded("Alpha", children: alphaChildren, false)
        setExpanded("Beta", children: betaChildren, false)
        runFolderReorder("folder-collapsed", count: dragCount)
        runFolderPastSession(count: min(dragCount, 6))
        setExpanded("Alpha", children: alphaChildren, true)
        runBetaPastExpandedAlpha(count: dragCount)
        setExpanded("Beta", children: betaChildren, true)
        runOpenFolderLastMoves()
    },
    ScenarioStep("cross-project-insert", runsByDefault: false) { runCrossProjectInsert(count: min(dragCount, 6)) },
    ScenarioStep("session-above-folder", runsByDefault: false) {
        setExpanded("Alpha", children: alphaChildren, false)
        setExpanded("Beta", children: betaChildren, false)
        runSessionAboveFolder(count: min(dragCount, 6))
        setExpanded("Alpha", children: alphaChildren, true)
        setExpanded("Beta", children: betaChildren, true)
    },
    ScenarioStep("folder-persisted", runsByDefault: false) { runFolderPersisted() },
    ScenarioStep("pinned-persisted", runsByDefault: false) { runPinnedPersisted() },
    ScenarioStep("folder-pinned") { runPinnedFolders(count: dragCount) },
    ScenarioStep("project-reorder") {
        setExpanded("Small", children: smallChildren, true)
        runProjectReorder(count: dragCount)
    },
]

/// What `--only` takes.
let knownScenarios = Set(scenarioSteps.map(\.name))

func wanted(_ step: ScenarioStep) -> Bool { only?.contains(step.name) ?? step.runsByDefault }
