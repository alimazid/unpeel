// main.swift — the driver behind verify-sidebar-interaction.sh. It clicks and
// drags PROJECTS rows in a running dev app with real pointer events and checks
// every step against the app's accessibility tree and the Host's session list.
//
//   driver check [--only a,b]
//   driver prepare --pid P [--window-height H] [--scale S]
//   driver run --pid P --ls <script> --home DIR [--clicks N] [--drags N] [--only a,b] [--report F] [--scale S]
//
// It never fights the user: it starts only after the machine has been quiet,
// and any pointer motion or key press it did not make pauses the run, releases
// the button in place, and resumes after the user has been quiet again.
//
// Only this file runs statements, in order. A global here reads as zero until its
// line has run, so anything another file reads is declared in that file instead.
import AppKit
import ApplicationServices

if command == "locked" { exit(screenIsLocked() ? 0 : 1) }

if let only {
    let unknown = only.subtracting(knownScenarios).sorted()
    guard !only.isEmpty, unknown.isEmpty else {
        print("--only: no scenario named '\(unknown.joined(separator: ","))'; there are: "
            + knownScenarios.sorted().joined(separator: ","))
        exit(2)
    }
}
if command == "check" { exit(0) }

_ = pid

if command == "prepare" {
    guard let window = mainWindow() else {
        print("no window")
        exit(1)
    }
    var origin = CGPoint(x: 60, y: 60)
    var size = CGSize(width: 1100, height: option("--window-height").flatMap(Double.init) ?? 1280)
    if let wantedScale {
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor == wantedScale }) else {
            print("no display at \(wantedScale)x")
            exit(1)
        }
        let area = topDown(screen.visibleFrame)
        origin = CGPoint(x: area.minX + 60, y: area.minY + 10)
        size.height = min(size.height, area.height - 20)
    }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    print(summary(labels(readRows())))
    exit(0)
}

guard AXIsProcessTrusted() else {
    print("this process needs Accessibility permission")
    exit(2)
}

waitForQuiet()
NSRunningApplication(processIdentifier: pid)?.activate(options: [])
Thread.sleep(forTimeInterval: 0.6)
let scale = windowScale()
log("display scale: \(scale.map { "\($0)x" } ?? "unknown")")
if let wantedScale, scale != wantedScale {
    log("the window is not on a \(wantedScale)x display")
    exit(1)
}
log("rows: \(summary(labels(readRows())))")

for step in scenarioSteps where wanted(step) { step.run() }

guard !scenarios.isEmpty else {
    log("no scenario ran")
    exit(2)
}
log("")
log("scenario                passed  failed")
for scenario in scenarios {
    log(scenario.name.padding(toLength: 24, withPad: " ", startingAt: 0)
        + String(format: "%6d  %6d", scenario.passed, scenario.failed))
}
let failures = scenarios.reduce(0) { $0 + $1.failed }
log("total failures: \(failures); user pauses: \(pauses)")
if let reportPath {
    let report = scenarios.map { ["name": $0.name, "passed": $0.passed, "failed": $0.failed, "details": $0.details] as [String: Any] }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
        FileManager.default.createFile(atPath: reportPath, contents: data)
    }
}
exit(failures == 0 ? 0 : 1)
