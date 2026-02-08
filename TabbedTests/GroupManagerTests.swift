import XCTest
@testable import Tabbed
import ApplicationServices

final class GroupManagerTests: XCTestCase {
    func makeWindow(id: CGWindowID) -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(
            id: id, element: element, ownerPID: 0,
            bundleID: "com.test", title: "Window \(id)",
            appName: "Test", icon: nil
        )
    }

    func testCreateGroup() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        let group = gm.createGroup(with: windows, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNotNil(group)
        XCTAssertEqual(gm.groups.count, 1)
        XCTAssertEqual(group?.windows.count, 2)
    }

    func testCreateGroupWithSingleWindow() {
        let gm = GroupManager()
        let group = gm.createGroup(with: [makeWindow(id: 1)], frame: .zero)
        XCTAssertNotNil(group)
        XCTAssertEqual(gm.groups.count, 1)
        XCTAssertEqual(group?.windows.count, 1)
    }

    func testCreateGroupRejectsEmptyArray() {
        let gm = GroupManager()
        let group = gm.createGroup(with: [], frame: .zero)
        XCTAssertNil(group)
        XCTAssertEqual(gm.groups.count, 0)
    }

    func testCreateGroupRejectsDuplicateWindows() {
        let gm = GroupManager()
        let w1 = makeWindow(id: 1)
        let group = gm.createGroup(with: [w1, w1], frame: .zero)
        XCTAssertNil(group)
        XCTAssertEqual(gm.groups.count, 0)
    }

    func testCannotAddWindowAlreadyInGroup() {
        let gm = GroupManager()
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = gm.createGroup(with: [w1, w2], frame: .zero)!
        gm.addWindow(w1, to: group)
        XCTAssertEqual(group.windows.count, 2)

        // Can't create a new group containing w1 either
        let group2 = gm.createGroup(with: [w1, w3], frame: .zero)
        XCTAssertNil(group2)
    }

    func testAddWindowToForeignGroupIsIgnored() {
        let gm = GroupManager()
        let foreignGroup = TabGroup(windows: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)
        gm.addWindow(makeWindow(id: 3), to: foreignGroup)
        XCTAssertEqual(foreignGroup.windows.count, 2)
    }

    func testFindGroupForWindow() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        gm.createGroup(with: windows, frame: .zero)
        XCTAssertNotNil(gm.group(for: 1))
        XCTAssertNil(gm.group(for: 99))
    }

    func testRemoveWindowKeepsGroupWithOneLeft() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        let group = gm.createGroup(with: windows, frame: .zero)!
        gm.releaseWindow(withID: 1, from: group)
        XCTAssertEqual(gm.groups.count, 1)
        XCTAssertEqual(group.windows.count, 1)
    }

    func testRemoveWindowDissolvesGroupWhenEmpty() {
        let gm = GroupManager()
        let group = gm.createGroup(with: [makeWindow(id: 1)], frame: .zero)!
        gm.releaseWindow(withID: 1, from: group)
        XCTAssertEqual(gm.groups.count, 0)
        XCTAssertFalse(gm.isWindowGrouped(1))
    }

    func testSingleWindowGroupGrowAndShrink() {
        let gm = GroupManager()
        let group = gm.createGroup(with: [makeWindow(id: 1)], frame: .zero)!
        XCTAssertEqual(group.windows.count, 1)

        gm.addWindow(makeWindow(id: 2), to: group)
        XCTAssertEqual(group.windows.count, 2)

        gm.releaseWindow(withID: 2, from: group)
        XCTAssertEqual(gm.groups.count, 1)
        XCTAssertEqual(group.windows.count, 1)

        gm.releaseWindow(withID: 1, from: group)
        XCTAssertEqual(gm.groups.count, 0)
    }

    func testRemoveWindowKeepsGroupWithMultiple() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let group = gm.createGroup(with: windows, frame: .zero)!
        gm.releaseWindow(withID: 1, from: group)
        XCTAssertEqual(gm.groups.count, 1)
        XCTAssertEqual(group.windows.count, 2)
    }

    func testReleaseWindowFromForeignGroupIsIgnored() {
        let gm = GroupManager()
        let foreignGroup = TabGroup(windows: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)
        gm.releaseWindow(withID: 10, from: foreignGroup)
        XCTAssertEqual(foreignGroup.windows.count, 2)
    }

    func testIsWindowGrouped() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        gm.createGroup(with: windows, frame: .zero)
        XCTAssertTrue(gm.isWindowGrouped(1))
        XCTAssertFalse(gm.isWindowGrouped(99))
    }

    func testDissolveGroup() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        let group = gm.createGroup(with: windows, frame: .zero)!
        gm.dissolveGroup(group)
        XCTAssertEqual(gm.groups.count, 0)
    }

    func testDissolveForeignGroupIsIgnored() {
        let gm = GroupManager()
        gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        let foreignGroup = TabGroup(windows: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)
        gm.dissolveGroup(foreignGroup)
        XCTAssertEqual(gm.groups.count, 1)
    }

    func testDissolveAllGroups() {
        let gm = GroupManager()
        gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        gm.createGroup(with: [makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
        XCTAssertEqual(gm.groups.count, 2)
        gm.dissolveAllGroups()
        XCTAssertEqual(gm.groups.count, 0)
    }

    func testReleaseWindowsFromGroup() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let group = gm.createGroup(with: windows, frame: .zero)!
        let released = gm.releaseWindows(withIDs: [1, 3], from: group)
        XCTAssertEqual(released.map(\.id).sorted(), [1, 3])
        XCTAssertEqual(group.windows.count, 1)
        XCTAssertEqual(gm.groups.count, 1)
    }

    func testReleaseAllWindowsDissolvesGroup() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        let group = gm.createGroup(with: windows, frame: .zero)!
        let released = gm.releaseWindows(withIDs: [1, 2], from: group)
        XCTAssertEqual(released.count, 2)
        XCTAssertEqual(gm.groups.count, 0)
    }

    func testReleaseWindowsFromForeignGroupIsIgnored() {
        let gm = GroupManager()
        let foreignGroup = TabGroup(windows: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)
        let released = gm.releaseWindows(withIDs: [10], from: foreignGroup)
        XCTAssertTrue(released.isEmpty)
        XCTAssertEqual(foreignGroup.windows.count, 2)
    }

    // MARK: - Cross-Group Tab Moves

    func testMoveTabsBetweenGroups() {
        let gm = GroupManager()
        let groupA = gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)!
        let groupB = gm.createGroup(with: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)!

        // Release window 2 from group A
        let released = gm.releaseWindows(withIDs: [2], from: groupA)
        XCTAssertEqual(released.count, 1)
        XCTAssertEqual(groupA.windows.map(\.id), [1, 3])

        // Add released window to group B at index 1
        gm.addWindow(released[0], to: groupB, at: 1)
        XCTAssertEqual(groupB.windows.map(\.id), [10, 2, 11])
        XCTAssertEqual(gm.groups.count, 2)
    }

    func testMoveMultipleTabsBetweenGroups() {
        let gm = GroupManager()
        let groupA = gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)!
        let groupB = gm.createGroup(with: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)!

        // Release windows 1 and 3 from group A
        let released = gm.releaseWindows(withIDs: [1, 3], from: groupA)
        XCTAssertEqual(released.count, 2)
        XCTAssertEqual(groupA.windows.map(\.id), [2])

        // Add released windows to group B at index 1 (preserving order)
        for (offset, window) in released.enumerated() {
            gm.addWindow(window, to: groupB, at: 1 + offset)
        }
        XCTAssertEqual(groupB.windows.map(\.id), [10, 1, 3, 11])
    }

    func testMoveAllTabsDissolvesSource() {
        let gm = GroupManager()
        let groupA = gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)!
        let groupB = gm.createGroup(with: [makeWindow(id: 10)], frame: .zero)!

        let released = gm.releaseWindows(withIDs: [1, 2], from: groupA)
        XCTAssertEqual(released.count, 2)
        XCTAssertEqual(gm.groups.count, 1) // groupA dissolved

        for (offset, window) in released.enumerated() {
            gm.addWindow(window, to: groupB, at: 1 + offset)
        }
        XCTAssertEqual(groupB.windows.map(\.id), [10, 1, 2])
        XCTAssertEqual(gm.groups.count, 1)
    }

    func testMoveTabToEndOfTargetGroup() {
        let gm = GroupManager()
        let groupA = gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)!
        let groupB = gm.createGroup(with: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)!

        let released = gm.releaseWindows(withIDs: [1], from: groupA)
        gm.addWindow(released[0], to: groupB, at: 2)
        XCTAssertEqual(groupB.windows.map(\.id), [10, 11, 1])
    }

    func testMoveTabToBeginningOfTargetGroup() {
        let gm = GroupManager()
        let groupA = gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)!
        let groupB = gm.createGroup(with: [makeWindow(id: 10), makeWindow(id: 11)], frame: .zero)!

        let released = gm.releaseWindows(withIDs: [1], from: groupA)
        gm.addWindow(released[0], to: groupB, at: 0)
        XCTAssertEqual(groupB.windows.map(\.id), [1, 10, 11])
    }

    // MARK: - Drop Indicator

    func testDropIndicatorIndexSetAndClear() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        XCTAssertNil(group.dropIndicatorIndex)

        group.dropIndicatorIndex = 1
        XCTAssertEqual(group.dropIndicatorIndex, 1)

        group.dropIndicatorIndex = nil
        XCTAssertNil(group.dropIndicatorIndex)
    }

}
