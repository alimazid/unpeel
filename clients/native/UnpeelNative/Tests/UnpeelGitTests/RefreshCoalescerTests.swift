import XCTest
@testable import UnpeelGit

@MainActor
final class RefreshCoalescerTests: XCTestCase {
    func testABurstIsOneRun() async {
        let coalescer = RefreshCoalescer()
        var runs = 0

        let tasks = (0..<5).map { _ in coalescer.request(debounce: 0.05) { runs += 1 } }
        for task in tasks { await task.value }

        XCTAssertEqual(runs, 1)
        XCTAssertNil(coalescer.current)
    }

    /// Requests that arrive while a run is in progress cost exactly one
    /// more run, however many there are.
    func testRequestsDuringARunCostOneMore() async {
        let coalescer = RefreshCoalescer()
        var runs = 0
        let first = coalescer.request(debounce: 0) {
            runs += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)

        for _ in 0..<3 { coalescer.request(debounce: 0) { runs += 1 } }
        await first.value

        XCTAssertEqual(runs, 2)
    }

    func testResetDropsARunStillWaiting() async throws {
        let coalescer = RefreshCoalescer()
        var runs = 0
        let waiting = coalescer.request(debounce: 0.1) { runs += 1 }

        coalescer.reset()
        await waiting.value

        XCTAssertEqual(runs, 0)
        XCTAssertNil(coalescer.current)
        await coalescer.request(debounce: 0) { runs += 1 }.value
        XCTAssertEqual(runs, 1, "a request after the reset starts afresh")
    }
}
