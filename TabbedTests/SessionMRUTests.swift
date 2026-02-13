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

    func testSaveSessionPersistsGroupName() {
        let group = makeGroup(app: "Alpha", windowID: 1)
        group.name = "Team Alpha"

        SessionManager.saveSession(groups: [group], mruGroupOrder: [])

        let loaded = SessionManager.loadSession()!
        XCTAssertEqual(loaded.first?.name, "Team Alpha")
    }

    func testSaveSessionPersistsPinnedWindowState() {
        var pinnedWindow = makeWindow(id: 1, app: "Alpha")
        pinnedWindow.isPinned = true
        let group = TabGroup(windows: [pinnedWindow, makeWindow(id: 2, app: "Alpha")], frame: .zero)

        SessionManager.saveSession(groups: [group], mruGroupOrder: [])

        let loaded = SessionManager.loadSession()!
        XCTAssertEqual(loaded.first?.windows.first?.isPinned, true)
        XCTAssertEqual(loaded.first?.windows.last?.isPinned, false)
    }

    func testSaveSessionPersistsCustomTabName() {
        var renamedWindow = makeWindow(id: 1, app: "Alpha")
        renamedWindow.customTabName = "Daily Focus"
        let group = TabGroup(windows: [renamedWindow], frame: .zero)

        SessionManager.saveSession(groups: [group], mruGroupOrder: [])

        let loaded = SessionManager.loadSession()!
        XCTAssertEqual(loaded.first?.windows.first?.customTabName, "Daily Focus")
    }

    func testSaveSessionPersistsSeparatorsInOrder() {
        let separator = WindowInfo.separator(withID: 4_000_000_123)
        let group = TabGroup(
            windows: [makeWindow(id: 1, app: "Alpha"), separator, makeWindow(id: 2, app: "Alpha")],
            frame: .zero
        )

        SessionManager.saveSession(groups: [group], mruGroupOrder: [])

        let loaded = SessionManager.loadSession()!
        XCTAssertEqual(loaded.first?.windows.count, 3)
        XCTAssertEqual(loaded.first?.windows[1].isSeparator, true)
        XCTAssertEqual(loaded.first?.windows[1].windowID, separator.id)
    }

    func testMatchGroupRestoresSeparatorsAlongsideMatchedWindows() {
        let live = [
            makeWindow(id: 10, app: "Alpha"),
            makeWindow(id: 11, app: "Alpha")
        ]
        let separatorID: CGWindowID = 4_000_000_222
        let snapshot = GroupSnapshot(
            windows: [
                WindowSnapshot(windowID: 10, bundleID: "com.Alpha", title: "Alpha Window", appName: "Alpha", isPinned: false),
                WindowSnapshot(
                    windowID: separatorID,
                    bundleID: "dev.tabbed.separator",
                    title: "Separator",
                    appName: "Separator",
                    isPinned: false,
                    isSeparator: true
                ),
                WindowSnapshot(windowID: 11, bundleID: "com.Alpha", title: "Alpha Window", appName: "Alpha", isPinned: false)
            ],
            activeIndex: 0,
            frame: CodableRect(.zero),
            tabBarSqueezeDelta: 0,
            name: nil
        )

        let matched = SessionManager.matchGroup(
            snapshot: snapshot,
            liveWindows: live,
            alreadyClaimed: [],
            mode: .always
        )

        XCTAssertEqual(matched?.count, 3)
        XCTAssertEqual(matched?[1].isSeparator, true)
        XCTAssertEqual(matched?[1].id, separatorID)
    }

    func testMatchGroupAppliesPinnedStateFromSnapshot() {
        let live = [
            makeWindow(id: 10, app: "Alpha"),
            makeWindow(id: 11, app: "Alpha")
        ]
        let snapshot = GroupSnapshot(
            windows: [
                WindowSnapshot(windowID: 10, bundleID: "com.Alpha", title: "Alpha Window", appName: "Alpha", isPinned: true),
                WindowSnapshot(windowID: 11, bundleID: "com.Alpha", title: "Alpha Window", appName: "Alpha", isPinned: false)
            ],
            activeIndex: 0,
            frame: CodableRect(.zero),
            tabBarSqueezeDelta: 0,
            name: nil
        )

        let matched = SessionManager.matchGroup(
            snapshot: snapshot,
            liveWindows: live,
            alreadyClaimed: [],
            mode: .always
        )

        XCTAssertEqual(matched?.count, 2)
        XCTAssertEqual(matched?.first?.isPinned, true)
        XCTAssertEqual(matched?.last?.isPinned, false)
    }

    func testMatchGroupAppliesCustomTabNameFromSnapshot() {
        let live = [
            makeWindow(id: 10, app: "Alpha")
        ]
        let snapshot = GroupSnapshot(
            windows: [
                WindowSnapshot(
                    windowID: 10,
                    bundleID: "com.Alpha",
                    title: "Alpha Window",
                    appName: "Alpha",
                    isPinned: false,
                    customTabName: "Focus"
                )
            ],
            activeIndex: 0,
            frame: CodableRect(.zero),
            tabBarSqueezeDelta: 0,
            name: nil
        )

        let matched = SessionManager.matchGroup(
            snapshot: snapshot,
            liveWindows: live,
            alreadyClaimed: [],
            mode: .always
        )

        XCTAssertEqual(matched?.first?.customTabName, "Focus")
    }
}
