import XCTest
@testable import Tabbed
import ApplicationServices

final class SuperpinUnpinTests: XCTestCase {
    private final class StubTabBarPanel: TabBarPanel {
        override func orderAbove(windowID: CGWindowID) {}
        override func close() {}
    }

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

    private func configureSuperpinCounters(source: TabGroup, target: TabGroup) {
        let counters = [source.id, target.id]
        source.maximizedGroupCounterIDs = counters
        target.maximizedGroupCounterIDs = counters
    }

    private func makeAppDelegateWithSuperpinEnabled() -> AppDelegate {
        let app = AppDelegate()
        app.tabBarConfig = TabBarConfig(
            style: .compact,
            showDragHandle: true,
            showTooltip: true,
            closeButtonMode: .xmarkOnAllTabs,
            showCloseConfirmation: true,
            showMaximizedGroupCounters: true
        )
        return app
    }

    func testUnpinningSuperPinnedSourceTabRemovesMirrorsAndKeepsTabLocal() {
        let app = makeAppDelegateWithSuperpinEnabled()
        let superpinCandidate = makeWindow(id: 101)
        let sourceCompanion = makeWindow(id: 102)
        let targetWindow = makeWindow(id: 201)

        guard let source = app.groupManager.createGroup(with: [superpinCandidate, sourceCompanion], frame: .zero),
              let target = app.groupManager.createGroup(with: [targetWindow], frame: .zero) else {
            XCTFail("Expected group creation")
            return
        }
        configureSuperpinCounters(source: source, target: target)

        app.setSuperPinned(true, forWindowIDs: [superpinCandidate.id], in: source)
        XCTAssertTrue(target.contains(windowID: superpinCandidate.id))
        XCTAssertTrue(app.superpinMirroredWindowIDsByGroupID[target.id]?.contains(superpinCandidate.id) ?? false)

        app.setPinned(false, forWindowIDs: [superpinCandidate.id], in: source)

        XCTAssertTrue(source.contains(windowID: superpinCandidate.id))
        XCTAssertEqual(
            source.windows.first(where: { $0.id == superpinCandidate.id })?.pinState,
            WindowPinState.none
        )
        XCTAssertFalse(target.contains(windowID: superpinCandidate.id))
        XCTAssertEqual(app.groupManager.membershipCount(for: superpinCandidate.id), 1)
        XCTAssertFalse(app.superpinMirroredWindowIDsByGroupID.values.contains(where: { $0.contains(superpinCandidate.id) }))
    }

    func testUnpinningMirroredSuperPinnedTabMovesTabIntoCurrentGroup() {
        let app = makeAppDelegateWithSuperpinEnabled()
        let superpinCandidate = makeWindow(id: 301)
        let sourceCompanion = makeWindow(id: 302)
        let targetWindow = makeWindow(id: 401)

        guard let source = app.groupManager.createGroup(with: [superpinCandidate, sourceCompanion], frame: .zero),
              let target = app.groupManager.createGroup(with: [targetWindow], frame: .zero) else {
            XCTFail("Expected group creation")
            return
        }
        configureSuperpinCounters(source: source, target: target)

        app.setSuperPinned(true, forWindowIDs: [superpinCandidate.id], in: source)
        XCTAssertTrue(target.contains(windowID: superpinCandidate.id))
        XCTAssertEqual(target.windows.first(where: { $0.id == superpinCandidate.id })?.pinState, .super)
        XCTAssertTrue(app.superpinMirroredWindowIDsByGroupID[target.id]?.contains(superpinCandidate.id) ?? false)

        app.setPinned(false, forWindowIDs: [superpinCandidate.id], in: target)

        XCTAssertTrue(target.contains(windowID: superpinCandidate.id))
        XCTAssertEqual(
            target.windows.first(where: { $0.id == superpinCandidate.id })?.pinState,
            WindowPinState.none
        )
        XCTAssertFalse(source.contains(windowID: superpinCandidate.id))
        XCTAssertEqual(app.groupManager.membershipCount(for: superpinCandidate.id), 1)
        XCTAssertEqual(app.groupManager.group(for: superpinCandidate.id)?.id, target.id)
        XCTAssertFalse(app.superpinMirroredWindowIDsByGroupID.values.contains(where: { $0.contains(superpinCandidate.id) }))
    }

    func testUnpinningMirroredSuperpinDissolvesGroupThatBecomesMirrorsOnly() {
        let app = makeAppDelegateWithSuperpinEnabled()
        let sourceWindow = makeWindow(id: 501)
        let targetWindow = makeWindow(id: 502)
        let thirdWindow = makeWindow(id: 503)

        guard let source = app.groupManager.createGroup(with: [sourceWindow], frame: .zero),
              let target = app.groupManager.createGroup(with: [targetWindow], frame: .zero),
              let third = app.groupManager.createGroup(with: [thirdWindow], frame: .zero) else {
            XCTFail("Expected group creation")
            return
        }

        let counters = [source.id, target.id, third.id]
        source.maximizedGroupCounterIDs = counters
        target.maximizedGroupCounterIDs = counters
        third.maximizedGroupCounterIDs = counters

        app.setSuperPinned(true, forWindowIDs: [sourceWindow.id], in: source)
        app.setSuperPinned(true, forWindowIDs: [thirdWindow.id], in: third)

        XCTAssertTrue(source.contains(windowID: sourceWindow.id))
        XCTAssertTrue(source.contains(windowID: thirdWindow.id))
        XCTAssertTrue(app.superpinMirroredWindowIDsByGroupID[source.id]?.contains(thirdWindow.id) ?? false)

        app.setPinned(false, forWindowIDs: [sourceWindow.id], in: target)

        XCTAssertFalse(app.groupManager.groups.contains(where: { $0.id == source.id }))
        XCTAssertTrue(third.contains(windowID: thirdWindow.id))
        XCTAssertTrue(target.contains(windowID: sourceWindow.id))
        XCTAssertEqual(app.groupManager.group(for: sourceWindow.id)?.id, target.id)
    }

    func testReleaseTabDissolvesGroupThatBecomesMirrorsOnly() {
        let app = makeAppDelegateWithSuperpinEnabled()
        let sourceWindow = makeWindow(id: 601)
        let targetWindow = makeWindow(id: 602)
        let thirdWindow = makeWindow(id: 603)

        guard let source = app.groupManager.createGroup(with: [sourceWindow], frame: .zero),
              let target = app.groupManager.createGroup(with: [targetWindow], frame: .zero),
              let third = app.groupManager.createGroup(with: [thirdWindow], frame: .zero) else {
            XCTFail("Expected group creation")
            return
        }

        let counters = [source.id, target.id, third.id]
        source.maximizedGroupCounterIDs = counters
        target.maximizedGroupCounterIDs = counters
        third.maximizedGroupCounterIDs = counters

        app.setSuperPinned(true, forWindowIDs: [thirdWindow.id], in: third)
        XCTAssertTrue(source.contains(windowID: thirdWindow.id))

        app.releaseTabs(withIDs: [sourceWindow.id], from: source, panel: StubTabBarPanel())

        XCTAssertFalse(app.groupManager.groups.contains(where: { $0.id == source.id }))
        XCTAssertTrue(third.contains(windowID: thirdWindow.id))
    }

    func testReleaseTabOnMirroredWindowDemotesRemainingSingleMembershipToRegularTab() {
        let app = makeAppDelegateWithSuperpinEnabled()
        let sourceWindow = makeWindow(id: 611)
        let targetWindow = makeWindow(id: 612)

        guard let source = app.groupManager.createGroup(with: [sourceWindow], frame: .zero),
              let target = app.groupManager.createGroup(with: [targetWindow], frame: .zero) else {
            XCTFail("Expected group creation")
            return
        }
        configureSuperpinCounters(source: source, target: target)

        app.setSuperPinned(true, forWindowIDs: [sourceWindow.id], in: source)
        XCTAssertTrue(target.contains(windowID: sourceWindow.id))
        XCTAssertEqual(source.windows.first(where: { $0.id == sourceWindow.id })?.pinState, .super)

        guard let mirroredIndex = target.windows.firstIndex(where: { $0.id == sourceWindow.id }) else {
            XCTFail("Expected mirrored window in target group")
            return
        }
        app.releaseTab(at: mirroredIndex, from: target, panel: StubTabBarPanel())

        XCTAssertFalse(target.contains(windowID: sourceWindow.id))
        XCTAssertTrue(source.contains(windowID: sourceWindow.id))
        XCTAssertEqual(app.groupManager.membershipCount(for: sourceWindow.id), 1)
        XCTAssertEqual(source.windows.first(where: { $0.id == sourceWindow.id })?.pinState, WindowPinState.none)
        XCTAssertFalse(app.superpinMirroredWindowIDsByGroupID.values.contains(where: { $0.contains(sourceWindow.id) }))
    }

    func testReleaseTabsOnMirroredWindowDemotesRemainingSingleMembershipToRegularTab() {
        let app = makeAppDelegateWithSuperpinEnabled()
        let sourceWindow = makeWindow(id: 621)
        let targetWindow = makeWindow(id: 622)

        guard let source = app.groupManager.createGroup(with: [sourceWindow], frame: .zero),
              let target = app.groupManager.createGroup(with: [targetWindow], frame: .zero) else {
            XCTFail("Expected group creation")
            return
        }
        configureSuperpinCounters(source: source, target: target)

        app.setSuperPinned(true, forWindowIDs: [sourceWindow.id], in: source)
        XCTAssertTrue(target.contains(windowID: sourceWindow.id))
        XCTAssertEqual(source.windows.first(where: { $0.id == sourceWindow.id })?.pinState, .super)

        app.releaseTabs(withIDs: [sourceWindow.id], from: target, panel: StubTabBarPanel())

        XCTAssertFalse(target.contains(windowID: sourceWindow.id))
        XCTAssertTrue(source.contains(windowID: sourceWindow.id))
        XCTAssertEqual(app.groupManager.membershipCount(for: sourceWindow.id), 1)
        XCTAssertEqual(source.windows.first(where: { $0.id == sourceWindow.id })?.pinState, WindowPinState.none)
        XCTAssertFalse(app.superpinMirroredWindowIDsByGroupID.values.contains(where: { $0.contains(sourceWindow.id) }))
    }

    func testCloseTabDissolvesGroupThatBecomesMirrorsOnly() {
        let app = makeAppDelegateWithSuperpinEnabled()
        let sourceWindow = makeWindow(id: 701)
        let targetWindow = makeWindow(id: 702)
        let thirdWindow = makeWindow(id: 703)

        guard let source = app.groupManager.createGroup(with: [sourceWindow], frame: .zero),
              let target = app.groupManager.createGroup(with: [targetWindow], frame: .zero),
              let third = app.groupManager.createGroup(with: [thirdWindow], frame: .zero) else {
            XCTFail("Expected group creation")
            return
        }

        let counters = [source.id, target.id, third.id]
        source.maximizedGroupCounterIDs = counters
        target.maximizedGroupCounterIDs = counters
        third.maximizedGroupCounterIDs = counters

        app.setSuperPinned(true, forWindowIDs: [thirdWindow.id], in: third)
        XCTAssertTrue(source.contains(windowID: thirdWindow.id))

        let sourcePanel = StubTabBarPanel()
        app.tabBarPanels[source.id] = sourcePanel
        app.closeTabs(withIDs: [sourceWindow.id], from: source, panel: sourcePanel)

        XCTAssertFalse(app.groupManager.groups.contains(where: { $0.id == source.id }))
        XCTAssertTrue(third.contains(windowID: thirdWindow.id))
    }
}
