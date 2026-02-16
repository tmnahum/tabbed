import XCTest
@testable import Tabbed
import ApplicationServices

final class SuperpinUnpinTests: XCTestCase {
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
}
