import XCTest
@testable import Tabbed
import ApplicationServices

final class GroupedBarDragTests: XCTestCase {
    private func makeWindow(id: CGWindowID) -> WindowInfo {
        WindowInfo(
            id: id,
            element: AXUIElementCreateApplication(1),
            ownerPID: 1,
            bundleID: "com.example.test",
            title: "Window \(id)",
            appName: "Test"
        )
    }

    private func makeFrame(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 600, height: 400)
    }

    private func setCounterIDs(_ ids: [UUID], groups: [TabGroup]) {
        for group in groups {
            group.maximizedGroupCounterIDs = ids
        }
    }

    func testHandleBarDragWithoutShiftMovesCounterPeerGroups() {
        let app = AppDelegate()
        guard let source = app.groupManager.createGroup(with: [makeWindow(id: 101)], frame: makeFrame(x: 100, y: 200)),
              let peer = app.groupManager.createGroup(with: [makeWindow(id: 102)], frame: makeFrame(x: 300, y: 400)) else {
            XCTFail("Expected groups to be created")
            return
        }

        let counters = [source.id, peer.id]
        setCounterIDs(counters, groups: [source, peer])

        app.handleBarDrag(group: source, totalDx: 24, totalDy: 10, isShiftPressed: false)

        XCTAssertEqual(source.frame.origin.x, 124, accuracy: 0.001)
        XCTAssertEqual(source.frame.origin.y, 190, accuracy: 0.001)
        XCTAssertEqual(peer.frame.origin.x, 324, accuracy: 0.001)
        XCTAssertEqual(peer.frame.origin.y, 390, accuracy: 0.001)
    }

    func testHandleBarDragWithShiftMovesOnlySourceGroup() {
        let app = AppDelegate()
        guard let source = app.groupManager.createGroup(with: [makeWindow(id: 201)], frame: makeFrame(x: 100, y: 200)),
              let peer = app.groupManager.createGroup(with: [makeWindow(id: 202)], frame: makeFrame(x: 320, y: 420)),
              let third = app.groupManager.createGroup(with: [makeWindow(id: 203)], frame: makeFrame(x: 460, y: 520)),
              let outside = app.groupManager.createGroup(with: [makeWindow(id: 204)], frame: makeFrame(x: 700, y: 800)) else {
            XCTFail("Expected groups to be created")
            return
        }

        let counters = [source.id, peer.id, third.id]
        setCounterIDs(counters, groups: [source, peer, third, outside])

        app.handleBarDrag(group: source, totalDx: 30, totalDy: 12, isShiftPressed: true)

        XCTAssertEqual(source.frame.origin.x, 130, accuracy: 0.001)
        XCTAssertEqual(source.frame.origin.y, 188, accuracy: 0.001)
        XCTAssertEqual(peer.frame.origin.x, 320, accuracy: 0.001)
        XCTAssertEqual(peer.frame.origin.y, 420, accuracy: 0.001)
        XCTAssertEqual(third.frame.origin.x, 460, accuracy: 0.001)
        XCTAssertEqual(third.frame.origin.y, 520, accuracy: 0.001)
        XCTAssertEqual(outside.frame.origin.x, 700, accuracy: 0.001)
        XCTAssertEqual(outside.frame.origin.y, 800, accuracy: 0.001)
    }

    func testHandleBarDragShiftReleaseMidDragStartsPeerMovementFromTogglePoint() {
        let app = AppDelegate()
        guard let source = app.groupManager.createGroup(with: [makeWindow(id: 301)], frame: makeFrame(x: 100, y: 200)),
              let peer = app.groupManager.createGroup(with: [makeWindow(id: 302)], frame: makeFrame(x: 320, y: 420)) else {
            XCTFail("Expected groups to be created")
            return
        }

        let counters = [source.id, peer.id]
        setCounterIDs(counters, groups: [source, peer])

        // Initial drag with Shift moves only source.
        app.handleBarDrag(group: source, totalDx: 20, totalDy: 0, isShiftPressed: true)
        XCTAssertEqual(source.frame.origin.x, 120, accuracy: 0.001)
        XCTAssertEqual(peer.frame.origin.x, 320, accuracy: 0.001)

        // Reapply counters because drag refresh can recompute group counter memberships.
        setCounterIDs(counters, groups: [source, peer])

        // Releasing Shift engages grouped drag: peers should not jump to catch up immediately.
        app.handleBarDrag(group: source, totalDx: 40, totalDy: 0, isShiftPressed: false)
        XCTAssertEqual(source.frame.origin.x, 140, accuracy: 0.001)
        XCTAssertEqual(peer.frame.origin.x, 320, accuracy: 0.001)

        // Additional movement with Shift released moves peers by post-toggle delta only.
        setCounterIDs(counters, groups: [source, peer])
        app.handleBarDrag(group: source, totalDx: 60, totalDy: 0, isShiftPressed: false)

        XCTAssertEqual(source.frame.origin.x, 160, accuracy: 0.001)
        XCTAssertEqual(peer.frame.origin.x, 340, accuracy: 0.001)
    }

    func testShouldToggleZoomAcrossCounterGroupsRequiresSourceInMultiGroupSet() {
        let source = UUID()
        let peer = UUID()

        XCTAssertTrue(
            AppDelegate.shouldToggleZoomAcrossCounterGroups(
                sourceGroupID: source,
                counterGroupIDs: [source, peer]
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldToggleZoomAcrossCounterGroups(
                sourceGroupID: source,
                counterGroupIDs: [source]
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldToggleZoomAcrossCounterGroups(
                sourceGroupID: source,
                counterGroupIDs: [peer]
            )
        )
    }

    func testGroupedZoomActionRestoresOnlyWhenAllGroupsCanRestore() {
        XCTAssertEqual(
            AppDelegate.groupedZoomAction(
                allGroupsMaximized: true,
                allGroupsHavePreZoom: true
            ),
            .restore
        )
        XCTAssertEqual(
            AppDelegate.groupedZoomAction(
                allGroupsMaximized: true,
                allGroupsHavePreZoom: false
            ),
            .maximize
        )
        XCTAssertEqual(
            AppDelegate.groupedZoomAction(
                allGroupsMaximized: false,
                allGroupsHavePreZoom: true
            ),
            .maximize
        )
    }

    func testToggleZoomAppliesToCounterPeerGroups() {
        let app = AppDelegate()
        guard let source = app.groupManager.createGroup(with: [makeWindow(id: 401)], frame: makeFrame(x: 100, y: 200)),
              let peer = app.groupManager.createGroup(with: [makeWindow(id: 402)], frame: makeFrame(x: 420, y: 220)) else {
            XCTFail("Expected groups to be created")
            return
        }

        let counters = [source.id, peer.id]
        setCounterIDs(counters, groups: [source, peer])
        let sourcePanel = TabBarPanel()
        let peerPanel = TabBarPanel()
        app.tabBarPanels[source.id] = sourcePanel
        app.tabBarPanels[peer.id] = peerPanel

        XCTAssertNil(source.preZoomFrame)
        XCTAssertNil(peer.preZoomFrame)

        app.toggleZoom(group: source, panel: sourcePanel)

        XCTAssertNotNil(source.preZoomFrame)
        XCTAssertNotNil(peer.preZoomFrame)
    }
}
