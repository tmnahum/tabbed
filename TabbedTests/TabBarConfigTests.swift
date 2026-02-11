import XCTest
@testable import Tabbed

final class TabBarConfigTests: XCTestCase {
    private var savedConfigData: Data?

    override func setUp() {
        super.setUp()
        savedConfigData = UserDefaults.standard.data(forKey: "tabBarConfig")
        UserDefaults.standard.removeObject(forKey: "tabBarConfig")
    }

    override func tearDown() {
        if let data = savedConfigData {
            UserDefaults.standard.set(data, forKey: "tabBarConfig")
        } else {
            UserDefaults.standard.removeObject(forKey: "tabBarConfig")
        }
        super.tearDown()
    }

    func testDefaultStyle() {
        let config = TabBarConfig()
        XCTAssertEqual(config.style, .compact)
        XCTAssertTrue(config.showDragHandle)
        XCTAssertEqual(config.closeButtonMode, .xmarkOnAllTabs)
        XCTAssertTrue(config.showCloseConfirmation)
    }

    func testSaveAndLoad() {
        let config = TabBarConfig(style: .equal)
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.style, .equal)
    }

    func testLoadReturnsDefaultWhenNoSavedData() {
        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.style, .compact)
    }

    func testSaveOverwritesPreviousValue() {
        let config1 = TabBarConfig(style: .equal)
        config1.save()

        let config2 = TabBarConfig(style: .compact)
        config2.save()

        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.style, .compact)
    }

    func testRoundTripEncoding() throws {
        let original = TabBarConfig(
            style: .compact,
            showDragHandle: false,
            showTooltip: false,
            closeButtonMode: .minusOnCurrentTab,
            showCloseConfirmation: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabBarConfig.self, from: data)
        XCTAssertEqual(decoded.style, .compact)
        XCTAssertFalse(decoded.showDragHandle)
        XCTAssertFalse(decoded.showTooltip)
        XCTAssertEqual(decoded.closeButtonMode, .minusOnCurrentTab)
        XCTAssertFalse(decoded.showCloseConfirmation)
    }

    func testDecodesWithMissingStyleKey() throws {
        // Simulate old config without style key
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TabBarConfig.self, from: json)
        XCTAssertEqual(decoded.style, .compact)
        XCTAssertTrue(decoded.showDragHandle)
        XCTAssertTrue(decoded.showTooltip)
        XCTAssertEqual(decoded.closeButtonMode, .xmarkOnAllTabs)
        XCTAssertTrue(decoded.showCloseConfirmation)
    }

    func testSaveAndLoadDragHandle() {
        let config = TabBarConfig(style: .compact, showDragHandle: false)
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertFalse(loaded.showDragHandle)
    }

    func testSaveAndLoadCloseButtonModeAndConfirmation() {
        let config = TabBarConfig(
            style: .compact,
            closeButtonMode: .minusOnAllTabs,
            showCloseConfirmation: false
        )
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.closeButtonMode, .minusOnAllTabs)
        XCTAssertFalse(loaded.showCloseConfirmation)
    }
}
