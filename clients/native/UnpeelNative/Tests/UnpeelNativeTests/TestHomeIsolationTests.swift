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
    }

    func testAppDefaultsIsTheHomesPrivateSuite() throws {
        let configured = try XCTUnwrap(ProcessInfo.processInfo.environment["UNPEEL_HOME"])
        var buffer = [CChar](repeating: 0, count: 128)
        XCTAssertTrue(unpeel_native_test_home_suite_name(configured, &buffer, buffer.count))
        let suiteName = String(cString: buffer)
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
