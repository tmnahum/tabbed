import XCTest
@testable import Tabbed
import ApplicationServices

final class TabGroupTests: XCTestCase {
    func makeWindow(id: CGWindowID) -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(
            id: id,
            element: element,
            ownerPID: 0,
            bundleID: "com.test",
            title: "Window \(id)",
            appName: "Test",
            icon: nil
        )
    }

    func makeSeparator(id: CGWindowID) -> WindowInfo {
        WindowInfo.separator(withID: id)
    }

    func testInitSetsActiveIndexToZero() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        XCTAssertEqual(group.activeIndex, 0)
    }

    func testDisplayNameTrimsWhitespace() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero, name: "  Work  ")
        XCTAssertEqual(group.displayName, "Work")
    }

    func testDisplayNameReturnsNilForWhitespaceOnly() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero, name: "   ")
        XCTAssertNil(group.displayName)
    }

    func testTabBarDisplayedGroupNameTrimsWhitespace() {
        XCTAssertEqual(TabBarView.displayedGroupName(from: "  Work  "), "Work")
    }

    func testTabBarDisplayedGroupNameReturnsNilForWhitespaceOnly() {
        XCTAssertNil(TabBarView.displayedGroupName(from: "  "))
        XCTAssertNil(TabBarView.displayedGroupName(from: nil))
    }

    func testDisplayedCounterTooltipTitleUsesTrimmedGroupName() {
        let groupID = UUID()
        let title = TabBarView.displayedCounterTooltipTitle(for: groupID) { id in
            guard id == groupID else { return nil }
            return "  Work  "
        }
        XCTAssertEqual(title, "Work")
    }

    func testDisplayedCounterTooltipTitleReturnsNilForUnnamedGroup() {
        let groupID = UUID()
        XCTAssertNil(
            TabBarView.displayedCounterTooltipTitle(for: groupID) { _ in nil }
        )
        XCTAssertNil(
            TabBarView.displayedCounterTooltipTitle(for: groupID) { _ in "   " }
        )
    }

    func testGroupNameReservedWidthIsMinimalWhenUnnamed() {
        XCTAssertEqual(TabBarView.groupNameReservedWidth(for: nil), TabBarView.groupNameEmptyHitWidth)
    }

    func testGroupNameReservedWidthTreatsWhitespaceAsEmpty() {
        XCTAssertEqual(TabBarView.groupNameReservedWidth(for: "   "), TabBarView.groupNameEmptyHitWidth)
    }

    func testGroupNameReservedWidthWhileEditingShowsPlaceholderWidthWhenEmpty() {
        XCTAssertEqual(
            TabBarView.groupNameReservedWidth(for: nil, isEditing: true),
            TabBarView.groupNameReservedWidth(for: TabBarView.groupNamePlaceholder)
        )
    }

    func testGroupNameReservedWidthMatchesTrimmedFinalName() {
        XCTAssertEqual(
            TabBarView.groupNameReservedWidth(for: "Work  "),
            TabBarView.groupNameReservedWidth(for: "Work")
        )
    }

    func testGroupCounterReservedWidthIsZeroForZeroOrOneVisibleCounter() {
        let current = UUID()
        XCTAssertEqual(
            TabBarView.groupCounterReservedWidth(
                counterGroupIDs: [],
                currentGroupID: current,
                enabled: true
            ),
            0
        )
        XCTAssertEqual(
            TabBarView.groupCounterReservedWidth(
                counterGroupIDs: [current],
                currentGroupID: current,
                enabled: true
            ),
            0
        )
        XCTAssertEqual(
            TabBarView.groupCounterReservedWidth(
                counterGroupIDs: [UUID(), UUID()],
                currentGroupID: current,
                enabled: true
            ),
            0
        )
    }

    func testGroupCounterReservedWidthGrowsAsCounterCountIncreases() {
        let current = UUID()
        let two = [current, UUID()]
        let three = [current, UUID(), UUID()]
        let widthTwo = TabBarView.groupCounterReservedWidth(
            counterGroupIDs: two,
            currentGroupID: current,
            enabled: true
        )
        let widthThree = TabBarView.groupCounterReservedWidth(
            counterGroupIDs: three,
            currentGroupID: current,
            enabled: true
        )

        XCTAssertGreaterThan(widthTwo, 0)
        XCTAssertGreaterThan(widthThree, widthTwo)
    }

    func testGroupCounterDisplayNumberUsesConfiguredStart() {
        XCTAssertEqual(TabBarView.groupCounterDisplayNumber(index: 0, startAtZero: false), 1)
        XCTAssertEqual(TabBarView.groupCounterDisplayNumber(index: 3, startAtZero: false), 4)
        XCTAssertEqual(TabBarView.groupCounterDisplayNumber(index: 0, startAtZero: true), 0)
        XCTAssertEqual(TabBarView.groupCounterDisplayNumber(index: 3, startAtZero: true), 3)
    }

    func testGroupCounterReservedWidthRespectsStartAtZeroForTwoDigitBoundary() {
        let current = UUID()
        let ids = (0..<10).map { _ in UUID() }
        let counterIDs = [current] + Array(ids.dropLast())

        let widthStartAtOne = TabBarView.groupCounterReservedWidth(
            counterGroupIDs: counterIDs,
            currentGroupID: current,
            enabled: true,
            startAtZero: false
        )
        let widthStartAtZero = TabBarView.groupCounterReservedWidth(
            counterGroupIDs: counterIDs,
            currentGroupID: current,
            enabled: true,
            startAtZero: true
        )

        XCTAssertGreaterThan(widthStartAtOne, widthStartAtZero)
    }

    func testDisplayedTabTitlePrefersCustomTabName() {
        var window = makeWindow(id: 1)
        window.customTabName = "  Focus  "
        window.title = "Original"

        XCTAssertEqual(TabBarView.displayedTabTitle(for: window), "Focus")
    }

    func testDisplayedTabTitleFallsBackToWindowTitleWhenCustomNameIsEmpty() {
        var window = makeWindow(id: 1)
        window.customTabName = "   "
        window.title = "Original"

        XCTAssertEqual(TabBarView.displayedTabTitle(for: window), "Original")
    }

    func testDisplayedTabTitleFallsBackToAppNameWhenWindowTitleIsEmpty() {
        var window = makeWindow(id: 1)
        window.customTabName = nil
        window.title = ""
        window.appName = "Finder"

        XCTAssertEqual(TabBarView.displayedTabTitle(for: window), "Finder")
    }

    func testActiveWindow() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = TabGroup(windows: [w1, w2], frame: .zero)
        XCTAssertEqual(group.activeWindow?.id, 1)
        group.switchTo(index: 1)
        XCTAssertEqual(group.activeWindow?.id, 2)
    }

    func testContains() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero)
        XCTAssertTrue(group.contains(windowID: 1))
        XCTAssertFalse(group.contains(windowID: 99))
    }

    func testAddWindow() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero)
        group.addWindow(makeWindow(id: 2))
        XCTAssertEqual(group.windows.count, 2)
    }

    func testAddDuplicateWindowIsIgnored() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero)
        group.addWindow(makeWindow(id: 1))
        XCTAssertEqual(group.windows.count, 1)
    }

    func testAddSeparatorDoesNotChangeManagedWindowCount() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)

        _ = group.addSeparator(at: 1)

        XCTAssertEqual(group.windows.count, 3)
        XCTAssertEqual(group.managedWindowCount, 2)
        XCTAssertEqual(group.managedWindows.map(\.id), [1, 2])
    }

    func testAddSeparatorAfterPinnedTabInsertsAtPinnedBoundary() {
        var pinned = makeWindow(id: 1)
        pinned.isPinned = true
        let group = TabGroup(windows: [pinned, makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)

        let separatorID = group.addSeparator(at: 1)

        XCTAssertEqual(group.windows.map(\.id), [1, separatorID, 2, 3])
        XCTAssertEqual(group.managedWindows.map(\.id), [1, 2, 3])
    }

    func testRemoveWindow() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        let removed = group.removeWindow(withID: 1)
        XCTAssertEqual(removed?.id, 1)
        XCTAssertEqual(group.windows.count, 1)
    }

    func testRemoveActiveWindowAdjustsIndex() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        group.switchTo(index: 1)
        group.removeWindow(at: 1)
        XCTAssertEqual(group.activeIndex, 0)
    }

    func testRemoveActiveWindowPrefersPreviousTab() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.switchTo(index: 1) // Window 2 active
        group.removeWindow(at: 1)
        XCTAssertEqual(group.activeIndex, 0)
        XCTAssertEqual(group.activeWindow?.id, 1)
    }

    func testRemoveWindowBeforeActiveAdjustsIndex() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
        group.switchTo(index: 2) // Window 3 is active
        group.removeWindow(at: 0) // Remove Window 1
        XCTAssertEqual(group.activeIndex, 1)
        XCTAssertEqual(group.activeWindow?.id, 3)
    }

    func testSwitchToIndex() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        group.switchTo(index: 1)
        XCTAssertEqual(group.activeIndex, 1)
    }

    func testSwitchToInvalidIndexDoesNothing() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero)
        group.switchTo(index: 5)
        XCTAssertEqual(group.activeIndex, 0)
    }

    func testSwitchToWindowID() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        group.switchTo(windowID: 2)
        XCTAssertEqual(group.activeIndex, 1)
    }

    func testMoveTab() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.moveTab(from: 0, to: 2)
        XCTAssertEqual(group.windows.map(\.id), [2, 1, 3])
    }

    func testMoveTabUpdatesActiveIndex() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.switchTo(index: 0)
        group.moveTab(from: 0, to: 2)
        XCTAssertEqual(group.activeIndex, 1)
        XCTAssertEqual(group.activeWindow?.id, 1)
    }

    func testPinWindowMovesTabToPinnedArea() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.pinWindow(withID: 3)

        XCTAssertEqual(group.windows.map(\.id), [3, 1, 2])
        XCTAssertEqual(group.pinnedCount, 1)
        XCTAssertTrue(group.windows[0].isPinned)
    }

    func testPinWindowIgnoresSeparator() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeSeparator(id: 4), makeWindow(id: 2)], frame: .zero)
        group.pinWindow(withID: 4)

        XCTAssertEqual(group.pinnedCount, 0)
        XCTAssertFalse(group.windows.first(where: { $0.id == 4 })?.isPinned ?? false)
    }

    func testPinWindowAtSpecificPinnedIndex() {
        let w1 = makeWindow(id: 1)
        var w2 = makeWindow(id: 2)
        w2.isPinned = true
        let group = TabGroup(windows: [w2, w1, makeWindow(id: 3)], frame: .zero)

        group.pinWindow(withID: 3, at: 0)

        XCTAssertEqual(group.windows.map(\.id), [3, 2, 1])
        XCTAssertEqual(group.pinnedCount, 2)
        XCTAssertTrue(group.windows[0].isPinned)
        XCTAssertTrue(group.windows[1].isPinned)
    }

    func testUnpinWindowMovesTabOutOfPinnedArea() {
        var w1 = makeWindow(id: 1)
        var w2 = makeWindow(id: 2)
        w1.isPinned = true
        w2.isPinned = true
        let group = TabGroup(windows: [w1, w2, makeWindow(id: 3)], frame: .zero)

        group.unpinWindow(withID: 1)

        XCTAssertEqual(group.windows.map(\.id), [2, 1, 3])
        XCTAssertEqual(group.pinnedCount, 1)
        XCTAssertFalse(group.windows[1].isPinned)
    }

    func testMovePinnedTabReordersWithinPinnedAreaOnly() {
        var w1 = makeWindow(id: 1)
        var w2 = makeWindow(id: 2)
        w1.isPinned = true
        w2.isPinned = true
        let group = TabGroup(windows: [w1, w2, makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)

        group.movePinnedTab(withID: 2, toPinnedIndex: 0)

        XCTAssertEqual(group.windows.map(\.id), [2, 1, 3, 4])
        XCTAssertEqual(group.pinnedCount, 2)
    }

    func testMoveUnpinnedTabKeepsPinnedBoundary() {
        var w1 = makeWindow(id: 1)
        w1.isPinned = true
        let group = TabGroup(windows: [w1, makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)

        group.moveUnpinnedTab(withID: 4, toUnpinnedIndex: 0)

        XCTAssertEqual(group.windows.map(\.id), [1, 4, 2, 3])
        XCTAssertEqual(group.pinnedCount, 1)
        XCTAssertTrue(group.windows[0].isPinned)
    }

    func testSetPinnedNormalizesPinnedFirstAndKeepsActiveWindow() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.switchTo(windowID: 2)

        group.setPinned(true, forWindowIDs: [3, 1])

        XCTAssertEqual(group.windows.map(\.id), [1, 3, 2])
        XCTAssertEqual(group.activeWindow?.id, 2)
        XCTAssertEqual(group.pinnedCount, 2)
    }

    func testSetSuperPinnedPlacesSuperpinsAtStartOfPinnedSection() {
        var w1 = makeWindow(id: 1)
        var w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        w1.pinState = .normal
        w2.pinState = .normal
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)

        group.setSuperPinned(true, forWindowIDs: [2])

        XCTAssertEqual(group.windows.map(\.id), [2, 1, 3])
        XCTAssertEqual(group.superPinnedCount, 1)
        XCTAssertEqual(group.pinnedCount, 2)
        XCTAssertEqual(group.windows[0].pinState, .super)
    }

    func testSetPinnedKeepsExistingSuperpinsAheadOfNormalPins() {
        var superPinned = makeWindow(id: 1)
        var normalPinned = makeWindow(id: 2)
        let unpinned = makeWindow(id: 3)
        superPinned.pinState = .super
        normalPinned.pinState = .normal
        let group = TabGroup(windows: [normalPinned, superPinned, unpinned], frame: .zero)

        group.setPinned(true, forWindowIDs: [3])

        XCTAssertEqual(group.windows.map(\.id), [1, 2, 3])
        XCTAssertEqual(group.superPinnedCount, 1)
        XCTAssertEqual(group.windows[0].pinState, .super)
        XCTAssertEqual(group.windows[1].pinState, .normal)
        XCTAssertEqual(group.windows[2].pinState, .normal)
    }

    func testRemoveWindowsWithIDs() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
        group.switchTo(index: 2) // Window 3 is active
        let removed = group.removeWindows(withIDs: [1, 3])
        XCTAssertEqual(removed.map(\.id).sorted(), [1, 3])
        XCTAssertEqual(group.windows.map(\.id), [2, 4])
        // Active was window 3 (removed), should fall to valid index
        XCTAssertTrue(group.activeIndex >= 0 && group.activeIndex < group.windows.count)
    }

    func testRemoveWindowsWithIDsActiveRemovedPrefersPreviousTab() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
        group.switchTo(index: 2) // Window 3 active
        let removed = group.removeWindows(withIDs: [3])
        XCTAssertEqual(removed.map(\.id), [3])
        XCTAssertEqual(group.activeWindow?.id, 2)
        XCTAssertEqual(group.activeIndex, 1)
    }

    func testRemoveWindowsWithIDsPreservesOrder() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4), makeWindow(id: 5)], frame: .zero)
        group.switchTo(index: 4) // Window 5 is active
        let removed = group.removeWindows(withIDs: [2, 4])
        XCTAssertEqual(removed.map(\.id), [2, 4])
        XCTAssertEqual(group.windows.map(\.id), [1, 3, 5])
        XCTAssertEqual(group.activeWindow?.id, 5)
    }

    func testRemoveWindowsWithIDsActiveBeforeRemoved() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.switchTo(index: 0) // Window 1 is active
        let removed = group.removeWindows(withIDs: [2, 3])
        XCTAssertEqual(removed.map(\.id), [2, 3])
        XCTAssertEqual(group.activeWindow?.id, 1)
        XCTAssertEqual(group.activeIndex, 0)
    }

    func testRemoveWindowsEmptySetDoesNothing() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        let removed = group.removeWindows(withIDs: [])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(group.windows.count, 2)
    }

    func testRemoveAllWindows() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        let removed = group.removeWindows(withIDs: [1, 2, 3])
        XCTAssertEqual(removed.count, 3)
        XCTAssertTrue(group.windows.isEmpty)
        XCTAssertEqual(group.activeIndex, 0)
    }

    func testRemovingLastManagedWindowAlsoRemovesSeparators() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeSeparator(id: 500)], frame: .zero)
        _ = group.removeWindow(withID: 1)

        XCTAssertTrue(group.windows.isEmpty)
        XCTAssertEqual(group.managedWindowCount, 0)
    }

    func testMoveTabsToEnd() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4), makeWindow(id: 5)], frame: .zero)
        group.switchTo(index: 0) // Window 1 active
        // toIndex=4 means block's first element targets final position 4.
        // remaining=[2,4,5], insertAt=min(4, 3)=3 → [2,4,5,1,3]
        group.moveTabs(withIDs: [1, 3], toIndex: 4)
        XCTAssertEqual(group.windows.map(\.id), [2, 4, 5, 1, 3])
        XCTAssertEqual(group.activeWindow?.id, 1)
    }

    func testMoveTabsToBeginning() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
        group.switchTo(index: 3) // Window 4 active
        // toIndex=0, remaining=[1,2], insertAt=0 → [3,4,1,2]
        group.moveTabs(withIDs: [3, 4], toIndex: 0)
        XCTAssertEqual(group.windows.map(\.id), [3, 4, 1, 2])
        XCTAssertEqual(group.activeWindow?.id, 4)
    }

    func testMoveTabsPreservesRelativeOrder() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4), makeWindow(id: 5)], frame: .zero)
        // toIndex=1, remaining=[1,3,5], insertAt=1 → [1,2,4,3,5]
        group.moveTabs(withIDs: [4, 2], toIndex: 1)
        XCTAssertEqual(group.windows.map(\.id), [1, 2, 4, 3, 5])
    }

    func testMoveTabsSingleTab() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        // toIndex=2, remaining=[2,3], insertAt=min(2, 2)=2 → [2,3,1]
        group.moveTabs(withIDs: [1], toIndex: 2)
        XCTAssertEqual(group.windows.map(\.id), [2, 3, 1])
    }

    func testMoveTabsToMiddle() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4), makeWindow(id: 5)], frame: .zero)
        // toIndex=2, remaining=[1,3,5], insertAt=min(2, 3)=2 → [1,3,2,4,5]
        group.moveTabs(withIDs: [2, 4], toIndex: 2)
        XCTAssertEqual(group.windows.map(\.id), [1, 3, 2, 4, 5])
    }

    func testMoveTabsNoOpWhenAlreadyInPlace() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.moveTabs(withIDs: [1, 2], toIndex: 0)
        XCTAssertEqual(group.windows.map(\.id), [1, 2, 3])
    }

    func testMoveTabsActiveNotMoved() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
        group.switchTo(index: 1) // Window 2 is active
        // Move windows 3,4 to the beginning; window 2 should stay active
        group.moveTabs(withIDs: [3, 4], toIndex: 0)
        XCTAssertEqual(group.windows.map(\.id), [3, 4, 1, 2])
        XCTAssertEqual(group.activeWindow?.id, 2)
    }

    // MARK: - Multi-Drag Position Delta (TabBarView animation helper)

    func testMultiDragPositionDeltaDragToEnd() {
        // [1,2,3,4,5], drag {1,3} to target=4
        // remaining: [(0,1→skip),(1,2),(2,3→skip),(3,4),(4,5)]
        // remaining without dragged: [(1,2),(3,4),(4,5)], insertAt=min(4,3)=3
        // All non-dragged are before insertAt → no shift for any? No:
        // finalPos 0 (id 2, orig 1): adjustedPos=0, delta=0-1=-1
        // finalPos 1 (id 4, orig 3): adjustedPos=1, delta=1-3=-2
        // finalPos 2 (id 5, orig 4): adjustedPos=2, delta=2-4=-2
        let ids: [CGWindowID] = [1, 2, 3, 4, 5]
        let dragged: Set<CGWindowID> = [1, 3]
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 1, windowIDs: ids, draggedIDs: dragged, targetIndex: 4), -1)
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 3, windowIDs: ids, draggedIDs: dragged, targetIndex: 4), -2)
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 4, windowIDs: ids, draggedIDs: dragged, targetIndex: 4), -2)
    }

    func testMultiDragPositionDeltaDragToBeginning() {
        // [1,2,3,4], drag {3,4} to target=0
        // remaining: [(0,1),(1,2)], insertAt=0
        // finalPos 0 (id 1, orig 0): 0>=0 → adjustedPos=0+2=2, delta=+2
        // finalPos 1 (id 2, orig 1): 1>=0 → adjustedPos=1+2=3, delta=+2
        let ids: [CGWindowID] = [1, 2, 3, 4]
        let dragged: Set<CGWindowID> = [3, 4]
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 0, windowIDs: ids, draggedIDs: dragged, targetIndex: 0), 2)
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 1, windowIDs: ids, draggedIDs: dragged, targetIndex: 0), 2)
    }

    func testMultiDragPositionDeltaNoOp() {
        // [1,2,3,4], drag {1,2} to target=0 — block already at 0
        // remaining: [(2,3),(3,4)], insertAt=0
        // finalPos 0 (id 3, orig 2): 0>=0 → adjustedPos=0+2=2, delta=0
        // finalPos 1 (id 4, orig 3): 1>=0 → adjustedPos=1+2=3, delta=0
        let ids: [CGWindowID] = [1, 2, 3, 4]
        let dragged: Set<CGWindowID> = [1, 2]
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 2, windowIDs: ids, draggedIDs: dragged, targetIndex: 0), 0)
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 3, windowIDs: ids, draggedIDs: dragged, targetIndex: 0), 0)
    }

    func testMultiDragPositionDeltaScatteredToMiddle() {
        // [1,2,3,4,5], drag {1,3,5} to target=2
        // remaining: [(1,2),(3,4)], insertAt=min(2,2)=2
        // finalPos 0 (id 2, orig 1): 0<2 → adjustedPos=0, delta=-1
        // finalPos 1 (id 4, orig 3): 1<2 → adjustedPos=1, delta=-2
        let ids: [CGWindowID] = [1, 2, 3, 4, 5]
        let dragged: Set<CGWindowID> = [1, 3, 5]
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 1, windowIDs: ids, draggedIDs: dragged, targetIndex: 2), -1)
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 3, windowIDs: ids, draggedIDs: dragged, targetIndex: 2), -2)
    }

    func testMultiDragPositionDeltaDraggedTabReturnsZero() {
        // Dragged tabs should return 0 (they use dragTranslation directly)
        let ids: [CGWindowID] = [1, 2, 3, 4]
        let dragged: Set<CGWindowID> = [2, 3]
        XCTAssertEqual(TabBarView.multiDragPositionDelta(for: 1, windowIDs: ids, draggedIDs: dragged, targetIndex: 0), 0)  // index 1 is dragged → not in remaining → returns 0
    }

    func testShouldPinOnDropOnlyWhenDroppingUnpinnedIntoPinnedArea() {
        XCTAssertTrue(TabBarView.shouldPinOnDrop(isPinned: false, pinnedCount: 2, targetIndex: 1))
        XCTAssertFalse(TabBarView.shouldPinOnDrop(isPinned: false, pinnedCount: 2, targetIndex: 2))
        XCTAssertFalse(TabBarView.shouldPinOnDrop(isPinned: true, pinnedCount: 2, targetIndex: 0))
        XCTAssertFalse(TabBarView.shouldPinOnDrop(isPinned: false, pinnedCount: 0, targetIndex: 0))
    }

    func testShouldUnpinOnDropOnlyWhenDroppingPinnedOutsidePinnedArea() {
        XCTAssertTrue(TabBarView.shouldUnpinOnDrop(isPinned: true, pinnedCount: 2, targetIndex: 2))
        XCTAssertTrue(TabBarView.shouldUnpinOnDrop(isPinned: true, pinnedCount: 2, targetIndex: 4))
        XCTAssertFalse(TabBarView.shouldUnpinOnDrop(isPinned: true, pinnedCount: 2, targetIndex: 1))
        XCTAssertFalse(TabBarView.shouldUnpinOnDrop(isPinned: false, pinnedCount: 2, targetIndex: 2))
        XCTAssertFalse(TabBarView.shouldUnpinOnDrop(isPinned: true, pinnedCount: 0, targetIndex: 0))
    }

    func testTabWidthsKeepPinnedTabsNarrower() {
        let widths = TabBarView.tabWidths(
            availableWidth: 600,
            tabCount: 4,
            pinnedCount: 1,
            style: .compact
        )

        XCTAssertEqual(widths.pinned, TabBarView.pinnedTabIdealWidth, accuracy: 0.01)
        XCTAssertGreaterThan(widths.unpinned, widths.pinned)
    }

    func testPinnedTabsUseTighterHorizontalPadding() {
        XCTAssertLessThan(TabBarView.pinnedTabHorizontalPadding, TabBarView.tabHorizontalPadding)
    }

    func testTabWidthLayoutMakesSeparatorHalfWidthOfRegularUnpinnedTab() {
        let tabs = [makeWindow(id: 1), makeSeparator(id: 99), makeWindow(id: 2)]
        let layout = TabBarView.tabWidthLayout(availableWidth: 450, tabs: tabs, style: .equal)

        XCTAssertEqual(layout.widths.count, 3)
        XCTAssertEqual(layout.widths[1], layout.widths[0] * 0.5, accuracy: 0.01)
        XCTAssertEqual(layout.widths[2], layout.widths[0], accuracy: 0.01)
    }

    func testSuperPinnedSectionWidthUsesLeadingSuperPinnedTabs() {
        var superPinnedA = makeWindow(id: 1)
        var superPinnedB = makeWindow(id: 2)
        var normalPinned = makeWindow(id: 3)
        let unpinned = makeWindow(id: 4)
        superPinnedA.pinState = .super
        superPinnedB.pinState = .super
        normalPinned.pinState = .normal
        let tabs = [superPinnedA, superPinnedB, normalPinned, unpinned]
        let widths: [CGFloat] = [30, 30, 40, 90]

        let sectionWidth = TabBarView.superPinnedSectionWidth(tabs: tabs, tabWidths: widths)
        let expected = widths[0] + widths[1] + TabBarView.tabSpacing

        XCTAssertEqual(sectionWidth, expected, accuracy: 0.01)
    }

    func testTabGapAddsExtraSpacingAtPinnedBoundary() {
        var pinned = makeWindow(id: 1)
        pinned.isPinned = true
        let tabs = [pinned, makeWindow(id: 2), makeWindow(id: 3)]

        XCTAssertEqual(
            TabBarView.tabGap(after: 0, tabs: tabs),
            TabBarView.tabSpacing + TabBarView.pinnedSectionSpacing,
            accuracy: 0.01
        )
        XCTAssertEqual(TabBarView.tabGap(after: 1, tabs: tabs), TabBarView.tabSpacing, accuracy: 0.01)
    }

    func testTabContentWidthIncludesPinnedBoundaryGap() {
        var pinned = makeWindow(id: 1)
        pinned.isPinned = true
        let tabs = [pinned, makeWindow(id: 2), makeWindow(id: 3)]
        let widths: [CGFloat] = [40, 100, 100]
        let expected = widths.reduce(0, +)
            + TabBarView.tabSpacing
            + (TabBarView.tabSpacing + TabBarView.pinnedSectionSpacing)

        XCTAssertEqual(TabBarView.tabContentWidth(tabWidths: widths, tabs: tabs), expected, accuracy: 0.01)
    }

    func testInsertionGeometryWithTabsAccountsForPinnedBoundaryGap() {
        var pinned = makeWindow(id: 1)
        pinned.isPinned = true
        let tabs = [pinned, makeWindow(id: 2), makeWindow(id: 3)]
        let widths: [CGFloat] = [40, 100, 100]
        let expectedOffset = widths[0] + (TabBarView.tabSpacing + TabBarView.pinnedSectionSpacing) + widths[1]
        let unpinnedStart = widths[0] + (TabBarView.tabSpacing + TabBarView.pinnedSectionSpacing)
        let unpinnedMidpoint = unpinnedStart + widths[1] / 2

        XCTAssertEqual(TabBarView.insertionOffsetX(for: 2, tabWidths: widths, tabs: tabs), expectedOffset, accuracy: 0.01)
        XCTAssertEqual(TabBarView.insertionIndexForPoint(localTabX: unpinnedMidpoint - 0.5, tabWidths: widths, tabs: tabs), 1)
    }

    func testInsertionIndexForPointUsesPinnedGeometry() {
        let tabCount = 3
        let pinnedCount = 1
        let pinnedWidth: CGFloat = 40
        let unpinnedWidth: CGFloat = 120

        XCTAssertEqual(
            TabBarView.insertionIndexForPoint(
                localTabX: 10,
                tabCount: tabCount,
                pinnedCount: pinnedCount,
                pinnedWidth: pinnedWidth,
                unpinnedWidth: unpinnedWidth
            ),
            0
        )
        XCTAssertEqual(
            TabBarView.insertionIndexForPoint(
                localTabX: 30,
                tabCount: tabCount,
                pinnedCount: pinnedCount,
                pinnedWidth: pinnedWidth,
                unpinnedWidth: unpinnedWidth
            ),
            1
        )
        XCTAssertEqual(
            TabBarView.insertionIndexForPoint(
                localTabX: 170,
                tabCount: tabCount,
                pinnedCount: pinnedCount,
                pinnedWidth: pinnedWidth,
                unpinnedWidth: unpinnedWidth
            ),
            2
        )
        XCTAssertEqual(
            TabBarView.insertionIndexForPoint(
                localTabX: 260,
                tabCount: tabCount,
                pinnedCount: pinnedCount,
                pinnedWidth: pinnedWidth,
                unpinnedWidth: unpinnedWidth
            ),
            3
        )
    }

    func testDragEndActionPrefersCrossPanelDropWhenTargetExists() {
        XCTAssertEqual(
            TabBarView.dragEndAction(hasDropTarget: true, draggedOffBar: false),
            .crossPanelDrop
        )
        XCTAssertEqual(
            TabBarView.dragEndAction(hasDropTarget: true, draggedOffBar: true),
            .crossPanelDrop
        )
    }

    func testDragEndActionDetachesWhenDraggedOffBarWithoutTarget() {
        XCTAssertEqual(
            TabBarView.dragEndAction(hasDropTarget: false, draggedOffBar: true),
            .detachToNewGroup
        )
    }

    func testDragEndActionReordersWhenNotDetachedAndNoTarget() {
        XCTAssertEqual(
            TabBarView.dragEndAction(hasDropTarget: false, draggedOffBar: false),
            .reorderInGroup
        )
    }

    func testShouldDetachForTranslationRequiresExceedingVerticalThreshold() {
        let threshold = TabBarView.crossPanelDetachVerticalThreshold
        XCTAssertFalse(
            TabBarView.shouldDetachForTranslation(
                CGSize(width: 0, height: threshold)
            )
        )
        XCTAssertTrue(
            TabBarView.shouldDetachForTranslation(
                CGSize(width: 0, height: threshold + 0.01)
            )
        )
    }

    func testShouldDetachForTranslationSuppressesStrongHorizontalIntent() {
        XCTAssertFalse(
            TabBarView.shouldDetachForTranslation(
                CGSize(
                    width: TabBarView.horizontalIntentSuppressDetachThreshold,
                    height: TabBarView.crossPanelDetachVerticalThreshold + 50
                )
            )
        )
        XCTAssertFalse(
            TabBarView.shouldDetachForTranslation(
                CGSize(width: 40, height: 42)
            )
        )
        XCTAssertTrue(
            TabBarView.shouldDetachForTranslation(
                CGSize(width: 6, height: 40)
            )
        )
    }

    func testCrossPanelDropSpacesMatchRequiresEqualityWhenBothKnown() {
        XCTAssertTrue(
            AppDelegate.crossPanelDropSpacesMatch(sourceSpaceID: 42, targetSpaceID: 42)
        )
        XCTAssertFalse(
            AppDelegate.crossPanelDropSpacesMatch(sourceSpaceID: 42, targetSpaceID: 7)
        )
    }

    func testCrossPanelDropSpacesMatchAllowsUnknownSpace() {
        XCTAssertTrue(
            AppDelegate.crossPanelDropSpacesMatch(sourceSpaceID: nil, targetSpaceID: 7)
        )
        XCTAssertTrue(
            AppDelegate.crossPanelDropSpacesMatch(sourceSpaceID: 42, targetSpaceID: nil)
        )
        XCTAssertTrue(
            AppDelegate.crossPanelDropSpacesMatch(sourceSpaceID: nil, targetSpaceID: nil)
        )
    }

    func testPointDistanceFromRectIsZeroInsideAndPositiveOutside() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 50)

        XCTAssertEqual(
            AppDelegate.pointDistance(from: NSPoint(x: 150, y: 120), to: rect),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AppDelegate.pointDistance(from: NSPoint(x: 80, y: 120), to: rect),
            20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AppDelegate.pointDistance(from: NSPoint(x: 80, y: 70), to: rect),
            hypot(20, 30),
            accuracy: 0.001
        )
    }

    func testShouldSkipOverlappingPanelDropTargetRequiresCursorInsideBothPanels() {
        let source = CGRect(x: 100, y: 100, width: 200, height: 28)
        let target = CGRect(x: 100, y: 100, width: 200, height: 28)

        XCTAssertTrue(
            AppDelegate.shouldSkipOverlappingPanelDropTarget(
                mouseLocation: NSPoint(x: 150, y: 110),
                sourcePanelFrame: source,
                targetPanelFrame: target
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSkipOverlappingPanelDropTarget(
                mouseLocation: NSPoint(x: 350, y: 110),
                sourcePanelFrame: source,
                targetPanelFrame: target
            )
        )
    }

    func testShouldSkipOverlappingPanelDropTargetFalseWhenSourceFrameUnknown() {
        let target = CGRect(x: 100, y: 100, width: 200, height: 28)

        XCTAssertFalse(
            AppDelegate.shouldSkipOverlappingPanelDropTarget(
                mouseLocation: NSPoint(x: 150, y: 110),
                sourcePanelFrame: nil,
                targetPanelFrame: target
            )
        )
    }

    func testHasExitedSourcePanelForCrossDropUsesTolerance() {
        let source = CGRect(x: 100, y: 100, width: 200, height: 28)

        XCTAssertFalse(
            AppDelegate.hasExitedSourcePanelForCrossDrop(
                mouseLocation: NSPoint(x: 305, y: 110),
                sourcePanelFrame: source
            )
        )
        XCTAssertTrue(
            AppDelegate.hasExitedSourcePanelForCrossDrop(
                mouseLocation: NSPoint(x: 309, y: 110),
                sourcePanelFrame: source
            )
        )
    }

    func testShouldConsiderPanelForCrossDropRequiresVisibleTargetAndSourceExit() {
        let source = CGRect(x: 100, y: 100, width: 200, height: 28)
        let target = CGRect(x: 330, y: 100, width: 200, height: 28)

        XCTAssertFalse(
            AppDelegate.shouldConsiderPanelForCrossDrop(
                mouseLocation: NSPoint(x: 120, y: 110),
                sourcePanelFrame: source,
                targetPanelFrame: target,
                targetPanelIsVisible: true
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldConsiderPanelForCrossDrop(
                mouseLocation: NSPoint(x: 340, y: 110),
                sourcePanelFrame: source,
                targetPanelFrame: target,
                targetPanelIsVisible: false
            )
        )
        XCTAssertTrue(
            AppDelegate.shouldConsiderPanelForCrossDrop(
                mouseLocation: NSPoint(x: 340, y: 110),
                sourcePanelFrame: source,
                targetPanelFrame: target,
                targetPanelIsVisible: true
            )
        )
    }

    func testIsBetterDropCandidatePrefersFrontmostPanelBeforeDistance() {
        XCTAssertTrue(
            AppDelegate.isBetterDropCandidate(
                zOrderIndex: 0,
                hitDistance: 200,
                centerDistance: 200,
                currentZOrderIndex: 3,
                currentHitDistance: 0,
                currentCenterDistance: 0
            )
        )
    }

    func testIsBetterDropCandidateFallsBackToDistanceWhenZOrderUnknown() {
        XCTAssertTrue(
            AppDelegate.isBetterDropCandidate(
                zOrderIndex: nil,
                hitDistance: 1,
                centerDistance: 5,
                currentZOrderIndex: nil,
                currentHitDistance: 4,
                currentCenterDistance: 1
            )
        )
    }

    func testWindowInfoIsFullscreenedDefaultsFalse() {
        let window = makeWindow(id: 1)
        XCTAssertFalse(window.isFullscreened)
    }

    func testFullscreenedWindowsProperty() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        XCTAssertTrue(group.fullscreenedWindowIDs.isEmpty)
        group.windows[1].isFullscreened = true
        XCTAssertEqual(group.fullscreenedWindowIDs, [2])
    }

    func testVisibleWindowsExcludesFullscreened() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.windows[1].isFullscreened = true
        XCTAssertEqual(group.visibleWindows.map(\.id), [1, 3])
    }

    func testVisibleWindowsExcludesSeparators() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeSeparator(id: 42), makeWindow(id: 2)], frame: .zero)
        XCTAssertEqual(group.visibleWindows.map(\.id), [1, 2])
    }

    func testMRUCycleSkipsFullscreenedWindows() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.recordFocus(windowID: 1)
        group.recordFocus(windowID: 2)
        group.recordFocus(windowID: 3)
        // Fullscreen window 2
        group.windows[1].isFullscreened = true
        // Cycle: should skip window 2
        let next1 = group.nextInMRUCycle()
        XCTAssertNotNil(next1)
        // The returned index should not point to window 2
        if let idx = next1 {
            XCTAssertNotEqual(group.windows[idx].id, 2)
        }
    }
}
