import XCTest
@testable import Tabbed
import ApplicationServices

final class BrowserProviderResolverTests: XCTestCase {

    func testPreferredSelectionPrefersHeliumWhenInstalled() {
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

        let selection = resolver.preferredSelection()
        XCTAssertEqual(selection?.bundleID, BrowserProviderResolver.heliumBundleID)
        XCTAssertEqual(selection?.engine, .chromium)
    }

    func testResolveSelectionUsesExplicitBundleAndEngine() {
        let resolver = BrowserProviderResolver(appURLLookup: { bundleID in
            switch bundleID {
            case "org.mozilla.firefox":
                return URL(fileURLWithPath: "/Applications/Firefox.app")
            default:
                return nil
            }
        })

        let provider = resolver.resolve(selection: BrowserProviderSelection(bundleID: "org.mozilla.firefox", engine: .firefox))
        XCTAssertEqual(provider?.selection.bundleID, "org.mozilla.firefox")
        XCTAssertEqual(provider?.selection.engine, .firefox)
    }

    func testResolveSelectionReturnsNilWhenAppNotInstalled() {
        let resolver = BrowserProviderResolver(appURLLookup: { _ in nil })

        let provider = resolver.resolve(selection: BrowserProviderSelection(bundleID: "com.example.unknown", engine: .chromium))
        XCTAssertNil(provider)
    }

    func testDisablingBothActionsRemovesURLAndSearchCandidates() {
        let engine = LauncherEngine()
        let config = AddWindowLauncherConfig(
            urlLaunchEnabled: false,
            searchLaunchEnabled: false,
            searchEngine: .google
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
            targetGroupDisplayName: nil,
            targetGroupWindowCount: nil,
            targetActiveTabID: nil,
            targetActiveTabTitle: nil,
            appCatalog: [],
            launcherConfig: config,
            resolvedURLBrowserProvider: nil,
            resolvedSearchBrowserProvider: nil,
            currentSpaceID: nil,
            windowRecency: [:],
            groupRecency: [:],
            appRecency: [:],
            urlHistory: [],
            appLaunchHistory: [:],
            actionHistory: [:]
        )

        let ranked = engine.rank(query: "example.com", context: context)
        let hasURLOrSearch = ranked.contains { candidate in
            if case .openURL = candidate.action { return true }
            if case .webSearch = candidate.action { return true }
            return false
        }

        XCTAssertFalse(hasURLOrSearch)
    }

    func testSearchOnlyResolvesSearchProviderSelection() {
        let resolver = BrowserProviderResolver(appURLLookup: { bundleID in
            switch bundleID {
            case "com.google.Chrome":
                return URL(fileURLWithPath: "/Applications/Google Chrome.app")
            default:
                return nil
            }
        })

        let config = AddWindowLauncherConfig(
            urlLaunchEnabled: false,
            searchLaunchEnabled: true,
            searchProviderSelection: BrowserProviderSelection(bundleID: "com.google.Chrome", engine: .chromium),
            searchEngine: .google
        )

        let provider = resolver.resolve(selection: config.searchProviderSelection)
        XCTAssertEqual(provider?.selection.bundleID, "com.google.Chrome")
        XCTAssertEqual(provider?.selection.engine, .chromium)
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

    func testPreferredSelectionFallsBackToSafariWhenNoChromiumOrFirefoxInstalled() {
        let resolver = BrowserProviderResolver(appURLLookup: { bundleID in
            switch bundleID {
            case "com.apple.Safari":
                return URL(fileURLWithPath: "/Applications/Safari.app")
            default:
                return nil
            }
        })

        let selection = resolver.preferredSelection()
        XCTAssertEqual(selection?.bundleID, "com.apple.Safari")
        XCTAssertEqual(selection?.engine, .safari)
    }

    func testPreferredSelectionPrefersChromiumOverSafari() {
        let resolver = BrowserProviderResolver(appURLLookup: { bundleID in
            switch bundleID {
            case "com.google.Chrome":
                return URL(fileURLWithPath: "/Applications/Google Chrome.app")
            case "com.apple.Safari":
                return URL(fileURLWithPath: "/Applications/Safari.app")
            default:
                return nil
            }
        })

        let selection = resolver.preferredSelection()
        XCTAssertEqual(selection?.bundleID, "com.google.Chrome")
        XCTAssertEqual(selection?.engine, .chromium)
    }

    func testManualSelectionDetectsSafariEngine() {
        let resolver = BrowserProviderResolver(appURLLookup: { _ in nil })
        let selection = resolver.manualSelection(forBundleID: "com.apple.Safari", fallbackEngine: .firefox)

        XCTAssertEqual(selection.bundleID, "com.apple.Safari")
        XCTAssertEqual(selection.engine, .safari)
    }
}
