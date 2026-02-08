import XCTest
@testable import Tabbed

/// Tests the active-tab correction logic used by session restore.
/// After restore, the frontmostIndex heuristic may pick the wrong active tab.
/// The fix queries the user's actual focused window and calls
/// switchTo(windowID:) + recordFocus(windowID:) to correct it.
/// These tests verify that correction path works correctly.
final class SessionRestoreFocusTests: XCTestCase {

    private func makeWindow(id: CGWindowID) -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(
            id: id, element: element, ownerPID: 0,
            bundleID: "com.test", title: "Window \(id)",
            appName: "Test", icon: nil
        )
    }

    func testSwitchToCorrectsFrontmostIndexHeuristic() {
        // Simulate: restore created group with activeIndex=0 (frontmostIndex picked window 1)
        // but the user actually has window 3 focused
        let group = TabGroup(
            windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)],
            frame: .zero
        )
        group.switchTo(index: 0) // frontmostIndex heuristic picked window 1
        XCTAssertEqual(group.activeWindow?.id, 1)

        // The fix calls switchTo + recordFocus for the actual focused window
        group.switchTo(windowID: 3)
        group.recordFocus(windowID: 3)

        XCTAssertEqual(group.activeIndex, 2)
        XCTAssertEqual(group.activeWindow?.id, 3)
        XCTAssertEqual(group.focusHistory.first, 3)
    }

    func testCorrectionToMiddleTab() {
        let group = TabGroup(
            windows: [makeWindow(id: 10), makeWindow(id: 20), makeWindow(id: 30), makeWindow(id: 40)],
            frame: .zero
        )
        group.switchTo(index: 3) // heuristic picked last window
        XCTAssertEqual(group.activeWindow?.id, 40)

        // Correct to middle tab
        group.switchTo(windowID: 20)
        group.recordFocus(windowID: 20)

        XCTAssertEqual(group.activeIndex, 1)
        XCTAssertEqual(group.activeWindow?.id, 20)
        XCTAssertEqual(group.focusHistory.first, 20)
    }

    func testCorrectionWithNonexistentWindowIDIsNoOp() {
        let group = TabGroup(
            windows: [makeWindow(id: 1), makeWindow(id: 2)],
            frame: .zero
        )
        group.switchTo(index: 0)

        // If the focused window isn't in this group, switchTo does nothing
        group.switchTo(windowID: 999)

        XCTAssertEqual(group.activeIndex, 0)
        XCTAssertEqual(group.activeWindow?.id, 1)
    }

    func testGroupManagerLookupAndCorrection() {
        let gm = GroupManager()
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = gm.createGroup(with: [w1, w2, w3], frame: .zero)!
        group.switchTo(index: 0) // heuristic picked w1

        // Simulate the restore fix: lookup by focused windowID, then correct
        let focusedWindowID: CGWindowID = 3
        if let found = gm.group(for: focusedWindowID) {
            found.switchTo(windowID: focusedWindowID)
            found.recordFocus(windowID: focusedWindowID)
        }

        XCTAssertEqual(group.activeWindow?.id, 3)
        XCTAssertEqual(group.focusHistory.first, 3)
    }

    func testUnfocusedWindowNotInAnyGroup() {
        let gm = GroupManager()
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = gm.createGroup(with: [w1, w2], frame: .zero)!
        group.switchTo(index: 0)

        // Focused window isn't in any group — lookup returns nil, no correction
        let focusedWindowID: CGWindowID = 99
        let found = gm.group(for: focusedWindowID)
        XCTAssertNil(found)

        // Original heuristic preserved
        XCTAssertEqual(group.activeWindow?.id, 1)
    }
}
