import XCTest
@testable import Tabbed

/// Tests that session snapshots are reordered by MRU when saved,
/// so the global switcher has a meaningful order on next launch.
final class SessionMRUTests: XCTestCase {

    private let testSuiteKey = "savedSession"

    private func makeWindow(id: CGWindowID, app: String = "App") -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(
            id: id, element: element, ownerPID: 0,
            bundleID: "com.\(app)", title: "\(app) Window",
            appName: app, icon: nil
        )
    }

    private func makeGroup(app: String, windowID: CGWindowID) -> TabGroup {
        TabGroup(windows: [makeWindow(id: windowID, app: app)], frame: .zero)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testSuiteKey)
        super.tearDown()
    }

    // MARK: - Snapshot Reordering

    func testSaveSessionReordersSnapshotsByMRU() {
        let groupA = makeGroup(app: "Alpha", windowID: 1)
        let groupB = makeGroup(app: "Beta", windowID: 2)
        let groupC = makeGroup(app: "Charlie", windowID: 3)
        let groups = [groupA, groupB, groupC]

        // MRU order: C, A, B (different from array order)
        let mruOrder = [groupC.id, groupA.id, groupB.id]
        SessionManager.saveSession(groups: groups, mruGroupOrder: mruOrder)

        let loaded = SessionManager.loadSession()!
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[0].windows[0].appName, "Charlie")
        XCTAssertEqual(loaded[1].windows[0].appName, "Alpha")
        XCTAssertEqual(loaded[2].windows[0].appName, "Beta")
    }

    func testSaveSessionWithEmptyMRUPreservesOriginalOrder() {
        let groupA = makeGroup(app: "Alpha", windowID: 1)
        let groupB = makeGroup(app: "Beta", windowID: 2)
        let groupC = makeGroup(app: "Charlie", windowID: 3)

        SessionManager.saveSession(groups: [groupA, groupB, groupC], mruGroupOrder: [])

        let loaded = SessionManager.loadSession()!
        XCTAssertEqual(loaded[0].windows[0].appName, "Alpha")
        XCTAssertEqual(loaded[1].windows[0].appName, "Beta")
        XCTAssertEqual(loaded[2].windows[0].appName, "Charlie")
    }

    func testSaveSessionWithPartialMRUPutsMRUGroupsFirst() {
        let groupA = makeGroup(app: "Alpha", windowID: 1)
        let groupB = makeGroup(app: "Beta", windowID: 2)
        let groupC = makeGroup(app: "Charlie", windowID: 3)

        // Only Beta is in MRU — it should come first, others stay in original order
        SessionManager.saveSession(groups: [groupA, groupB, groupC], mruGroupOrder: [groupB.id])

        let loaded = SessionManager.loadSession()!
        XCTAssertEqual(loaded[0].windows[0].appName, "Beta")
        XCTAssertEqual(loaded[1].windows[0].appName, "Alpha")
        XCTAssertEqual(loaded[2].windows[0].appName, "Charlie")
    }

    func testSaveSessionMRUWithNonexistentGroupIDsAreIgnored() {
        let groupA = makeGroup(app: "Alpha", windowID: 1)
        let groupB = makeGroup(app: "Beta", windowID: 2)

        // Bogus UUID in MRU — should be ignored, original order preserved
        SessionManager.saveSession(groups: [groupA, groupB], mruGroupOrder: [UUID()])

        let loaded = SessionManager.loadSession()!
        XCTAssertEqual(loaded[0].windows[0].appName, "Alpha")
        XCTAssertEqual(loaded[1].windows[0].appName, "Beta")
    }
}
