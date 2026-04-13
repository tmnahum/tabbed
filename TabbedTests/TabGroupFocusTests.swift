import XCTest
@testable import Tabbed

final class TabGroupFocusTests: XCTestCase {

    private func makeWindow(id: CGWindowID, appName: String = "App") -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(id: id, element: element, ownerPID: 1, bundleID: "com.test", title: appName, appName: appName, icon: nil)
    }

    // MARK: - Focus History

    func testInitSeedsFocusHistory() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)

        // Init seeds focus history with window order
        XCTAssertEqual(group.focusHistory, [1, 2, 3])
    }

    func testRecordFocusMovesToFront() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)

        group.recordFocus(windowID: 3)
        XCTAssertEqual(group.focusHistory, [3, 1, 2])

        group.recordFocus(windowID: 2)
        XCTAssertEqual(group.focusHistory, [2, 3, 1])
    }

    func testRecordFocusDeduplicates() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        group.recordFocus(windowID: 1)
        group.recordFocus(windowID: 1)
        group.recordFocus(windowID: 1)

        // Should not have duplicates
        XCTAssertEqual(group.focusHistory.count, 2)
        XCTAssertEqual(group.focusHistory[0], 1)
    }

    func testRemoveWindowClearsFocusHistory() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)

        _ = group.removeWindow(at: 1) // remove w2

        XCTAssertFalse(group.focusHistory.contains(2))
        XCTAssertEqual(group.focusHistory.count, 2)
    }

    func testRemoveActiveWindowFallsToMRU() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let w4 = makeWindow(id: 4)
        let group = TabGroup(windows: [w1, w2, w3, w4], frame: .zero)
        // focusHistory: [1, 2, 3, 4]

        // Build MRU: focus 3, then 1, then 2 → MRU: [2, 1, 3, 4]
        group.recordFocus(windowID: 3)
        group.recordFocus(windowID: 1)
        group.recordFocus(windowID: 2)

        group.switchTo(index: 1) // Window 2 is active
        _ = group.removeWindow(at: 1) // Remove window 2

        // MRU after removing 2: [1, 3, 4] → should switch to window 1
        XCTAssertEqual(group.activeWindow?.id, 1)
    }

    func testRemoveActiveWindowFallsToMRUNotNeighbor() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        // focusHistory: [1, 2, 3]

        // Focus window 3, then window 2 → MRU: [2, 3, 1]
        group.recordFocus(windowID: 3)
        group.recordFocus(windowID: 2)

        group.switchTo(index: 1) // Window 2 is active
        _ = group.removeWindow(at: 1) // Remove window 2

        // MRU after removing 2: [3, 1] → should switch to window 3, not window 1 (positional neighbor)
        XCTAssertEqual(group.activeWindow?.id, 3)
    }

    func testRemoveNonActiveWindowKeepsActive() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)

        group.switchTo(index: 2) // Window 3 is active
        _ = group.removeWindow(at: 0) // Remove window 1

        // Non-active removed → active stays on window 3
        XCTAssertEqual(group.activeWindow?.id, 3)
    }

    func testBatchRemoveActiveWindowFallsToMRU() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let w4 = makeWindow(id: 4)
        let group = TabGroup(windows: [w1, w2, w3, w4], frame: .zero)

        // Build MRU: [4, 2, 1, 3]
        group.recordFocus(windowID: 2)
        group.recordFocus(windowID: 4)

        group.switchTo(index: 3) // Window 4 is active
        _ = group.removeWindows(withIDs: [4, 1]) // Remove active + another

        // MRU after removing 4 and 1: [2, 3] → should switch to window 2
        XCTAssertEqual(group.activeWindow?.id, 2)
    }

    func testAddWindowAppendsFocusHistory() {
        let w1 = makeWindow(id: 1)
        let group = TabGroup(windows: [w1], frame: .zero)

        let w2 = makeWindow(id: 2)
        group.addWindow(w2)

        XCTAssertEqual(group.focusHistory, [1, 2])
    }

    func testFullscreenModeTabSwitchDoesNotMutateRestoreFrame() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let originalFrame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let group = TabGroup(windows: [w1, w2], frame: originalFrame)
        group.displayMode = .fullscreen
        group.fullscreenState = FullscreenGroupState(
            screenIdentity: ScreenIdentity(frame: CodableRect(CGRect(x: 0, y: 0, width: 1440, height: 900))),
            preFullscreenFrame: originalFrame
        )

        group.switchTo(index: 1)
        group.recordFocus(windowID: 2)

        XCTAssertEqual(group.frame, originalFrame)
        XCTAssertEqual(group.fullscreenState?.preFullscreenFrame, originalFrame)
        XCTAssertEqual(group.activeWindow?.id, 2)
        XCTAssertEqual(group.focusHistory.first, 2)
    }

    // MARK: - MRU Cycling

    func testNextInMRUCycleReturnsNilForSingleWindow() {
        let w1 = makeWindow(id: 1)
        let group = TabGroup(windows: [w1], frame: .zero)

        XCTAssertNil(group.nextInMRUCycle())
    }

    func testNextInMRUCycleStartsCycling() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        XCTAssertFalse(group.isCycling)
        _ = group.nextInMRUCycle()
        XCTAssertTrue(group.isCycling)
    }

    func testNextInMRUCycleFollowsFocusHistory() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        // focusHistory: [1, 2, 3]
        group.recordFocus(windowID: 3)  // [3, 1, 2]
        group.recordFocus(windowID: 1)  // [1, 3, 2]

        // First call snapshots MRU: [1, 3, 2] and advances to position 1 → w3
        let first = group.nextInMRUCycle()
        XCTAssertEqual(first, 2) // index of w3 in windows array

        // Second call → position 2 → w2
        let second = group.nextInMRUCycle()
        XCTAssertEqual(second, 1) // index of w2

        // Third call → wraps to position 0 → w1
        let third = group.nextInMRUCycle()
        XCTAssertEqual(third, 0) // index of w1
    }

    func testEndCycleClearsState() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        _ = group.nextInMRUCycle()
        XCTAssertTrue(group.isCycling)

        group.endCycle()
        XCTAssertFalse(group.isCycling)
    }

    func testEndCycleCommitsLandedWindowToMRUFront() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        // focusHistory: [1, 2, 3]

        // Cycle once: advances to position 1 → w2
        let idx = group.nextInMRUCycle()
        XCTAssertEqual(idx, 1)

        group.endCycle()

        // w2 should now be at front of focus history
        XCTAssertEqual(group.focusHistory[0], 2)
    }

    func testEndCycleWithExplicitLandedWindowCommitsThatWindow() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        // focusHistory: [1, 2, 3]

        // Start cycle: snapshot [1, 2, 3], internal position advances to w2.
        let first = group.nextInMRUCycle()
        XCTAssertEqual(first, 1)

        // Simulate UI navigating further without mutating TabGroup's cycle cursor.
        // Commit explicit landed window (w3).
        group.endCycle(landedWindowID: 3)

        XCTAssertEqual(group.focusHistory.first, 3)
    }

    func testCycleSnapshotIsFrozen() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)

        // Start cycling — snapshots [1, 2, 3]
        _ = group.nextInMRUCycle()

        // Recording focus mid-cycle should NOT affect the cycle order
        group.recordFocus(windowID: 3)

        // Next should still follow original snapshot
        let next = group.nextInMRUCycle()
        XCTAssertNotNil(next)
    }

    func testCycleHandlesWindowRemovedMidCycle() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)

        // Start cycling — snapshots [1, 2, 3], advances to w2
        let first = group.nextInMRUCycle()
        XCTAssertEqual(first, 1) // w2 at index 1

        // Remove w3 mid-cycle
        _ = group.removeWindow(at: 2)

        // Should skip removed window and continue
        let next = group.nextInMRUCycle()
        XCTAssertNotNil(next)
    }

    func testMultipleCycleSessionsAreIndependent() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        // First session
        _ = group.nextInMRUCycle()
        group.endCycle()

        // Second session should start fresh
        XCTAssertFalse(group.isCycling)
        _ = group.nextInMRUCycle()
        XCTAssertTrue(group.isCycling)
        group.endCycle()
    }
}
