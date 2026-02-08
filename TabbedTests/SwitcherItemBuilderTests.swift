import XCTest
@testable import Tabbed

final class SwitcherItemBuilderTests: XCTestCase {

    private func makeWindow(id: CGWindowID, appName: String = "App", title: String = "") -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(id: id, element: element, ownerPID: 1, bundleID: "com.test", title: title, appName: appName, icon: nil)
    }

    func testUngroupedWindowsPreserveZOrder() {
        let w1 = makeWindow(id: 1, appName: "A")
        let w2 = makeWindow(id: 2, appName: "B")
        let w3 = makeWindow(id: 3, appName: "C")

        let items = SwitcherItemBuilder.build(zOrderedWindows: [w1, w2, w3], groups: [])

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].windowIDs, [1])
        XCTAssertEqual(items[1].windowIDs, [2])
        XCTAssertEqual(items[2].windowIDs, [3])
    }

    func testGroupCoalescedAtFrontmostPosition() {
        // z-order: w1(ungrouped), w2(in group), w3(ungrouped), w4(in group)
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let w4 = makeWindow(id: 4)

        let group = TabGroup(windows: [w2, w4], frame: .zero)

        let items = SwitcherItemBuilder.build(zOrderedWindows: [w1, w2, w3, w4], groups: [group])

        // Expected: w1, group(w2+w4), w3
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].windowIDs, [1])
        XCTAssertTrue(items[1].isGroup)
        XCTAssertEqual(items[1].windowCount, 2)
        XCTAssertEqual(items[2].windowIDs, [3])
    }

    func testEmptyInput() {
        let items = SwitcherItemBuilder.build(zOrderedWindows: [], groups: [])
        XCTAssertTrue(items.isEmpty)
    }

    func testMultipleGroups() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let w4 = makeWindow(id: 4)

        let groupA = TabGroup(windows: [w1, w3], frame: .zero)
        let groupB = TabGroup(windows: [w2, w4], frame: .zero)

        let items = SwitcherItemBuilder.build(zOrderedWindows: [w1, w2, w3, w4], groups: [groupA, groupB])

        // w1 is first in z-order and in groupA -> groupA appears at position 0
        // w2 is next and in groupB -> groupB appears at position 1
        // w3 and w4 are already claimed by their groups
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isGroup)
        XCTAssertTrue(items[1].isGroup)
    }

    func testGroupWithOnlyOneWindowInZOrder() {
        // Group has w2 and w4, but only w2 appears in z-ordered windows
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w4 = makeWindow(id: 4)

        let group = TabGroup(windows: [w2, w4], frame: .zero)

        let items = SwitcherItemBuilder.build(zOrderedWindows: [w1, w2], groups: [group])

        // w1 is ungrouped, w2 triggers group placement
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].windowIDs, [1])
        XCTAssertTrue(items[1].isGroup)
        XCTAssertEqual(items[1].windowCount, 2) // group still has both windows
    }

    func testGroupNotInZOrderIsOmitted() {
        // Group exists but none of its windows appear in z-order
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = TabGroup(windows: [w2, w3], frame: .zero)

        let items = SwitcherItemBuilder.build(zOrderedWindows: [w1], groups: [group])

        // Only w1 appears — group never encountered
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].windowIDs, [1])
    }

    func testWindowInGroupIsNotDuplicated() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        let items = SwitcherItemBuilder.build(zOrderedWindows: [w1, w2], groups: [group])

        // Both windows are in the group — should produce just one group item
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isGroup)
        XCTAssertEqual(items[0].windowCount, 2)
    }

    func testSingleWindowGroup() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = TabGroup(windows: [w1], frame: .zero)

        let items = SwitcherItemBuilder.build(zOrderedWindows: [w1, w2], groups: [group])

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isGroup)
        XCTAssertEqual(items[0].windowCount, 1)
        XCTAssertEqual(items[1].windowIDs, [2])
    }

    func testMixedGroupedAndUngroupedPreservesOrder() {
        // z-order: w5, w3(groupA), w1, w2(groupB), w4(groupA)
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let w4 = makeWindow(id: 4)
        let w5 = makeWindow(id: 5)

        let groupA = TabGroup(windows: [w3, w4], frame: .zero)
        let groupB = TabGroup(windows: [w2], frame: .zero)

        let items = SwitcherItemBuilder.build(
            zOrderedWindows: [w5, w3, w1, w2, w4],
            groups: [groupA, groupB]
        )

        // Expected: w5, groupA (at w3's position), w1, groupB (at w2's position)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].windowIDs, [5])
        XCTAssertTrue(items[1].isGroup)
        XCTAssertEqual(items[1].windowCount, 2) // groupA
        XCTAssertEqual(items[2].windowIDs, [1])
        XCTAssertTrue(items[3].isGroup)
        XCTAssertEqual(items[3].windowCount, 1) // groupB
    }
}
