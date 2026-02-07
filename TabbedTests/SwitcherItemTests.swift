import XCTest
@testable import Tabbed

final class SwitcherItemTests: XCTestCase {

    // MARK: - Helpers

    /// Create a minimal WindowInfo for testing (no real AXUIElement needed).
    private func makeWindow(id: CGWindowID, title: String, appName: String) -> WindowInfo {
        let element = AXUIElementCreateSystemWide() // dummy; never used in model tests
        return WindowInfo(
            id: id,
            element: element,
            ownerPID: 1,
            bundleID: "com.test.\(appName.lowercased())",
            title: title,
            appName: appName,
            icon: nil
        )
    }

    // MARK: - Single window

    func testSingleWindowItem() {
        let window = makeWindow(id: 100, title: "Inbox", appName: "Mail")
        let item = SwitcherItem.singleWindow(window)

        XCTAssertEqual(item.displayTitle, "Inbox")
        XCTAssertEqual(item.appName, "Mail")
        XCTAssertEqual(item.windowCount, 1)
        XCTAssertEqual(item.windowIDs, [100])
        XCTAssertFalse(item.isGroup)
    }

    func testSingleWindowFallbackTitle() {
        let window = makeWindow(id: 101, title: "", appName: "Finder")
        let item = SwitcherItem.singleWindow(window)
        XCTAssertEqual(item.displayTitle, "Finder")
    }

    // MARK: - Group

    func testGroupItem() {
        let w1 = makeWindow(id: 200, title: "Tab 1", appName: "Safari")
        let w2 = makeWindow(id: 201, title: "Tab 2", appName: "Firefox")
        let group = TabGroup(windows: [w1, w2], frame: .zero)
        group.switchTo(index: 1) // Firefox active

        let item = SwitcherItem.group(group)

        XCTAssertTrue(item.isGroup)
        XCTAssertEqual(item.displayTitle, "Tab 2") // active window title
        XCTAssertEqual(item.windowCount, 2)
        XCTAssertEqual(item.windowIDs.count, 2)
        XCTAssertTrue(item.windowIDs.contains(200))
        XCTAssertTrue(item.windowIDs.contains(201))
    }

    func testGroupIcons() {
        let w1 = makeWindow(id: 300, title: "A", appName: "A")
        let w2 = makeWindow(id: 301, title: "B", appName: "B")
        let w3 = makeWindow(id: 302, title: "C", appName: "C")
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        let item = SwitcherItem.group(group)

        // icons returns all window icons (nil in test, but count should match)
        XCTAssertEqual(item.icons.count, 3)
    }
}
