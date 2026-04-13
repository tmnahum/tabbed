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
        XCTAssertTrue(config.superpinnedTabsBeforeHandle)
        XCTAssertEqual(config.closeButtonMode, .xmarkOnAllTabs)
        XCTAssertTrue(config.showCloseConfirmation)
        XCTAssertTrue(config.quitAppWhenLastWindowClosed)
        XCTAssertEqual(config.groupCounterMode, .maximizedOnly)
        XCTAssertTrue(config.showMaximizedGroupCounters)
        XCTAssertFalse(config.multiGroupCounterStartsAtZero)
        XCTAssertFalse(config.fullscreenModeKeepsResizedWindows)
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
            superpinnedTabsBeforeHandle: false,
            showTooltip: false,
            closeButtonMode: .minusOnCurrentTab,
            showCloseConfirmation: false,
            quitAppWhenLastWindowClosed: false,
            groupCounterMode: .disabled,
            multiGroupCounterStartsAtZero: true,
            fullscreenModeKeepsResizedWindows: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabBarConfig.self, from: data)
        XCTAssertEqual(decoded.style, .compact)
        XCTAssertFalse(decoded.showDragHandle)
        XCTAssertFalse(decoded.superpinnedTabsBeforeHandle)
        XCTAssertFalse(decoded.showTooltip)
        XCTAssertEqual(decoded.closeButtonMode, .minusOnCurrentTab)
        XCTAssertFalse(decoded.showCloseConfirmation)
        XCTAssertFalse(decoded.quitAppWhenLastWindowClosed)
        XCTAssertEqual(decoded.groupCounterMode, .disabled)
        XCTAssertFalse(decoded.showMaximizedGroupCounters)
        XCTAssertTrue(decoded.multiGroupCounterStartsAtZero)
        XCTAssertTrue(decoded.fullscreenModeKeepsResizedWindows)
    }

    func testDecodesWithMissingStyleKey() throws {
        // Simulate old config without style key
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TabBarConfig.self, from: json)
        XCTAssertEqual(decoded.style, .compact)
        XCTAssertTrue(decoded.showDragHandle)
        XCTAssertTrue(decoded.superpinnedTabsBeforeHandle)
        XCTAssertTrue(decoded.showTooltip)
        XCTAssertEqual(decoded.closeButtonMode, .xmarkOnAllTabs)
        XCTAssertTrue(decoded.showCloseConfirmation)
        XCTAssertTrue(decoded.quitAppWhenLastWindowClosed)
        XCTAssertEqual(decoded.groupCounterMode, .maximizedOnly)
        XCTAssertTrue(decoded.showMaximizedGroupCounters)
        XCTAssertFalse(decoded.multiGroupCounterStartsAtZero)
        XCTAssertFalse(decoded.fullscreenModeKeepsResizedWindows)
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
            showCloseConfirmation: false,
            quitAppWhenLastWindowClosed: false
        )
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.closeButtonMode, .minusOnAllTabs)
        XCTAssertFalse(loaded.showCloseConfirmation)
        XCTAssertFalse(loaded.quitAppWhenLastWindowClosed)
    }

    func testSaveAndLoadSuperpinnedBeforeHandleToggle() {
        let config = TabBarConfig(style: .compact, superpinnedTabsBeforeHandle: false)
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertFalse(loaded.superpinnedTabsBeforeHandle)
    }

    func testSaveAndLoadMaximizedGroupCountersToggle() {
        let config = TabBarConfig(style: .compact, showMaximizedGroupCounters: false)
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.groupCounterMode, .disabled)
        XCTAssertFalse(loaded.showMaximizedGroupCounters)
    }

    func testSaveAndLoadGroupCounterMode() {
        let config = TabBarConfig(style: .compact, groupCounterMode: .maximizedAndPositionAligned)
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.groupCounterMode, .maximizedAndPositionAligned)
        XCTAssertTrue(loaded.showMaximizedGroupCounters)
    }

    func testLegacyBoolDecodesIntoGroupCounterMode() throws {
        let json = #"{"showMaximizedGroupCounters":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TabBarConfig.self, from: json)
        XCTAssertEqual(decoded.groupCounterMode, .disabled)
        XCTAssertFalse(decoded.showMaximizedGroupCounters)
        XCTAssertFalse(decoded.multiGroupCounterStartsAtZero)
    }

    func testSaveAndLoadMultiGroupCounterStartsAtZero() {
        let config = TabBarConfig(style: .compact, multiGroupCounterStartsAtZero: true)
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertTrue(loaded.multiGroupCounterStartsAtZero)
    }

    func testSaveAndLoadFullscreenModeKeepsResizedWindows() {
        let config = TabBarConfig(style: .compact, fullscreenModeKeepsResizedWindows: true)
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertTrue(loaded.fullscreenModeKeepsResizedWindows)
    }
}
