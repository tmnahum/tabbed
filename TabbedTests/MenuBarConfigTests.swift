import XCTest
@testable import Tabbed

final class MenuBarConfigTests: XCTestCase {
    private var savedConfigData: Data?

    override func setUp() {
        super.setUp()
        savedConfigData = UserDefaults.standard.data(forKey: "menuBarConfig")
        UserDefaults.standard.removeObject(forKey: "menuBarConfig")
    }

    override func tearDown() {
        if let savedConfigData {
            UserDefaults.standard.set(savedConfigData, forKey: "menuBarConfig")
        } else {
            UserDefaults.standard.removeObject(forKey: "menuBarConfig")
        }
        super.tearDown()
    }

    func testDefaultsToShowingUngroupedWindows() {
        XCTAssertTrue(MenuBarConfig.load().showUngroupedWindows)
    }

    func testSavesDisabledSetting() {
        let config = MenuBarConfig()
        config.showUngroupedWindows = false

        XCTAssertFalse(MenuBarConfig.load().showUngroupedWindows)
    }

    func testOlderEmptyConfigUsesDefault() throws {
        let data = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(MenuBarConfig.self, from: data)

        XCTAssertTrue(config.showUngroupedWindows)
    }
}
