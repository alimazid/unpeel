import XCTest
@testable import UnpeelMarkdownPreview

@MainActor
final class MarkdownFileObserverTests: XCTestCase {
    private var file: URL!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-observer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("doc.md")
        try Data("one".utf8).write(to: file)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testWriteFiresOnceAfterDebounce() throws {
        let fired = expectation(description: "change")
        var count = 0
        let observer = MarkdownFileObserver(path: file.path, debounce: 0.05) {
            count += 1
            if count == 1 { fired.fulfill() }
        }
        observer.start()
        defer { observer.stop() }
        try Data("two".utf8).write(to: file)
        try Data("three".utf8).write(to: file)
        wait(for: [fired], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(count, 1)
    }

    func testAtomicReplaceIsObservedAndTheObserverReArms() throws {
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        var count = 0
        let observer = MarkdownFileObserver(path: file.path, debounce: 0.05) {
            count += 1
            if count == 1 { first.fulfill() }
            if count == 2 { second.fulfill() }
        }
        observer.start()
        defer { observer.stop() }
        // Editors save atomically: write a sibling, then rename over the file.
        let temp = file.deletingLastPathComponent().appendingPathComponent("doc.md.tmp")
        try Data("atomic".utf8).write(to: temp)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        wait(for: [first], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try Data("again".utf8).write(to: file)
        wait(for: [second], timeout: 2)
    }

    func testStopDuringReopenWindowDoesNotResume() throws {
        var count = 0
        let observer = MarkdownFileObserver(path: file.path, debounce: 0.05) {
            count += 1
        }
        observer.start()
        // Atomic replace triggers delete/rename, which schedules a reopen
        // ~0.1s out; stopping right away must cancel that reopen too.
        let temp = file.deletingLastPathComponent().appendingPathComponent("doc.md.tmp")
        try Data("atomic".utf8).write(to: temp)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
        // Let the vnode event land first so the reopen IS scheduled; an
        // immediate `stop()` would cancel the source before any reopen
        // existed and the test would pass against an observer that never
        // cancels it.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        observer.stop()
        let countAtStop = count
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try Data("again".utf8).write(to: file)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(count, countAtStop)
    }

    // Fork-only: markdown preview pane — I1: the observer must keep retrying
    // past the first reopen window, not go permanently dead on one miss.
    func testFileReturningAfterALongAbsenceIsObservedAgain() throws {
        var count = 0
        let observer = MarkdownFileObserver(path: file.path, debounce: 0.05) {
            count += 1
        }
        observer.start()
        defer { observer.stop() }
        try FileManager.default.removeItem(at: file)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        try Data("returned".utf8).write(to: file)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let countAfterSpin = count
        try Data("again".utf8).write(to: file)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertGreaterThan(count, countAfterSpin)
    }
}
