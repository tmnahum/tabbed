import XCTest
@testable import Tabbed

final class SessionRestoreDiagnosticsTests: XCTestCase {
    func testParseBoolRecognizesTruthyValues() {
        XCTAssertEqual(SessionRestoreDiagnostics.parseBool("1"), true)
        XCTAssertEqual(SessionRestoreDiagnostics.parseBool("true"), true)
        XCTAssertEqual(SessionRestoreDiagnostics.parseBool("YES"), true)
        XCTAssertEqual(SessionRestoreDiagnostics.parseBool(" on "), true)
    }

    func testParseBoolRecognizesFalseyValues() {
        XCTAssertEqual(SessionRestoreDiagnostics.parseBool("0"), false)
        XCTAssertEqual(SessionRestoreDiagnostics.parseBool("false"), false)
        XCTAssertEqual(SessionRestoreDiagnostics.parseBool("No"), false)
        XCTAssertEqual(SessionRestoreDiagnostics.parseBool(" off "), false)
    }

    func testParseBoolReturnsNilForUnknownValues() {
        XCTAssertNil(SessionRestoreDiagnostics.parseBool(""))
        XCTAssertNil(SessionRestoreDiagnostics.parseBool("maybe"))
    }

    func testIsEnabledUsesUserDefaultsWhenEnvironmentMissing() {
        let suiteName = "SessionRestoreDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: SessionRestoreDiagnostics.userDefaultsKey)

        XCTAssertTrue(SessionRestoreDiagnostics.isEnabled(userDefaults: defaults, environment: [:]))
    }

    func testIsEnabledPrefersEnvironmentOverride() {
        let suiteName = "SessionRestoreDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: SessionRestoreDiagnostics.userDefaultsKey)

        let enabledEnv = [SessionRestoreDiagnostics.environmentKey: "1"]
        XCTAssertTrue(SessionRestoreDiagnostics.isEnabled(userDefaults: defaults, environment: enabledEnv))

        let disabledEnv = [SessionRestoreDiagnostics.environmentKey: "false"]
        XCTAssertFalse(SessionRestoreDiagnostics.isEnabled(userDefaults: defaults, environment: disabledEnv))
    }
}
