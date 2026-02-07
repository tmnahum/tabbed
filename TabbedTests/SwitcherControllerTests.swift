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
        controller.onCommit = { committed = $0 }
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
        controller.onCommit = { committed = $0 }
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
}
