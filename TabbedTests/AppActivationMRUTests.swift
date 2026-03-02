import XCTest
@testable import Tabbed

final class AppActivationMRUTests: XCTestCase {

    private func makeWindow(id: CGWindowID, pid: pid_t = 1, title: String? = nil) -> WindowInfo {
        WindowInfo(
            id: id,
            element: AXUIElementCreateSystemWide(),
            ownerPID: pid,
            bundleID: "com.test.\(pid)",
            title: title ?? "W\(id)",
            appName: "App\(pid)",
            icon: nil
        )
    }

    private func makeGroup(windows: [WindowInfo], activeIndex: Int = 0) -> TabGroup {
        let group = TabGroup(windows: windows, frame: .zero)
        group.switchTo(index: activeIndex)
        return group
    }

    func testResolveActivatedWindowIDFallsBackToCurrentSpace() {
        let app = AppDelegate()
        let targetPID: pid_t = 999_991
        let currentSpace = [makeWindow(id: 10, pid: targetPID), makeWindow(id: 11, pid: 2)]

        let resolved = app.resolveActivatedWindowID(
            forAppPID: targetPID,
            fallbackCurrentSpaceWindows: currentSpace,
            fallbackCachedWindows: []
        )

        XCTAssertEqual(resolved, 10)
    }

    func testResolveActivatedWindowIDFallsBackToCachedInventory() {
        let app = AppDelegate()
        let targetPID: pid_t = 999_992
        let cached = [makeWindow(id: 20, pid: targetPID)]

        let resolved = app.resolveActivatedWindowID(
            forAppPID: targetPID,
            fallbackCurrentSpaceWindows: [],
            fallbackCachedWindows: cached
        )

        XCTAssertEqual(resolved, 20)
    }

    func testResolveActivatedWindowIDReturnsNilWhenNoSourcesContainPID() {
        let app = AppDelegate()
        let resolved = app.resolveActivatedWindowID(
            forAppPID: 999_993,
            fallbackCurrentSpaceWindows: [],
            fallbackCachedWindows: []
        )
        XCTAssertNil(resolved)
    }

    func testShouldForceSyncRefreshForRecentExternalActivationWhenCacheMissingWindow() {
        let app = AppDelegate()
        app.windowInventory = WindowInventory(discoverAllSpaces: { [self.makeWindow(id: 1, pid: 1)] })
        app.windowInventory.refreshSync()
        app.noteRecentExternalActivation(windowID: 2, at: Date())

        XCTAssertTrue(app.shouldForceSynchronousInventoryRefreshForRecentExternalActivation(now: Date()))
    }

    func testShouldNotForceSyncRefreshWhenRecentExternalActivationAlreadyCached() {
        let app = AppDelegate()
        app.windowInventory = WindowInventory(discoverAllSpaces: { [self.makeWindow(id: 1, pid: 1)] })
        app.windowInventory.refreshSync()
        app.noteRecentExternalActivation(windowID: 1, at: Date())

        XCTAssertFalse(app.shouldForceSynchronousInventoryRefreshForRecentExternalActivation(now: Date()))
    }

    func testShouldClearExpiredRecentExternalActivation() {
        let app = AppDelegate()
        app.noteRecentExternalActivation(
            windowID: 123,
            at: Date().addingTimeInterval(-(AppDelegate.recentExternalActivationLifetime + 0.5))
        )

        XCTAssertFalse(app.shouldForceSynchronousInventoryRefreshForRecentExternalActivation(now: Date()))
        XCTAssertNil(app.recentExternalActivationWindowID)
        XCTAssertNil(app.recentExternalActivationAt)
    }

    func testGlobalSwitcherEligibleWindowsExcludesCurrentProcessWindows() {
        let app = AppDelegate()
        let ownPID: pid_t = 9_999
        let windows = [
            makeWindow(id: 1, pid: ownPID),
            makeWindow(id: 2, pid: 2),
            makeWindow(id: 3, pid: ownPID),
            makeWindow(id: 4, pid: 4),
            makeWindow(id: 5, pid: ownPID, title: "Tabbed Settings")
        ]

        let eligible = app.globalSwitcherEligibleWindows(from: windows, currentProcessID: ownPID)

        XCTAssertEqual(eligible.map(\.id), [2, 4, 5])
    }

    func testGlobalSwitcherEligibleItemsExcludeCurrentProcessOnlyEntries() {
        let app = AppDelegate()
        let ownPID: pid_t = 9_999
        let externalPID: pid_t = 5_001

        let ownSingle = SwitcherItem.singleWindow(makeWindow(id: 1, pid: ownPID))
        let externalSingle = SwitcherItem.singleWindow(makeWindow(id: 2, pid: externalPID))
        let ownGroup = SwitcherItem.group(makeGroup(windows: [makeWindow(id: 3, pid: ownPID)]))
        let mixedGroup = SwitcherItem.group(makeGroup(windows: [
            makeWindow(id: 4, pid: ownPID),
            makeWindow(id: 5, pid: externalPID)
        ]))

        let eligible = app.globalSwitcherEligibleItems(
            from: [ownSingle, externalSingle, ownGroup, mixedGroup],
            currentProcessID: ownPID
        )

        XCTAssertEqual(eligible.count, 2)
        XCTAssertEqual(eligible[0].windowIDs, [2])
        XCTAssertEqual(Set(eligible[1].windowIDs), Set([CGWindowID(4), CGWindowID(5)]))
    }

    func testExternalWindowForCommitFallsBackToExternalInGroup() {
        let app = AppDelegate()
        let ownPID: pid_t = 9_999
        let externalPID: pid_t = 5_001

        let own = makeWindow(id: 10, pid: ownPID)
        let external = makeWindow(id: 11, pid: externalPID)
        let group = makeGroup(windows: [own, external], activeIndex: 0)

        let resolved = app.externalWindowForCommit(
            for: .group(group),
            subIndex: nil,
            currentProcessID: ownPID
        )

        XCTAssertEqual(resolved?.id, 11)
    }

    func testExternalWindowForCommitFallsBackToExternalInSegment() {
        let app = AppDelegate()
        let ownPID: pid_t = 9_999
        let externalPID: pid_t = 5_001

        let own = makeWindow(id: 20, pid: ownPID)
        let external = makeWindow(id: 21, pid: externalPID)
        let group = makeGroup(windows: [own, external], activeIndex: 0)

        let resolved = app.externalWindowForCommit(
            for: .groupSegment(group, windowIDs: [20, 21]),
            subIndex: 0,
            currentProcessID: ownPID
        )

        XCTAssertEqual(resolved?.id, 21)
    }

    func testGlobalSwitcherEligibleItemsIncludesTabbedSettingsSingleWindow() {
        let app = AppDelegate()
        let ownPID: pid_t = 9_999

        let ownSettings = SwitcherItem.singleWindow(
            makeWindow(id: 30, pid: ownPID, title: "Tabbed Settings")
        )
        let ownOther = SwitcherItem.singleWindow(
            makeWindow(id: 31, pid: ownPID, title: "Internal Overlay")
        )

        let eligible = app.globalSwitcherEligibleItems(
            from: [ownOther, ownSettings],
            currentProcessID: ownPID
        )

        XCTAssertEqual(eligible.map { $0.windowIDs.first }, [30])
    }

    func testExternalWindowForCommitAllowsTabbedSettingsSelfWindow() {
        let app = AppDelegate()
        let ownPID: pid_t = 9_999
        let settingsWindow = makeWindow(id: 40, pid: ownPID, title: "Tabbed Settings")

        let resolved = app.externalWindowForCommit(
            for: .singleWindow(settingsWindow),
            subIndex: nil,
            currentProcessID: ownPID
        )

        XCTAssertEqual(resolved?.id, 40)
    }
}
