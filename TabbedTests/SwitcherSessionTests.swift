import XCTest
@testable import Tabbed

final class SwitcherSessionTests: XCTestCase {

    private func makeItem(id: CGWindowID) -> SwitcherItem {
        let element = AXUIElementCreateSystemWide()
        let window = WindowInfo(
            id: id,
            element: element,
            ownerPID: 1,
            bundleID: "com.test",
            title: "W\(id)",
            appName: "App",
            icon: nil
        )
        return .singleWindow(window)
    }

    func testStartInitializesState() {
        var session = SwitcherSession()
        session.subSelectedWindowID = 99
        session.start(
            items: [makeItem(id: 1), makeItem(id: 2)],
            style: .titles,
            scope: .withinGroup,
            namedGroupLabelMode: .groupNameOnly
        )

        XCTAssertEqual(session.items.count, 2)
        XCTAssertEqual(session.selectedIndex, 0)
        XCTAssertNil(session.subSelectedWindowID)
        XCTAssertEqual(session.style, .titles)
        XCTAssertEqual(session.scope, .withinGroup)
        XCTAssertEqual(session.namedGroupLabelMode, .groupNameOnly)
    }

    func testAdvanceAndRetreatWrap() {
        var session = SwitcherSession()
        session.start(items: [makeItem(id: 1), makeItem(id: 2)], style: .appIcons, scope: .global, namedGroupLabelMode: .groupAppWindow)

        session.advance()
        XCTAssertEqual(session.selectedIndex, 1)
        session.advance()
        XCTAssertEqual(session.selectedIndex, 0)

        session.retreat()
        XCTAssertEqual(session.selectedIndex, 1)
    }

    func testSelectReturnsFalseOutOfRange() {
        var session = SwitcherSession()
        session.start(items: [makeItem(id: 1)], style: .appIcons, scope: .global, namedGroupLabelMode: .groupAppWindow)

        XCTAssertFalse(session.select(index: -1))
        XCTAssertFalse(session.select(index: 2))
        XCTAssertTrue(session.select(index: 0))
    }
}
