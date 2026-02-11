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

    private func makeContext(
        mode: LauncherMode = .newGroup,
        looseWindows: [WindowInfo],
        mergeGroups: [TabGroup] = [],
        appCatalog: [AppCatalogService.AppRecord] = [],
        launcherConfig: AddWindowLauncherConfig = .default
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
            appRecency: [:]
        )
    }

    func testTierOrderingIsFixedAcrossCategories() {
        let window = makeWindow(id: 1, appName: "Alpha.com", title: "Alpha.com Notes")
        let mergeWindow = makeWindow(id: 2, appName: "Alpha.com Browser", title: "Alpha.com")
        let group = TabGroup(windows: [mergeWindow], frame: .zero)
        let app = AppCatalogService.AppRecord(
            bundleID: "com.alpha.app",
            displayName: "Alpha.com App",
            appURL: URL(fileURLWithPath: "/Applications/Alpha.app"),
            icon: nil,
            isRunning: true,
            runningPID: 123,
            recency: 10
        )

        let context = makeContext(
            mode: .addToGroup(targetGroupID: UUID(), targetSpaceID: 1),
            looseWindows: [window],
            mergeGroups: [group],
            appCatalog: [app]
        )

        let ranked = LauncherEngine().rank(query: "alpha.com", context: context)

        XCTAssertGreaterThanOrEqual(ranked.count, 5)

        switch ranked[0].action {
        case .looseWindow: break
        default: XCTFail("Expected loose window first")
        }
        switch ranked[1].action {
        case .mergeGroup: break
        default: XCTFail("Expected merge group second")
        }
        switch ranked[2].action {
        case .appLaunch: break
        default: XCTFail("Expected app third")
        }
        switch ranked[3].action {
        case .openURL: break
        default: XCTFail("Expected URL action before search")
        }
        switch ranked[4].action {
        case .webSearch: break
        default: XCTFail("Expected web search after URL")
        }
    }

    func testWithinCategoryScoringPrefixBeatsSubstring() {
        let prefix = makeWindow(id: 1, appName: "Notes", title: "Daily")
        let substring = makeWindow(id: 2, appName: "Project", title: "My Notes Board")

        let context = makeContext(looseWindows: [substring, prefix])
        let ranked = LauncherEngine().rank(query: "note", context: context)

        XCTAssertGreaterThanOrEqual(ranked.count, 2)
        guard case .looseWindow(let firstID) = ranked[0].action else {
            XCTFail("Expected loose window at index 0")
            return
        }
        XCTAssertEqual(firstID, 1)
    }

    func testEmptyQueryPreviewShowsOnlyWindowsAndGroupsWithCaps() {
        let windows = (1...10).map { id in
            makeWindow(id: CGWindowID(id), appName: "App\(id)", title: "Window\(id)")
        }
        let groups = (1...5).map { idx in
            TabGroup(windows: [makeWindow(id: CGWindowID(100 + idx), appName: "Group\(idx)", title: "T")], frame: .zero)
        }
        let app = AppCatalogService.AppRecord(
            bundleID: "com.alpha.app",
            displayName: "Alpha App",
            appURL: nil,
            icon: nil,
            isRunning: false,
            runningPID: nil,
            recency: 0
        )

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

    func testSearchDisabledKeepsOnlyURLAction() {
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
