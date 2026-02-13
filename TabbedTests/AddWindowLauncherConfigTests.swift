import XCTest
@testable import Tabbed

final class AddWindowLauncherConfigTests: XCTestCase {
    private var savedConfigData: Data?

    override func setUp() {
        super.setUp()
        savedConfigData = UserDefaults.standard.data(forKey: "addWindowLauncherConfig")
        UserDefaults.standard.removeObject(forKey: "addWindowLauncherConfig")
    }

    override func tearDown() {
        if let data = savedConfigData {
            UserDefaults.standard.set(data, forKey: "addWindowLauncherConfig")
        } else {
            UserDefaults.standard.removeObject(forKey: "addWindowLauncherConfig")
        }
        super.tearDown()
    }

    func testDefaults() {
        let config = AddWindowLauncherConfig.default
        XCTAssertTrue(config.urlLaunchEnabled)
        XCTAssertTrue(config.searchLaunchEnabled)
        XCTAssertEqual(config.searchEngine, .unduck)
        XCTAssertEqual(config.customSearchTemplate, SearchEngine.defaultTemplate)
        XCTAssertEqual(config.urlProviderSelection.engine, .chromium)
        XCTAssertEqual(config.urlProviderSelection.bundleID, "")
        XCTAssertEqual(config.searchProviderSelection.engine, .chromium)
        XCTAssertEqual(config.searchProviderSelection.bundleID, "")
    }

    func testSaveLoadRoundTrip() {
        let config = AddWindowLauncherConfig(
            urlLaunchEnabled: false,
            searchLaunchEnabled: true,
            urlProviderSelection: BrowserProviderSelection(bundleID: "com.google.Chrome", engine: .chromium),
            searchProviderSelection: BrowserProviderSelection(bundleID: "org.mozilla.firefox", engine: .firefox),
            searchEngine: .custom,
            customSearchTemplate: "https://example.com/search?q=%s"
        )

        config.save()
        let loaded = AddWindowLauncherConfig.load()

        XCTAssertEqual(loaded, config)
    }

    func testBackwardCompatibleDecodeWithMissingKeys() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AddWindowLauncherConfig.self, from: json)
        XCTAssertEqual(decoded, .default)
    }

    func testBackwardCompatibleDecodeMirrorsLegacyCombinedToggleForSearch() throws {
        let json = """
        {
          "urlLaunchEnabled": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AddWindowLauncherConfig.self, from: json)

        XCTAssertFalse(decoded.urlLaunchEnabled)
        XCTAssertFalse(decoded.searchLaunchEnabled)
    }

    func testUnknownLegacySearchEngineValueDecodesToUnduck() throws {
        let json = """
        {
          "searchEngine": "legacyProvider"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AddWindowLauncherConfig.self, from: json)

        XCTAssertEqual(decoded.searchEngine, .unduck)
    }

    func testLegacyManualSelectionMigratesToURLAndSearchProviderSelections() throws {
        let json = """
        {
          "manualSelection": {
            "bundleID": "org.mozilla.firefox",
            "engine": "firefox"
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AddWindowLauncherConfig.self, from: json)

        XCTAssertEqual(decoded.urlProviderSelection.bundleID, "org.mozilla.firefox")
        XCTAssertEqual(decoded.urlProviderSelection.engine, .firefox)
        XCTAssertEqual(decoded.searchProviderSelection.bundleID, "org.mozilla.firefox")
        XCTAssertEqual(decoded.searchProviderSelection.engine, .firefox)
    }

    func testApplyPreferredProviderSelectionsIfNeededSetsBothProvidersWhenUnset() {
        let resolver = BrowserProviderResolver(appURLLookup: { bundleID in
            switch bundleID {
            case "com.google.Chrome":
                return URL(fileURLWithPath: "/Applications/Google Chrome.app")
            default:
                return nil
            }
        })

        var config = AddWindowLauncherConfig.default
        let changed = config.applyPreferredProviderSelectionsIfNeeded(resolver: resolver)

        XCTAssertTrue(changed)
        XCTAssertEqual(config.urlProviderSelection.bundleID, "com.google.Chrome")
        XCTAssertEqual(config.urlProviderSelection.engine, .chromium)
        XCTAssertEqual(config.searchProviderSelection.bundleID, "com.google.Chrome")
        XCTAssertEqual(config.searchProviderSelection.engine, .chromium)
    }

    func testApplyPreferredProviderSelectionsIfNeededPrefersHeliumWhenInstalled() {
        let resolver = BrowserProviderResolver(appURLLookup: { bundleID in
            switch bundleID {
            case BrowserProviderResolver.heliumBundleID:
                return URL(fileURLWithPath: "/Applications/Helium.app")
            case "com.google.Chrome":
                return URL(fileURLWithPath: "/Applications/Google Chrome.app")
            default:
                return nil
            }
        })

        var config = AddWindowLauncherConfig.default
        let changed = config.applyPreferredProviderSelectionsIfNeeded(resolver: resolver)

        XCTAssertTrue(changed)
        XCTAssertEqual(config.urlProviderSelection.bundleID, BrowserProviderResolver.heliumBundleID)
        XCTAssertEqual(config.urlProviderSelection.engine, .chromium)
        XCTAssertEqual(config.searchProviderSelection.bundleID, BrowserProviderResolver.heliumBundleID)
        XCTAssertEqual(config.searchProviderSelection.engine, .chromium)
    }

    func testApplyPreferredProviderSelectionsIfNeededCopiesURLProviderToSearchWhenSearchUnset() {
        let resolver = BrowserProviderResolver(appURLLookup: { _ in nil })
        var config = AddWindowLauncherConfig(
            urlProviderSelection: BrowserProviderSelection(bundleID: "org.mozilla.firefox", engine: .firefox),
            searchProviderSelection: BrowserProviderSelection(bundleID: "", engine: .chromium)
        )

        let changed = config.applyPreferredProviderSelectionsIfNeeded(resolver: resolver)

        XCTAssertTrue(changed)
        XCTAssertEqual(config.searchProviderSelection.bundleID, "org.mozilla.firefox")
        XCTAssertEqual(config.searchProviderSelection.engine, .firefox)
    }
}
