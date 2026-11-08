import Foundation
import UnpeelNativeTestHome
import XCTest
@testable import UnpeelNative

/// Fork-only (#44): this bundle never resolves the real ~/.unpeel or the
/// real app's defaults. `UnpeelNativeTestHome` sets a private UNPEEL_HOME
/// before any test runs, unless the caller already chose one.
final class TestHomeIsolationTests: XCTestCase {
    private var realUnpeelDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".unpeel").standardizedFileURL.path
    }

    func testTheBundleNeverResolvesTheRealUnpeelHome() throws {
        let home = LaunchConfig.unpeelDir.standardizedFileURL.path
        XCTAssertFalse(
            home == realUnpeelDir || home.hasPrefix(realUnpeelDir + "/"),
            "the test bundle resolved its Unpeel home to \(home), inside the real \(realUnpeelDir)"
        )
        let configured = try XCTUnwrap(ProcessInfo.processInfo.environment["UNPEEL_HOME"])
        XCTAssertEqual(
            home, URL(fileURLWithPath: configured).standardizedFileURL.path,
            "LaunchConfig.unpeelDir must be the home the bundle runs under"
        )
        if let created = unpeel_native_test_home_created() {
            XCTAssertEqual(String(cString: created), configured)
        }
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: configured)[.type] as? FileAttributeType,
            .typeDirectory,
            "the home is a real directory, never a symlink"
        )
    }

    func testResettingASymlinkedSlotNeverTouchesItsTarget() throws {
        let root = try scratchDirectory()
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep"))
        let slot = root.appendingPathComponent("slot")
        try FileManager.default.createSymbolicLink(at: slot, withDestinationURL: target)

        XCTAssertTrue(unpeel_native_test_home_reset(slot.path))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("keep").path),
            "a symlinked slot's target survives the reset"
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: slot.path)[.type] as? FileAttributeType,
            .typeDirectory
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: slot.path), [])
    }

    func testResettingAHomeEmptiesItWithoutFollowingLinksInside() throws {
        let root = try scratchDirectory()
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep"))
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("app-sessions"), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: home.appendingPathComponent("app-state.json"))
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("link"), withDestinationURL: target
        )

        XCTAssertTrue(unpeel_native_test_home_reset(home.path))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("keep").path))
    }

    func testAppDefaultsIsTheHomesPrivateSuite() throws {
        let configured = try XCTUnwrap(ProcessInfo.processInfo.environment["UNPEEL_HOME"])
        var buffer = [CChar](repeating: 0, count: 128)
        XCTAssertTrue(unpeel_native_test_home_suite_name(configured, &buffer, buffer.count))
        let suiteName = String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let key = "unpeel.native.testHomeIsolation.\(UUID().uuidString)"
        AppDefaults.shared.set(true, forKey: key)
        defer { AppDefaults.shared.removeObject(forKey: key) }

        XCTAssertEqual(
            UserDefaults(suiteName: suiteName)?.object(forKey: key) as? Bool, true,
            "AppDefaults.shared must be the private home's suite \(suiteName)"
        )
        XCTAssertNil(
            UserDefaults.standard.object(forKey: key),
            "AppDefaults.shared fell back to .standard"
        )
        XCTAssertNil(
            UserDefaults(suiteName: "com.unpeel.native")?.object(forKey: key),
            "AppDefaults.shared wrote into the real app's defaults"
        )
    }

    private func scratchDirectory() throws -> URL {
        let root = LaunchConfig.unpeelDir
            .appendingPathComponent("reset-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testTheBundleNeverStartsAHost() {
        XCTAssertNotNil(
            ProcessInfo.processInfo.environment["UNPEEL_TEST_NATIVE_SUITE"],
            "HostServiceManager.ensureStarted skips UNPEEL_TEST_* processes"
        )
        if ProcessInfo.processInfo.environment["UNPEEL_HOST_CMD"] == "/usr/bin/false" {
            XCTAssertEqual(LaunchConfig.hostBinary, "/usr/bin/false", "a scoped gateway spawns nothing")
        }
    }
}
