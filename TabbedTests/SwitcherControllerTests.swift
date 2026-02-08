import XCTest
@testable import Tabbed

final class SwitcherControllerTests: XCTestCase {

    private func makeWindow(id: CGWindowID, appName: String = "App") -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(id: id, element: element, ownerPID: 1, bundleID: "com.test", title: appName, appName: appName, icon: nil)
    }

    func testAdvanceWrapsAround() {
        let controller = SwitcherController()
        let items = (1...3).map { SwitcherItem.singleWindow(makeWindow(id: CGWindowID($0))) }
        controller.show(items: items, style: .appIcons, scope: .global)

        // selectedIndex starts at 0
        controller.advance() // -> 1
        controller.advance() // -> 2
        controller.advance() // -> 0 (wraps)

        var committed: SwitcherItem?
        controller.onCommit = { item, _ in committed = item }
        controller.commit()
        XCTAssertEqual(committed?.windowIDs, [1])
    }

    func testRetreatWrapsAround() {
        let controller = SwitcherController()
        let items = (1...3).map { SwitcherItem.singleWindow(makeWindow(id: CGWindowID($0))) }
        controller.show(items: items, style: .titles, scope: .global)

        // selectedIndex starts at 0
        controller.retreat() // -> 2 (wraps backward)

        var committed: SwitcherItem?
        controller.onCommit = { item, _ in committed = item }
        controller.commit()
        XCTAssertEqual(committed?.windowIDs, [3])
    }

    func testDismissCallsOnDismiss() {
        let controller = SwitcherController()
        let items = [SwitcherItem.singleWindow(makeWindow(id: 1))]
        controller.show(items: items, style: .appIcons, scope: .global)

        var dismissed = false
        controller.onDismiss = { dismissed = true }
        controller.dismiss()
        XCTAssertTrue(dismissed)
        XCTAssertFalse(controller.isActive)
    }

    func testCommitTearsDown() {
        let controller = SwitcherController()
        let items = [SwitcherItem.singleWindow(makeWindow(id: 1))]
        controller.show(items: items, style: .appIcons, scope: .global)
        XCTAssertTrue(controller.isActive)

        controller.commit()
        XCTAssertFalse(controller.isActive)
    }

    func testShowWithEmptyItemsDoesNothing() {
        let controller = SwitcherController()
        controller.show(items: [], style: .appIcons, scope: .global)
        XCTAssertFalse(controller.isActive)
    }

    // MARK: - Commit passes selection

    func testCommitPassesSelectedItem() {
        let controller = SwitcherController()
        let items = (1...3).map { SwitcherItem.singleWindow(makeWindow(id: CGWindowID($0))) }
        controller.show(items: items, style: .appIcons, scope: .global)

        controller.advance() // -> index 1 (window id 2)

        var committedIDs: [CGWindowID]?
        var committedSubIndex: Int?
        controller.onCommit = { item, subIdx in
            committedIDs = item.windowIDs
            committedSubIndex = subIdx
        }
        controller.commit()
        XCTAssertEqual(committedIDs, [2])
        XCTAssertNil(committedSubIndex)
    }

    func testCommitWithNoItemsDismisses() {
        let controller = SwitcherController()
        // Don't show anything — items is empty

        var dismissed = false
        controller.onDismiss = { dismissed = true }
        controller.commit()
        XCTAssertTrue(dismissed)
    }

    // MARK: - Advance/retreat on empty is a no-op

    func testAdvanceOnEmptyDoesNotCrash() {
        let controller = SwitcherController()
        controller.advance()
        controller.retreat()
        // No crash = pass
    }

    // MARK: - Scope

    func testScopeIsSetCorrectly() {
        let controller = SwitcherController()
        let items = [SwitcherItem.singleWindow(makeWindow(id: 1))]

        controller.show(items: items, style: .appIcons, scope: .global)
        XCTAssertEqual(controller.scope, .global)

        controller.dismiss()
        controller.show(items: items, style: .titles, scope: .withinGroup)
        XCTAssertEqual(controller.scope, .withinGroup)
    }

    // MARK: - cycleWithinGroup

    func testCycleWithinGroupOnSingleWindowIsNoOp() {
        let controller = SwitcherController()
        let items = [SwitcherItem.singleWindow(makeWindow(id: 1))]
        controller.show(items: items, style: .appIcons, scope: .global)

        controller.cycleWithinGroup()
        XCTAssertNil(controller.subSelectedWindowIndex)
    }

    func testCycleWithinGroupSetsSubSelection() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 10, appName: "A")
        let w2 = makeWindow(id: 11, appName: "B")
        let w3 = makeWindow(id: 12, appName: "C")
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        // Focus history after init: [10, 11, 12]

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .appIcons, scope: .global)

        // First cycle: starts at MRU position 0, advances to position 1
        controller.cycleWithinGroup()
        XCTAssertNotNil(controller.subSelectedWindowIndex)
    }

    func testCycleWithinGroupWrapsAround() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 20, appName: "A")
        let w2 = makeWindow(id: 21, appName: "B")
        let group = TabGroup(windows: [w1, w2], frame: .zero)
        // Focus history: [20, 21] — MRU indices: [0, 1]

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .appIcons, scope: .global)

        // Cycle through: pos 0 -> 1, then 1 -> 0 (wrap)
        controller.cycleWithinGroup() // pos 0 → 1
        let first = controller.subSelectedWindowIndex
        controller.cycleWithinGroup() // pos 1 → 0 (wrap)
        let second = controller.subSelectedWindowIndex

        XCTAssertNotEqual(first, second)
    }

    func testCycleWithinGroupRequiresGlobalScope() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 30, appName: "A")
        let w2 = makeWindow(id: 31, appName: "B")
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .appIcons, scope: .withinGroup)

        controller.cycleWithinGroup()
        XCTAssertNil(controller.subSelectedWindowIndex)
    }

    // MARK: - cycleWithinGroupBackward

    func testCycleWithinGroupBackward() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 40, appName: "A")
        let w2 = makeWindow(id: 41, appName: "B")
        let w3 = makeWindow(id: 42, appName: "C")
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .appIcons, scope: .global)

        // Backward from position 0 wraps to last
        controller.cycleWithinGroupBackward()
        XCTAssertNotNil(controller.subSelectedWindowIndex)
    }

    func testCycleWithinGroupBackwardOnSingleWindowIsNoOp() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 50, appName: "A")
        let group = TabGroup(windows: [w1], frame: .zero)

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .appIcons, scope: .global)

        controller.cycleWithinGroupBackward()
        XCTAssertNil(controller.subSelectedWindowIndex)
    }

    // MARK: - Advance clears sub-selection

    func testAdvanceClearsSubSelection() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 60, appName: "A")
        let w2 = makeWindow(id: 61, appName: "B")
        let group = TabGroup(windows: [w1, w2], frame: .zero)
        let singleWindow = makeWindow(id: 62, appName: "C")

        let items: [SwitcherItem] = [.group(group), .singleWindow(singleWindow)]
        controller.show(items: items, style: .appIcons, scope: .global)

        controller.cycleWithinGroup() // sets sub-selection
        XCTAssertNotNil(controller.subSelectedWindowIndex)

        controller.advance() // should clear sub-selection
        XCTAssertNil(controller.subSelectedWindowIndex)
    }

    func testRetreatClearsSubSelection() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 70, appName: "A")
        let w2 = makeWindow(id: 71, appName: "B")
        let group = TabGroup(windows: [w1, w2], frame: .zero)
        let singleWindow = makeWindow(id: 72, appName: "C")

        let items: [SwitcherItem] = [.group(group), .singleWindow(singleWindow)]
        controller.show(items: items, style: .appIcons, scope: .global)

        controller.cycleWithinGroup()
        XCTAssertNotNil(controller.subSelectedWindowIndex)

        controller.retreat()
        XCTAssertNil(controller.subSelectedWindowIndex)
    }

    // MARK: - Commit with sub-selection

    func testCommitPassesSubSelection() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 80, appName: "A")
        let w2 = makeWindow(id: 81, appName: "B")
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .appIcons, scope: .global)

        controller.cycleWithinGroup() // sets sub-selection

        var committedSubIndex: Int?
        controller.onCommit = { _, subIdx in committedSubIndex = subIdx }
        controller.commit()
        XCTAssertNotNil(committedSubIndex)
    }

    // MARK: - handleArrowKey

    func testArrowKeyAppIconsLeftRightAdvancesRetreats() {
        let controller = SwitcherController()
        let items = (1...3).map { SwitcherItem.singleWindow(makeWindow(id: CGWindowID($0))) }
        controller.show(items: items, style: .appIcons, scope: .global)

        // Right = advance in appIcons mode
        controller.handleArrowKey(.right) // -> 1
        controller.handleArrowKey(.right) // -> 2

        var committed: SwitcherItem?
        controller.onCommit = { item, _ in committed = item }
        controller.commit()
        XCTAssertEqual(committed?.windowIDs, [3])
    }

    func testArrowKeyAppIconsLeftRetreats() {
        let controller = SwitcherController()
        let items = (1...3).map { SwitcherItem.singleWindow(makeWindow(id: CGWindowID($0))) }
        controller.show(items: items, style: .appIcons, scope: .global)

        controller.handleArrowKey(.left) // wraps to 2

        var committed: SwitcherItem?
        controller.onCommit = { item, _ in committed = item }
        controller.commit()
        XCTAssertEqual(committed?.windowIDs, [3])
    }

    func testArrowKeyTitlesUpDownAdvancesRetreats() {
        let controller = SwitcherController()
        let items = (1...3).map { SwitcherItem.singleWindow(makeWindow(id: CGWindowID($0))) }
        controller.show(items: items, style: .titles, scope: .global)

        // Down = advance in titles mode
        controller.handleArrowKey(.down) // -> 1

        var committed: SwitcherItem?
        controller.onCommit = { item, _ in committed = item }
        controller.commit()
        XCTAssertEqual(committed?.windowIDs, [2])
    }

    func testArrowKeyTitlesUpRetreats() {
        let controller = SwitcherController()
        let items = (1...3).map { SwitcherItem.singleWindow(makeWindow(id: CGWindowID($0))) }
        controller.show(items: items, style: .titles, scope: .global)

        controller.handleArrowKey(.up) // wraps to 2

        var committed: SwitcherItem?
        controller.onCommit = { item, _ in committed = item }
        controller.commit()
        XCTAssertEqual(committed?.windowIDs, [3])
    }

    func testArrowKeyAppIconsDownUpCyclesWithinGroup() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 90, appName: "A")
        let w2 = makeWindow(id: 91, appName: "B")
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .appIcons, scope: .global)

        // In appIcons, down/up is the secondary axis → cycles within group
        controller.handleArrowKey(.down)
        XCTAssertNotNil(controller.subSelectedWindowIndex)
    }

    func testArrowKeyTitlesLeftRightCyclesWithinGroup() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 95, appName: "A")
        let w2 = makeWindow(id: 96, appName: "B")
        let group = TabGroup(windows: [w1, w2], frame: .zero)

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .titles, scope: .global)

        // In titles, left/right is the secondary axis → cycles within group
        controller.handleArrowKey(.right)
        XCTAssertNotNil(controller.subSelectedWindowIndex)
    }

    // MARK: - cycleWithinGroup with focus history

    func testCycleWithinGroupFollowsMRUOrder() {
        let controller = SwitcherController()
        let w1 = makeWindow(id: 110, appName: "A")
        let w2 = makeWindow(id: 111, appName: "B")
        let w3 = makeWindow(id: 112, appName: "C")
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        // Init seeds focusHistory: [110, 111, 112]
        // Record focus on w3 then w2 → focusHistory: [111, 112, 110]
        group.recordFocus(windowID: 112)
        group.recordFocus(windowID: 111)

        let items = [SwitcherItem.group(group)]
        controller.show(items: items, style: .appIcons, scope: .global)

        // MRU indices: w2(idx 1), w3(idx 2), w1(idx 0)
        // First cycle: pos 0 → pos 1 → should select w3's index (2)
        controller.cycleWithinGroup()
        XCTAssertEqual(controller.subSelectedWindowIndex, 2) // w3

        controller.cycleWithinGroup()
        XCTAssertEqual(controller.subSelectedWindowIndex, 0) // w1

        controller.cycleWithinGroup()
        XCTAssertEqual(controller.subSelectedWindowIndex, 1) // w2 (wraps)
    }
}
