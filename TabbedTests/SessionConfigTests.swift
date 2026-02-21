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
        XCTAssertTrue(SessionConfig.default.autoCaptureRequireResizableToMatchGroup)
    }

    func testDecodeLegacyConfigDefaultsUnmatchedAutoCaptureToDisabled() throws {
        let legacyJSON = #"{"restoreMode":"smart","autoCaptureMode":"always"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: legacyJSON)

        XCTAssertEqual(decoded.restoreMode, .smart)
        XCTAssertEqual(decoded.autoCaptureMode, .always)
        XCTAssertFalse(decoded.autoCaptureUnmatchedToNewGroup)
        XCTAssertTrue(decoded.autoCaptureRequireResizableToMatchGroup)
    }

    func testDecodeLegacyBoolAutoCaptureEnabledStillMigrates() throws {
        let legacyJSON = #"{"restoreMode":"off","autoCaptureEnabled":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: legacyJSON)

        XCTAssertEqual(decoded.restoreMode, .off)
        XCTAssertEqual(decoded.autoCaptureMode, .whenMaximized)
        XCTAssertFalse(decoded.autoCaptureUnmatchedToNewGroup)
        XCTAssertTrue(decoded.autoCaptureRequireResizableToMatchGroup)
    }

    func testSaveAndLoadRoundTripPreservesUnmatchedAutoCaptureSetting() {
        let config = SessionConfig(
            restoreMode: .always,
            autoCaptureMode: .whenOnly,
            autoCaptureUnmatchedToNewGroup: true,
            autoCaptureRequireResizableToMatchGroup: false
        )

        config.save()
        let loaded = SessionConfig.load()

        XCTAssertEqual(loaded, config)
    }

    func testDecodeSupportsMaximizedOrOnlyMode() throws {
        let json = #"{"restoreMode":"smart","autoCaptureMode":"whenMaximizedOrOnly","autoCaptureUnmatchedToNewGroup":false,"autoCaptureRequireResizableToMatchGroup":false}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionConfig.self, from: json)

        XCTAssertEqual(decoded.restoreMode, .smart)
        XCTAssertEqual(decoded.autoCaptureMode, .whenMaximizedOrOnly)
        XCTAssertFalse(decoded.autoCaptureUnmatchedToNewGroup)
        XCTAssertFalse(decoded.autoCaptureRequireResizableToMatchGroup)
    }
}
