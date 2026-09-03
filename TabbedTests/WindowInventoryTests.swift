import XCTest
@testable import Tabbed

final class WindowInventoryTests: XCTestCase {

    private func makeWindow(id: CGWindowID) -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(
            id: id,
            element: element,
            ownerPID: 1,
            bundleID: "com.test",
            title: "W\(id)",
            appName: "App",
            icon: nil
        )
    }

    func testAllSpacesForSwitcherReturnsCachedAndRefreshesWhenEmpty() {
        var discoverCalls = 0
        let discovered = [makeWindow(id: 1)]
        let inventory = WindowInventory(
            staleAfter: 10,
            discoverAllSpaces: {
                discoverCalls += 1
                return discovered
            }
        )

        XCTAssertTrue(inventory.allSpacesForSwitcher().isEmpty)

        let refreshed = expectation(description: "async refresh populates cache")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !inventory.cachedAllSpacesWindows.isEmpty {
                refreshed.fulfill()
            }
        }
        wait(for: [refreshed], timeout: 1.0)

        XCTAssertEqual(discoverCalls, 1)
        XCTAssertEqual(inventory.allSpacesForSwitcher().map(\.id), [1])
    }

    func testAllSpacesForSwitcherDoesNotRefreshWhenFresh() {
        var discoverCalls = 0
        let inventory = WindowInventory(
            staleAfter: 60,
            discoverAllSpaces: {
                discoverCalls += 1
                return [self.makeWindow(id: 1)]
            }
        )

        inventory.refreshSync()
        XCTAssertEqual(discoverCalls, 1)
        XCTAssertEqual(inventory.allSpacesForSwitcher().map(\.id), [1])
        XCTAssertEqual(discoverCalls, 1)
    }

    func testAllSpacesForSwitcherReturnsStaleCacheAndRefreshesAsync() {
        var discoverCalls = 0
        var currentNow = Date()
        let inventory = WindowInventory(
            staleAfter: 0.1,
            discoverAllSpaces: {
                discoverCalls += 1
                if discoverCalls == 1 {
                    return [self.makeWindow(id: 1)]
                }
                return [self.makeWindow(id: 2)]
            },
            now: { currentNow }
        )

        inventory.refreshSync()
        XCTAssertEqual(inventory.cachedAllSpacesWindows.map(\.id), [1])

        currentNow = currentNow.addingTimeInterval(1.0) // stale
        let immediate = inventory.allSpacesForSwitcher().map(\.id)
        XCTAssertEqual(immediate, [1], "Should return cached windows immediately while refresh runs")

        let refreshed = expectation(description: "async stale refresh updates cache")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if inventory.cachedAllSpacesWindows.map(\.id) == [2] {
                refreshed.fulfill()
            }
        }
        wait(for: [refreshed], timeout: 1.0)

        XCTAssertEqual(discoverCalls, 2)
        XCTAssertEqual(inventory.cachedAllSpacesWindows.map(\.id), [2])
    }

    func testHasCompletedRefreshFlipsAfterRefresh() {
        let inventory = WindowInventory(
            staleAfter: 60,
            discoverAllSpaces: { [self.makeWindow(id: 1)] }
        )

        XCTAssertFalse(inventory.hasCompletedRefresh)
        inventory.refreshSync()
        XCTAssertTrue(inventory.hasCompletedRefresh)
    }

    func testRemoveCachedWindowImmediatelyUpdatesInventory() {
        let inventory = WindowInventory(
            staleAfter: 60,
            discoverAllSpaces: { [self.makeWindow(id: 1), self.makeWindow(id: 2)] }
        )
        inventory.refreshSync()

        inventory.removeCachedWindow(withID: 1)

        XCTAssertEqual(inventory.cachedAllSpacesWindows.map(\.id), [2])
    }

    func testForcedSyncRefreshWinsOverOlderAsyncCompletion() {
        let asyncStarted = expectation(description: "async refresh started")
        let allowAsyncCompletion = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var discoverCallCount = 0

        let inventory = WindowInventory(
            staleAfter: 60,
            discoverAllSpaces: {
                lock.lock()
                discoverCallCount += 1
                let call = discoverCallCount
                lock.unlock()

                if call == 1 {
                    asyncStarted.fulfill()
                    _ = allowAsyncCompletion.wait(timeout: .now() + 1.0)
                    return [self.makeWindow(id: 1)]
                }
                return [self.makeWindow(id: 2)]
            }
        )

        inventory.refreshAsync()
        wait(for: [asyncStarted], timeout: 1.0)

        inventory.refreshSync(force: true)
        XCTAssertEqual(inventory.cachedAllSpacesWindows.map(\.id), [2])

        allowAsyncCompletion.signal()
        let settled = expectation(description: "stale async completion ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)
        XCTAssertEqual(inventory.cachedAllSpacesWindows.map(\.id), [2])
    }
}
