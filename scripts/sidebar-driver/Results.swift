import Foundation

func log(_ line: String) {
    print(line)
    fflush(stdout)
}

final class Scenario {
    let name: String
    var passed = 0
    var failed = 0
    var details: [String] = []
    init(_ name: String) { self.name = name }

    func pass() { passed += 1 }
    func fail(_ detail: String) {
        failed += 1
        details.append(detail)
        log("  FAIL \(name) #\(passed + failed): \(detail)")
    }
}

var scenarios: [Scenario] = []

func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < end
    return condition()
}
