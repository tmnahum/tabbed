import XCTest
@testable import Tabbed

final class SessionConfigTests: XCTestCase {
    private let key = "sessionConfig"
    private var savedData: Data?

    override func setUp() {
        super.setUp()
        savedData = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let savedData {
            UserDefaults.standard.set(savedData, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testDefaultKeepsUnmatchedAutoCaptureDisabled() {
        XCTAssertFalse(SessionConfig.default.autoCaptureUnmatchedToNewGroup)
    }

    func testDecodeLegacyConfigDefaultsUnmatchedAutoCaptureToDisabled() throws {
        let legacyJSON = #"{"restoreMode":"smart","autoCaptureMode":"always"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: legacyJSON)

        XCTAssertEqual(decoded.restoreMode, .smart)
        XCTAssertEqual(decoded.autoCaptureMode, .always)
        XCTAssertFalse(decoded.autoCaptureUnmatchedToNewGroup)
    }

    func testDecodeLegacyBoolAutoCaptureEnabledStillMigrates() throws {
        let legacyJSON = #"{"restoreMode":"off","autoCaptureEnabled":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: legacyJSON)

        XCTAssertEqual(decoded.restoreMode, .off)
        XCTAssertEqual(decoded.autoCaptureMode, .whenMaximized)
        XCTAssertFalse(decoded.autoCaptureUnmatchedToNewGroup)
    }

    func testSaveAndLoadRoundTripPreservesUnmatchedAutoCaptureSetting() {
        let config = SessionConfig(
            restoreMode: .always,
            autoCaptureMode: .whenOnly,
            autoCaptureUnmatchedToNewGroup: true
        )

        config.save()
        let loaded = SessionConfig.load()

        XCTAssertEqual(loaded, config)
    }
}
