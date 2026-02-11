import XCTest
@testable import Tabbed
import ApplicationServices

final class BrowserProviderResolverTests: XCTestCase {

    func testAutoPrefersHeliumWhenInstalled() {
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

        let provider = resolver.resolve(config: .default)
        XCTAssertEqual(provider?.selection.bundleID, BrowserProviderResolver.heliumBundleID)
        XCTAssertEqual(provider?.selection.engine, .chromium)
    }

    func testManualModeOverridesAutoSelection() {
        let resolver = BrowserProviderResolver(appURLLookup: { bundleID in
            switch bundleID {
            case BrowserProviderResolver.heliumBundleID:
                return URL(fileURLWithPath: "/Applications/Helium.app")
            case "org.mozilla.firefox":
                return URL(fileURLWithPath: "/Applications/Firefox.app")
            default:
                return nil
            }
        })

        let config = AddWindowLauncherConfig(
            urlLaunchEnabled: true,
            providerMode: .manual,
            searchEngine: .google,
            manualSelection: BrowserProviderSelection(bundleID: "org.mozilla.firefox", engine: .firefox)
        )

        let provider = resolver.resolve(config: config)
        XCTAssertEqual(provider?.selection.bundleID, "org.mozilla.firefox")
        XCTAssertEqual(provider?.selection.engine, .firefox)
    }

    func testDisabledURLActionsRemoveURLCandidates() {
        let engine = LauncherEngine()
        let config = AddWindowLauncherConfig(
            urlLaunchEnabled: false,
            providerMode: .auto,
            searchEngine: .google,
            manualSelection: BrowserProviderSelection()
        )

        let context = LauncherQueryContext(
            mode: .newGroup,
            looseWindows: [
                WindowInfo(
                    id: 1,
                    element: AXUIElementCreateSystemWide(),
                    ownerPID: 1,
                    bundleID: "com.test.one",
                    title: "Test",
                    appName: "App",
                    icon: nil
                )
            ],
            mergeGroups: [],
            appCatalog: [],
            launcherConfig: config,
            resolvedBrowserProvider: nil,
            currentSpaceID: nil,
            windowRecency: [:],
            groupRecency: [:],
            appRecency: [:]
        )

        let ranked = engine.rank(query: "example.com", context: context)
        let hasURLOrSearch = ranked.contains { candidate in
            if case .openURL = candidate.action { return true }
            if case .webSearch = candidate.action { return true }
            return false
        }

        XCTAssertFalse(hasURLOrSearch)
    }

    func testManualSelectionDetectsKnownChromiumEngine() {
        let resolver = BrowserProviderResolver(appURLLookup: { _ in nil })
        let selection = resolver.manualSelection(forBundleID: " com.google.Chrome ", fallbackEngine: .firefox)

        XCTAssertEqual(selection.bundleID, "com.google.Chrome")
        XCTAssertEqual(selection.engine, .chromium)
    }

    func testManualSelectionDetectsKnownFirefoxEngine() {
        let resolver = BrowserProviderResolver(appURLLookup: { _ in nil })
        let selection = resolver.manualSelection(forBundleID: "org.mozilla.firefox", fallbackEngine: .chromium)

        XCTAssertEqual(selection.bundleID, "org.mozilla.firefox")
        XCTAssertEqual(selection.engine, .firefox)
    }

    func testManualSelectionFallsBackForUnknownBundle() {
        let resolver = BrowserProviderResolver(appURLLookup: { _ in nil })
        let selection = resolver.manualSelection(forBundleID: "com.example.CustomBrowser", fallbackEngine: .firefox)

        XCTAssertEqual(selection.bundleID, "com.example.CustomBrowser")
        XCTAssertEqual(selection.engine, .firefox)
    }
}
