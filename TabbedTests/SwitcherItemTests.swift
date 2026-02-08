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

    // MARK: - window(at:)

    func testWindowAtIndexReturnsCorrectWindow() {
        let w1 = makeWindow(id: 400, title: "First", appName: "App")
        let w2 = makeWindow(id: 401, title: "Second", appName: "App")
        let group = TabGroup(windows: [w1, w2], frame: .zero)
        let item = SwitcherItem.group(group)

        XCTAssertEqual(item.window(at: 0)?.id, 400)
        XCTAssertEqual(item.window(at: 1)?.id, 401)
    }

    func testWindowAtIndexOutOfBoundsReturnsNil() {
        let w1 = makeWindow(id: 400, title: "First", appName: "App")
        let group = TabGroup(windows: [w1], frame: .zero)
        let item = SwitcherItem.group(group)

        XCTAssertNil(item.window(at: 5))
        XCTAssertNil(item.window(at: -1))
    }

    func testWindowAtIndexOnSingleWindowReturnsNil() {
        let window = makeWindow(id: 500, title: "Solo", appName: "App")
        let item = SwitcherItem.singleWindow(window)

        XCTAssertNil(item.window(at: 0))
    }

    // MARK: - Group displayTitle with empty title

    func testGroupDisplayTitleFallsBackToAppName() {
        let w1 = makeWindow(id: 600, title: "", appName: "Finder")
        let group = TabGroup(windows: [w1], frame: .zero)
        let item = SwitcherItem.group(group)

        XCTAssertEqual(item.displayTitle, "Finder")
    }

    // MARK: - iconsInMRUOrder

    func testIconsInMRUOrderReturnsSingleIconForSingleWindow() {
        let window = makeWindow(id: 700, title: "Solo", appName: "App")
        let item = SwitcherItem.singleWindow(window)

        let result = item.iconsInMRUOrder(frontIndex: nil, maxVisible: 4)
        XCTAssertEqual(result.count, 1)
    }

    func testIconsInMRUOrderCapsToMaxVisible() {
        let windows = (0..<5).map { makeWindow(id: CGWindowID(800 + $0), title: "W\($0)", appName: "App") }
        let group = TabGroup(windows: windows, frame: .zero)
        let item = SwitcherItem.group(group)

        let result = item.iconsInMRUOrder(frontIndex: nil, maxVisible: 3)
        XCTAssertEqual(result.count, 3)
    }

    func testIconsInMRUOrderMaxVisibleExceedingCountReturnsAll() {
        let w1 = makeWindow(id: 900, title: "A", appName: "App")
        let w2 = makeWindow(id: 901, title: "B", appName: "App")
        let group = TabGroup(windows: [w1, w2], frame: .zero)
        let item = SwitcherItem.group(group)

        let result = item.iconsInMRUOrder(frontIndex: nil, maxVisible: 10)
        XCTAssertEqual(result.count, 2)
    }

    func testIconsInMRUOrderRespectsGroupFocusHistory() {
        let w1 = makeWindow(id: 1000, title: "A", appName: "App")
        let w2 = makeWindow(id: 1001, title: "B", appName: "App")
        let w3 = makeWindow(id: 1002, title: "C", appName: "App")
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        // Focus w3 then w1 — MRU order becomes [w1, w3, w2] (init seeds [w1,w2,w3])
        group.recordFocus(windowID: 1002) // [1002, 1000, 1001, 1002] -> deduped: [1002, 1000, 1001]
        group.recordFocus(windowID: 1000) // [1000, 1002, 1001]

        let item = SwitcherItem.group(group)
        // frontIndex nil → target = position 0 (most recent = w1/1000)
        // Visible window of 3: [w1, w3, w2] → reversed for ZStack: [w2, w3, w1]
        // All icons are nil in test, but count should be 3
        let result = item.iconsInMRUOrder(frontIndex: nil, maxVisible: 3)
        XCTAssertEqual(result.count, 3)
    }

    func testIconsInMRUOrderWithFrontIndex() {
        let w1 = makeWindow(id: 1100, title: "A", appName: "App")
        let w2 = makeWindow(id: 1101, title: "B", appName: "App")
        let w3 = makeWindow(id: 1102, title: "C", appName: "App")
        let group = TabGroup(windows: [w1, w2, w3], frame: .zero)
        // Focus history after init: [1100, 1101, 1102]

        let item = SwitcherItem.group(group)
        // frontIndex = 2 means target is w3 (windows[2])
        // w3's position in MRU: index 2
        // Sliding window of 2 starting at pos 2: [w3, w1(wraps)] → reversed: [w1, w3]
        let result = item.iconsInMRUOrder(frontIndex: 2, maxVisible: 2)
        XCTAssertEqual(result.count, 2)
    }

    func testIconsInMRUOrderWrapsAround() {
        let windows = (0..<4).map { makeWindow(id: CGWindowID(1200 + $0), title: "W\($0)", appName: "App") }
        let group = TabGroup(windows: windows, frame: .zero)
        let item = SwitcherItem.group(group)

        // frontIndex = 3 (last window), maxVisible = 3
        // MRU after init: [1200, 1201, 1202, 1203]
        // w3's MRU position = 3, sliding window of 3: [w3, w0(wrap), w1(wrap)] → reversed: [w1, w0, w3]
        let result = item.iconsInMRUOrder(frontIndex: 3, maxVisible: 3)
        XCTAssertEqual(result.count, 3)
    }
}
