import ApplicationServices
import XCTest
@testable import Tabbed

final class WindowManagerTests: XCTestCase {
    func testUngroupedWindowsExcludesGroupedIDsAndPreservesOrder() {
        let windows = [makeWindow(id: 30), makeWindow(id: 10), makeWindow(id: 20)]

        let result = WindowManager.ungroupedWindows(
            from: windows,
            groupedWindowIDs: [10]
        )

        XCTAssertEqual(result.map(\.id), [30, 20])
    }

    private func makeWindow(id: CGWindowID) -> WindowInfo {
        WindowInfo(
            id: id,
            element: AXUIElementCreateApplication(1),
            ownerPID: 1,
            bundleID: "com.example.app",
            title: "Window \(id)",
            appName: "Example"
        )
    }
}
