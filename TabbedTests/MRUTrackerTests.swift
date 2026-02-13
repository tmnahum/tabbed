import XCTest
@testable import Tabbed

final class MRUTrackerTests: XCTestCase {

    private func makeWindow(id: CGWindowID, appName: String = "App", cgBounds: CGRect? = nil) -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(
            id: id,
            element: element,
            ownerPID: 1,
            bundleID: "com.test",
            title: appName,
            appName: appName,
            icon: nil,
            cgBounds: cgBounds
        )
    }

    func testRecordActivationDeduplicatesAndMovesEntryToFront() {
        let tracker = MRUTracker()

        tracker.recordActivation(.window(10))
        tracker.recordActivation(.group(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)) // swiftlint:disable:this force_unwrapping
        tracker.recordActivation(.window(10))

        XCTAssertEqual(tracker.entries.count, 2)
        XCTAssertEqual(tracker.entries.first, .window(10))
    }

    func testAppendIfMissingPreservesExistingOrder() {
        let tracker = MRUTracker()
        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")! // swiftlint:disable:this force_unwrapping

        tracker.appendIfMissing(.group(id))
        tracker.appendIfMissing(.group(id))

        XCTAssertEqual(tracker.entries, [.group(id)])
    }

    func testRemoveWindowRemovesStandaloneAndGroupedWindowEntries() {
        let tracker = MRUTracker()
        let groupID = UUID()

        tracker.recordActivation(.groupWindow(groupID: groupID, windowID: 12))
        tracker.recordActivation(.window(12))
        tracker.recordActivation(.groupWindow(groupID: groupID, windowID: 13))

        tracker.removeWindow(12)

        XCTAssertEqual(tracker.entries, [.groupWindow(groupID: groupID, windowID: 13)])
    }

    func testRemoveGroupRemovesLegacyAndGroupedWindowEntries() {
        let tracker = MRUTracker()
        let groupID = UUID()
        let otherGroupID = UUID()

        tracker.recordActivation(.group(groupID))
        tracker.recordActivation(.groupWindow(groupID: groupID, windowID: 22))
        tracker.recordActivation(.groupWindow(groupID: otherGroupID, windowID: 23))

        tracker.removeGroup(groupID)

        XCTAssertEqual(tracker.entries, [.groupWindow(groupID: otherGroupID, windowID: 23)])
    }

    func testMRUGroupOrderReturnsOnlyGroups() {
        let tracker = MRUTracker()
        let groupA = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")! // swiftlint:disable:this force_unwrapping
        let groupB = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")! // swiftlint:disable:this force_unwrapping

        tracker.recordActivation(.group(groupA))
        tracker.recordActivation(.window(42))
        tracker.recordActivation(.group(groupB))

        XCTAssertEqual(tracker.mruGroupOrder(), [groupB, groupA])
    }

    func testMRUGroupOrderIncludesGroupWindowEntriesWithoutDuplicates() {
        let tracker = MRUTracker()
        let groupA = UUID()
        let groupB = UUID()

        tracker.recordActivation(.groupWindow(groupID: groupA, windowID: 10))
        tracker.recordActivation(.groupWindow(groupID: groupA, windowID: 11))
        tracker.recordActivation(.groupWindow(groupID: groupB, windowID: 20))

        XCTAssertEqual(tracker.mruGroupOrder(), [groupB, groupA])
    }

    func testBuildSwitcherItemsUsesMRUThenZOrderWithoutDuplicates() {
        let tracker = MRUTracker()

        let groupAFrame = CGRect(x: 10, y: 10, width: 500, height: 400)
        let groupBFrame = CGRect(x: 520, y: 10, width: 500, height: 400)

        let a1 = makeWindow(id: 1, appName: "A1", cgBounds: groupAFrame)
        let a2 = makeWindow(id: 2, appName: "A2", cgBounds: groupAFrame)
        let b1 = makeWindow(id: 3, appName: "B1", cgBounds: groupBFrame)
        let loose = makeWindow(id: 4, appName: "Loose", cgBounds: CGRect(x: 20, y: 430, width: 400, height: 300))

        let groupA = TabGroup(windows: [a1, a2], frame: groupAFrame)
        let groupB = TabGroup(windows: [b1], frame: groupBFrame)

        tracker.recordActivation(.group(groupA.id))
        tracker.recordActivation(.window(loose.id))

        // z-order: groupB member first, then groupA member, then loose, then second groupA member.
        let items = tracker.buildSwitcherItems(groups: [groupA, groupB], zOrderedWindows: [b1, a1, loose, a2])

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].windowIDs, [loose.id]) // MRU window first
        XCTAssertTrue(items[1].isGroup)                // MRU group second
        XCTAssertEqual(items[1].windowCount, 2)
        XCTAssertTrue(items[2].isGroup)                // Remaining group from z-order
        XCTAssertEqual(items[2].windowIDs, [b1.id])
    }

    func testBuildSwitcherItemsAddsGroupsWithNoVisibleMembers() {
        let tracker = MRUTracker()
        let groupFrame = CGRect(x: 100, y: 100, width: 500, height: 400)

        let groupedWindow = makeWindow(id: 11, appName: "Grouped", cgBounds: groupFrame)
        let ungroupedWindow = makeWindow(id: 99, appName: "Loose", cgBounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        let group = TabGroup(windows: [groupedWindow], frame: groupFrame)

        let items = tracker.buildSwitcherItems(groups: [group], zOrderedWindows: [ungroupedWindow])

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].windowIDs, [ungroupedWindow.id])
        XCTAssertTrue(items[1].isGroup)
    }

    func testBuildSwitcherItemsFiltersUngroupedFrameMatchAgainstGroupFrame() {
        let tracker = MRUTracker()
        let groupFrame = CGRect(x: 200, y: 200, width: 640, height: 480)

        let groupedWindow = makeWindow(id: 21, appName: "Grouped", cgBounds: groupFrame)
        let ghostWindow = makeWindow(id: 22, appName: "Ghost", cgBounds: groupFrame)
        let group = TabGroup(windows: [groupedWindow], frame: groupFrame)

        let items = tracker.buildSwitcherItems(groups: [group], zOrderedWindows: [ghostWindow])

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isGroup)
        XCTAssertEqual(items[0].windowIDs, [groupedWindow.id])
    }

    func testBuildSwitcherItemsSplitByPinnedTabsCreatesMultipleGroupEntries() {
        let tracker = MRUTracker()
        var pinnedA = makeWindow(id: 31, appName: "PinnedA")
        var pinnedB = makeWindow(id: 32, appName: "PinnedB")
        let unpinned = makeWindow(id: 33, appName: "Unpinned")
        pinnedA.isPinned = true
        pinnedB.isPinned = true
        let group = TabGroup(windows: [pinnedA, pinnedB, unpinned], frame: .zero)

        let items = tracker.buildSwitcherItems(
            groups: [group],
            zOrderedWindows: [pinnedA, unpinned, pinnedB],
            splitPinnedTabsIntoSeparateGroup: true
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isGroup)
        XCTAssertTrue(items[1].isGroup)
        XCTAssertEqual(items[0].windowIDs, [31, 32])
        XCTAssertEqual(items[1].windowIDs, [33])
    }

    func testBuildSwitcherItemsSplitBySeparatorsCreatesMultipleGroupEntries() {
        let tracker = MRUTracker()
        let w1 = makeWindow(id: 41, appName: "A")
        let separator = WindowInfo.separator(withID: 4_000_001_111)
        let w2 = makeWindow(id: 42, appName: "B")
        let w3 = makeWindow(id: 43, appName: "C")
        let group = TabGroup(windows: [w1, separator, w2, w3], frame: .zero)

        let items = tracker.buildSwitcherItems(
            groups: [group],
            zOrderedWindows: [w2, w1, w3],
            splitSeparatedTabsIntoSeparateGroups: true
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].windowIDs, [42, 43])
        XCTAssertEqual(items[1].windowIDs, [41])
    }

    func testBuildSwitcherItemsSplitByPinnedTabsStartsFromActiveSegment() {
        let tracker = MRUTracker()
        var pinnedA = makeWindow(id: 51, appName: "PinnedA")
        let unpinned = makeWindow(id: 52, appName: "Unpinned")
        pinnedA.isPinned = true
        let group = TabGroup(windows: [pinnedA, unpinned], frame: .zero)

        group.switchTo(index: 1)
        group.recordFocus(windowID: unpinned.id)
        tracker.recordActivation(.group(group.id))

        let items = tracker.buildSwitcherItems(
            groups: [group],
            zOrderedWindows: [unpinned, pinnedA],
            splitPinnedTabsIntoSeparateGroup: true
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].windowIDs, [52])
        XCTAssertEqual(items[1].windowIDs, [51])
    }

    func testBuildSwitcherItemsSplitByPinnedTabsUsesSegmentMRUFromGroupWindowEntry() {
        let tracker = MRUTracker()
        var pinnedA = makeWindow(id: 61, appName: "PinnedA")
        let unpinned = makeWindow(id: 62, appName: "Unpinned")
        pinnedA.isPinned = true
        let group = TabGroup(windows: [pinnedA, unpinned], frame: .zero)
        group.switchTo(index: 0)

        tracker.recordActivation(.groupWindow(groupID: group.id, windowID: unpinned.id))

        let items = tracker.buildSwitcherItems(
            groups: [group],
            zOrderedWindows: [pinnedA, unpinned],
            splitPinnedTabsIntoSeparateGroup: true
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].windowIDs, [62])
        XCTAssertEqual(items[1].windowIDs, [61])
    }

    func testBuildSwitcherItemsSplitGroupsInterleaveBySegmentMRU() {
        let tracker = MRUTracker()

        var g1Pinned = makeWindow(id: 71, appName: "G1Pinned")
        let g1Unpinned = makeWindow(id: 72, appName: "G1Unpinned")
        g1Pinned.isPinned = true
        let group1 = TabGroup(windows: [g1Pinned, g1Unpinned], frame: .zero)

        var g2Pinned = makeWindow(id: 81, appName: "G2Pinned")
        let g2Unpinned = makeWindow(id: 82, appName: "G2Unpinned")
        g2Pinned.isPinned = true
        let group2 = TabGroup(windows: [g2Pinned, g2Unpinned], frame: .zero)

        tracker.recordActivation(.groupWindow(groupID: group1.id, windowID: g1Unpinned.id))
        tracker.recordActivation(.groupWindow(groupID: group2.id, windowID: g2Pinned.id))

        let items = tracker.buildSwitcherItems(
            groups: [group1, group2],
            zOrderedWindows: [g1Pinned, g2Unpinned, g1Unpinned, g2Pinned],
            splitPinnedTabsIntoSeparateGroup: true
        )

        XCTAssertGreaterThanOrEqual(items.count, 2)
        XCTAssertEqual(items[0].windowIDs, [81])
        XCTAssertEqual(items[1].windowIDs, [72])
    }

    func testRecordActivationPrunesEntriesToMax() {
        let tracker = MRUTracker()

        for index in 0..<1_100 {
            tracker.recordActivation(.window(CGWindowID(index)))
        }

        XCTAssertEqual(tracker.entries.count, 1_024)
        XCTAssertEqual(tracker.entries.first, .window(1_099))
        XCTAssertEqual(tracker.entries.last, .window(76))
    }

    func testAppendIfMissingPrunesEntriesToMax() {
        let tracker = MRUTracker()

        for index in 0..<1_100 {
            tracker.appendIfMissing(.window(CGWindowID(index)))
        }

        XCTAssertEqual(tracker.entries.count, 1_024)
        XCTAssertEqual(tracker.entries.first, .window(0))
        XCTAssertEqual(tracker.entries.last, .window(1_023))
    }
}
