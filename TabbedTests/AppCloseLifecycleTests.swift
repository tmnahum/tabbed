import XCTest
@testable import Tabbed

final class AppCloseLifecycleTests: XCTestCase {
    private func makeWindow(id: CGWindowID, pid: pid_t) -> WindowInfo {
        WindowInfo(
            id: id,
            element: AXUIElementCreateApplication(pid),
            ownerPID: pid,
            bundleID: "test.bundle.\(pid)",
            title: "Window \(id)",
            appName: "App \(pid)"
        )
    }

    func testShouldQuitOwningAppAfterClosingWindowWhenNoSiblingWindowsRemain() {
        let closedPID: pid_t = 501
        let windows = [makeWindow(id: 10, pid: closedPID)]

        XCTAssertTrue(
            AppDelegate.shouldQuitOwningAppAfterClosingWindow(
                closedWindowID: 10,
                ownerPID: closedPID,
                appWindows: windows,
                currentProcessID: 999
            )
        )
    }

    func testShouldNotQuitOwningAppWhenAnotherWindowForSameAppRemains() {
        let closedPID: pid_t = 501
        let windows = [
            makeWindow(id: 10, pid: closedPID),
            makeWindow(id: 11, pid: closedPID)
        ]

        XCTAssertFalse(
            AppDelegate.shouldQuitOwningAppAfterClosingWindow(
                closedWindowID: 10,
                ownerPID: closedPID,
                appWindows: windows,
                currentProcessID: 999
            )
        )
    }

    func testShouldNotQuitTabbedItselfWhenClosingOwnWindow() {
        let ownPID: pid_t = 777
        let windows = [makeWindow(id: 20, pid: ownPID)]

        XCTAssertFalse(
            AppDelegate.shouldQuitOwningAppAfterClosingWindow(
                closedWindowID: 20,
                ownerPID: ownPID,
                appWindows: windows,
                currentProcessID: ownPID
            )
        )
    }

    func testCloseTabKeepsWindowGroupedUntilDestroyNotification() {
        let appDelegate = AppDelegate()
        let window = makeWindow(id: 30, pid: 501)
        let group = appDelegate.groupManager.createGroup(
            with: [window],
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertNotNil(group)
        guard let group else { return }

        appDelegate.closeTab(at: 0, from: group, panel: TabBarPanel())

        XCTAssertTrue(group.contains(windowID: window.id))
        XCTAssertEqual(appDelegate.groupManager.membershipCount(for: window.id), 1)
    }

    func testCloseTabsKeepsWindowsGroupedUntilDestroyNotification() {
        let appDelegate = AppDelegate()
        let first = makeWindow(id: 40, pid: 601)
        let second = makeWindow(id: 41, pid: 601)
        let group = appDelegate.groupManager.createGroup(
            with: [first, second],
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertNotNil(group)
        guard let group else { return }

        appDelegate.closeTabs(withIDs: [first.id], from: group, panel: TabBarPanel())

        XCTAssertTrue(group.contains(windowID: first.id))
        XCTAssertTrue(group.contains(windowID: second.id))
        XCTAssertEqual(appDelegate.groupManager.membershipCount(for: first.id), 1)
        XCTAssertEqual(appDelegate.groupManager.membershipCount(for: second.id), 1)
    }
}
