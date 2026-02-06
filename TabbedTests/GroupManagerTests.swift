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

    func testCreateGroupRequiresAtLeastTwoWindows() {
        let gm = GroupManager()
        let group = gm.createGroup(with: [makeWindow(id: 1)], frame: .zero)
        XCTAssertNil(group)
        XCTAssertEqual(gm.groups.count, 0)
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

    func testRemoveWindowDissolvesGroupWhenOneLeft() {
        let gm = GroupManager()
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        let group = gm.createGroup(with: windows, frame: .zero)!
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

    // MARK: - Callback Tests

    func testReleaseWindowFiresCallback() {
        let gm = GroupManager()
        var releasedIDs: [CGWindowID] = []
        gm.onWindowReleased = { releasedIDs.append($0.id) }
        let group = gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)!
        gm.releaseWindow(withID: 2, from: group)
        XCTAssertEqual(releasedIDs, [2])
    }

    func testReleaseWindowDissolutionFiresReleasedForAllWindows() {
        let gm = GroupManager()
        var releasedIDs: [CGWindowID] = []
        gm.onWindowReleased = { releasedIDs.append($0.id) }
        let group = gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)!
        gm.releaseWindow(withID: 1, from: group)
        // Both the explicitly released window AND the last survivor get onWindowReleased
        XCTAssertEqual(releasedIDs, [1, 2])
    }

    func testDissolveGroupFiresCallback() {
        let gm = GroupManager()
        var dissolvedWindowCounts: [Int] = []
        gm.onGroupDissolved = { dissolvedWindowCounts.append($0.count) }
        let group = gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)!
        gm.dissolveGroup(group)
        XCTAssertEqual(dissolvedWindowCounts, [2])
    }

    func testDissolveAllGroupsFiresCallbackForEach() {
        let gm = GroupManager()
        var dissolvedCalls = 0
        var releasedIDs: [CGWindowID] = []
        gm.onGroupDissolved = { _ in dissolvedCalls += 1 }
        gm.onWindowReleased = { releasedIDs.append($0.id) }
        gm.createGroup(with: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        gm.createGroup(with: [makeWindow(id: 3), makeWindow(id: 4)], frame: .zero)
        gm.dissolveAllGroups()
        XCTAssertEqual(dissolvedCalls, 2)
        XCTAssertEqual(Set(releasedIDs), [1, 2, 3, 4])
    }
}
