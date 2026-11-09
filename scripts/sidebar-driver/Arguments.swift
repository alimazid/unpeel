import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? ""
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let only = option("--only").map { Set($0.split(separator: ",").map(String.init)) }

/// The app under test. Without a usable --pid, the first read ends the run with
/// the usage line, so `main.swift` reads it before anything else can.
let pid: pid_t = {
    guard let value = option("--pid").flatMap({ pid_t($0) }) else {
        print("usage: driver check|prepare|run --pid P [--ls script] [--home DIR] [--clicks N] [--drags N] [--only a,b] [--report F] [--scale S]")
        exit(2)
    }
    return value
}()
let clickCount = option("--clicks").flatMap(Int.init) ?? 30
let dragCount = option("--drags").flatMap(Int.init) ?? 20
let listScript = option("--ls")
let fixtureHome = option("--home")
let wantedScale = option("--scale").flatMap(Double.init).map { CGFloat($0) }
let reportPath = option("--report")
let quietSeconds = option("--quiet").flatMap(Double.init) ?? 20
