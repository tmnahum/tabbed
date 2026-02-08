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
        XCTAssertEqual(config.style, .equal)
    }

    func testSaveAndLoad() {
        let config = TabBarConfig(style: .compact)
        config.save()

        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.style, .compact)
    }

    func testLoadReturnsDefaultWhenNoSavedData() {
        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.style, .equal)
    }

    func testSaveOverwritesPreviousValue() {
        let config1 = TabBarConfig(style: .compact)
        config1.save()

        let config2 = TabBarConfig(style: .equal)
        config2.save()

        let loaded = TabBarConfig.load()
        XCTAssertEqual(loaded.style, .equal)
    }

    func testRoundTripEncoding() throws {
        let original = TabBarConfig(style: .compact)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabBarConfig.self, from: data)
        XCTAssertEqual(decoded.style, .compact)
    }

    func testDecodesWithMissingStyleKey() throws {
        // Simulate old config without style key
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TabBarConfig.self, from: json)
        XCTAssertEqual(decoded.style, .equal)
    }
}
