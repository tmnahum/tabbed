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

    func testMRUGroupOrderReturnsOnlyGroups() {
        let tracker = MRUTracker()
        let groupA = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")! // swiftlint:disable:this force_unwrapping
        let groupB = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")! // swiftlint:disable:this force_unwrapping

        tracker.recordActivation(.group(groupA))
        tracker.recordActivation(.window(42))
        tracker.recordActivation(.group(groupB))

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
}
