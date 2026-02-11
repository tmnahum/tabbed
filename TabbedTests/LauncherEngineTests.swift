import XCTest
@testable import Tabbed
import ApplicationServices

final class LauncherEngineTests: XCTestCase {

    private func makeWindow(id: CGWindowID, appName: String, title: String) -> WindowInfo {
        WindowInfo(
            id: id,
            element: AXUIElementCreateSystemWide(),
            ownerPID: 1,
            bundleID: "com.test.\(id)",
            title: title,
            appName: appName,
            icon: nil
        )
    }

    private func makeApp(
        bundleID: String,
        displayName: String,
        isRunning: Bool = false,
        recency: Int = 0
    ) -> AppCatalogService.AppRecord {
        AppCatalogService.AppRecord(
            bundleID: bundleID,
            displayName: displayName,
            appURL: URL(fileURLWithPath: "/Applications/\(displayName).app"),
            icon: nil,
            isRunning: isRunning,
            runningPID: isRunning ? 123 : nil,
            recency: recency
        )
    }

    private func makeContext(
        mode: LauncherMode = .newGroup,
        looseWindows: [WindowInfo],
        mergeGroups: [TabGroup] = [],
        appCatalog: [AppCatalogService.AppRecord] = [],
        launcherConfig: AddWindowLauncherConfig = .default,
        urlHistory: [LauncherHistoryStore.URLEntry] = [],
        appLaunchHistory: [String: LauncherHistoryStore.AppEntry] = [:]
    ) -> LauncherQueryContext {
        LauncherQueryContext(
            mode: mode,
            looseWindows: looseWindows,
            mergeGroups: mergeGroups,
            appCatalog: appCatalog,
            launcherConfig: launcherConfig,
            resolvedBrowserProvider: ResolvedBrowserProvider(
                selection: BrowserProviderSelection(bundleID: "com.google.Chrome", engine: .chromium),
                appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
            ),
            currentSpaceID: 1,
            windowRecency: [:],
            groupRecency: [:],
            appRecency: [:],
            urlHistory: urlHistory,
            appLaunchHistory: appLaunchHistory
        )
    }

    func testOrderingKeepsWindowsAndGroupsAheadOfSuggestionsAndSearch() {
        let window = makeWindow(id: 1, appName: "Alpha.com", title: "Alpha.com Notes")
        let mergeWindow = makeWindow(id: 2, appName: "Alpha.com Browser", title: "Alpha.com")
        let group = TabGroup(windows: [mergeWindow], frame: .zero)
        let app = makeApp(bundleID: "com.alpha.app", displayName: "Alpha.com App", isRunning: true, recency: 10)

        let context = makeContext(
            mode: .addToGroup(targetGroupID: UUID(), targetSpaceID: 1),
            looseWindows: [window],
            mergeGroups: [group],
            appCatalog: [app]
        )

        let ranked = LauncherEngine().rank(query: "alpha.com", context: context)

        XCTAssertGreaterThanOrEqual(ranked.count, 5)

        guard case .looseWindow = ranked[0].action else {
            return XCTFail("Expected loose window first")
        }
        guard case .mergeGroup = ranked[1].action else {
            return XCTFail("Expected merge group second")
        }

        guard let firstSuggestionIndex = ranked.firstIndex(where: { $0.sectionTitle == "Suggestions" }) else {
            return XCTFail("Expected suggestion section")
        }
        guard case .openURL = ranked[firstSuggestionIndex].action else {
            return XCTFail("Expected URL suggestion to outrank app on explicit URL intent")
        }

        guard let last = ranked.last else {
            return XCTFail("Expected non-empty ranking")
        }
        guard case .webSearch = last.action else {
            return XCTFail("Expected web search at the bottom")
        }
        XCTAssertEqual(last.sectionTitle, "Web Search")
    }

    func testNonDotQueryInterleavesSuggestionsByScoreWithHistoryURLFirst() {
        let app = makeApp(bundleID: "com.google.Chrome", displayName: "Google Chrome", isRunning: true, recency: 20)
        let history = LauncherHistoryStore.URLEntry(
            urlString: "https://google.com",
            launchCount: 20,
            lastLaunchedAt: Date()
        )
        let context = makeContext(looseWindows: [], appCatalog: [app], urlHistory: [history])

        let ranked = LauncherEngine().rank(query: "goo", context: context)
        let suggestions = ranked.filter { $0.sectionTitle == "Suggestions" }

        XCTAssertGreaterThanOrEqual(suggestions.count, 2)
        guard case .openURL = suggestions[0].action else {
            return XCTFail("Expected history URL to rank above app by unified score")
        }
        XCTAssertTrue(suggestions.contains(where: {
            if case .appLaunch = $0.action { return true }
            return false
        }))
    }

    func testTypedURLDeduplicatesMatchingHistoryURL() {
        let history = LauncherHistoryStore.URLEntry(
            urlString: "https://example.com",
            launchCount: 5,
            lastLaunchedAt: Date()
        )
        let context = makeContext(looseWindows: [], urlHistory: [history])

        let ranked = LauncherEngine().rank(query: "example.com", context: context)
        let matchingOpenURLs = ranked.compactMap { candidate -> String? in
            guard case .openURL(let url) = candidate.action else { return nil }
            return LauncherHistoryStore.canonicalURLString(url)
        }
        .filter { $0 == "https://example.com" }

        XCTAssertEqual(matchingOpenURLs.count, 1)
    }

    func testAppLaunchHistoryBoostInfluencesSuggestionRanking() {
        let appOne = makeApp(bundleID: "com.example.one", displayName: "Alpha One")
        let appTwo = makeApp(bundleID: "com.example.two", displayName: "Alpha Two")
        let appHistory = [
            "com.example.two": LauncherHistoryStore.AppEntry(
                bundleID: "com.example.two",
                launchCount: 40,
                lastLaunchedAt: Date()
            )
        ]

        let context = makeContext(
            looseWindows: [],
            appCatalog: [appOne, appTwo],
            appLaunchHistory: appHistory
        )

        let ranked = LauncherEngine().rank(query: "alpha", context: context)
        let appSuggestions = ranked.filter {
            if case .appLaunch = $0.action { return true }
            return false
        }

        XCTAssertGreaterThanOrEqual(appSuggestions.count, 2)
        guard case .appLaunch(let firstBundleID, _, _) = appSuggestions[0].action else {
            return XCTFail("Expected app at top of app suggestions")
        }
        XCTAssertEqual(firstBundleID, "com.example.two")
    }

    func testEmptyQueryPreviewShowsOnlyWindowsAndGroupsWithCaps() {
        let windows = (1...10).map { id in
            makeWindow(id: CGWindowID(id), appName: "App\(id)", title: "Window\(id)")
        }
        let groups = (1...5).map { idx in
            TabGroup(windows: [makeWindow(id: CGWindowID(100 + idx), appName: "Group\(idx)", title: "T")], frame: .zero)
        }
        let app = makeApp(bundleID: "com.alpha.app", displayName: "Alpha App")

        let context = makeContext(
            mode: .addToGroup(targetGroupID: UUID(), targetSpaceID: 1),
            looseWindows: windows,
            mergeGroups: groups,
            appCatalog: [app]
        )

        let ranked = LauncherEngine().rank(query: "", context: context)

        XCTAssertEqual(ranked.count, 9)
        let windowCount = ranked.filter {
            if case .looseWindow = $0.action { return true }
            return false
        }.count
        let groupCount = ranked.filter {
            if case .mergeGroup = $0.action { return true }
            return false
        }.count
        let hasNonPreviewType = ranked.contains {
            if case .appLaunch = $0.action { return true }
            if case .openURL = $0.action { return true }
            if case .webSearch = $0.action { return true }
            return false
        }

        XCTAssertEqual(windowCount, 6)
        XCTAssertEqual(groupCount, 3)
        XCTAssertFalse(hasNonPreviewType)
    }

    func testURLDisabledKeepsOnlyWebSearchAction() {
        let config = AddWindowLauncherConfig(
            urlLaunchEnabled: false,
            searchLaunchEnabled: true,
            providerMode: .auto,
            searchEngine: .google,
            manualSelection: BrowserProviderSelection()
        )
        let context = makeContext(looseWindows: [], launcherConfig: config)

        let ranked = LauncherEngine().rank(query: "example.com", context: context)

        let hasURL = ranked.contains {
            if case .openURL = $0.action { return true }
            return false
        }
        let hasSearch = ranked.contains {
            if case .webSearch = $0.action { return true }
            return false
        }

        XCTAssertFalse(hasURL)
        XCTAssertTrue(hasSearch)
    }

    func testSearchDisabledKeepsOnlyURLSuggestions() {
        let config = AddWindowLauncherConfig(
            urlLaunchEnabled: true,
            searchLaunchEnabled: false,
            providerMode: .auto,
            searchEngine: .google,
            manualSelection: BrowserProviderSelection()
        )
        let context = makeContext(looseWindows: [], launcherConfig: config)

        let ranked = LauncherEngine().rank(query: "example.com", context: context)

        let hasURL = ranked.contains {
            if case .openURL = $0.action { return true }
            return false
        }
        let hasSearch = ranked.contains {
            if case .webSearch = $0.action { return true }
            return false
        }

        XCTAssertTrue(hasURL)
        XCTAssertFalse(hasSearch)
    }
}
