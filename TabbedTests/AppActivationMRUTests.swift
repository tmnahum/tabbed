import XCTest
@testable import Tabbed

final class AppActivationMRUTests: XCTestCase {

    private func makeWindow(id: CGWindowID, pid: pid_t = 1) -> WindowInfo {
        WindowInfo(
            id: id,
            element: AXUIElementCreateSystemWide(),
            ownerPID: pid,
            bundleID: "com.test.\(pid)",
            title: "W\(id)",
            appName: "App\(pid)",
            icon: nil
        )
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
            makeWindow(id: 4, pid: 4)
        ]

        let eligible = app.globalSwitcherEligibleWindows(from: windows, currentProcessID: ownPID)

        XCTAssertEqual(eligible.map(\.id), [2, 4])
    }
}
