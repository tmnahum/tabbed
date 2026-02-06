# Tabbed Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS menu bar utility that groups arbitrary windows into tab groups with a browser-style tab bar.

**Architecture:** Bottom-up — foundation layers first (AX wrapper, models), then core logic (WindowManager, GroupManager), then UI (TabBarPanel, tab strip, window picker, menu bar), then integration and edge cases. See `docs/plans/2026-02-05-tabbed-design.md` for full design.

**Tech Stack:** Swift, AppKit, SwiftUI (for UI content in AppKit containers), Accessibility API, XcodeGen (project generation)

---

### Task 1: Project Setup

**Files:**
- Create: `.gitignore`
- Create: `project.yml`
- Create: `Tabbed/Info.plist`
- Create: `Tabbed/Tabbed.entitlements`
- Create: `Tabbed/TabbedApp.swift`
- Create: `Tabbed/AppDelegate.swift`
- Create: `TabbedTests/TabbedTests.swift`

**Step 1: Create .gitignore**

```
*.xcodeproj
build/
DerivedData/
.DS_Store
*.xcuserdata
```

**Step 2: Install XcodeGen if needed**

Run: `brew list xcodegen || brew install xcodegen`
Expected: xcodegen is available

**Step 3: Create project.yml**

```yaml
name: Tabbed
options:
  bundleIdPrefix: com.tabbed
  deploymentTarget:
    macOS: "13.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.9"
    MACOSX_DEPLOYMENT_TARGET: "13.0"
targets:
  Tabbed:
    type: application
    platform: macOS
    sources: [Tabbed]
    settings:
      base:
        INFOPLIST_FILE: Tabbed/Info.plist
        CODE_SIGN_ENTITLEMENTS: Tabbed/Tabbed.entitlements
        CODE_SIGN_IDENTITY: "-"
        PRODUCT_BUNDLE_IDENTIFIER: com.tabbed.Tabbed
    entitlements:
      path: Tabbed/Tabbed.entitlements
  TabbedTests:
    type: bundle.unit-test
    platform: macOS
    sources: [TabbedTests]
    dependencies:
      - target: Tabbed
    settings:
      base:
        BUNDLE_LOADER: "$(TEST_HOST)"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Tabbed.app/Contents/MacOS/Tabbed"
```

**Step 4: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleName</key>
    <string>Tabbed</string>
    <key>CFBundleDisplayName</key>
    <string>Tabbed</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Tabbed needs Accessibility access to manage window positions and detect focus changes.</string>
</dict>
</plist>
```

**Step 5: Create entitlements (no sandbox)**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

**Step 6: Create TabbedApp.swift**

```swift
import SwiftUI

@main
struct TabbedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Tabbed", systemImage: "rectangle.stack") {
            Text("Tabbed is running")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
```

**Step 7: Create AppDelegate.swift**

```swift
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }
}
```

**Step 8: Create placeholder test file**

Create: `TabbedTests/TabbedTests.swift`

```swift
import XCTest
@testable import Tabbed

final class TabbedTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
```

**Step 9: Generate project and build**

Run: `cd /Users/tmn/ccode/tabbed/version-a && xcodegen generate`
Expected: `Tabbed.xcodeproj` is created

Run: `xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build`
Expected: BUILD SUCCEEDED

**Step 10: Run the app to verify menu bar icon appears**

Run: `open build/Build/Products/Debug/Tabbed.app`
Expected: Menu bar icon appears (rectangle.stack), clicking shows "Tabbed is running" and "Quit". Accessibility permission prompt appears. No Dock icon.

**Step 11: Commit**

```bash
git init
git add -A
git commit -m "feat: initial project setup with menu bar app shell"
```

---

### Task 2: Data Models

**Files:**
- Create: `Tabbed/Models/WindowInfo.swift`
- Create: `Tabbed/Models/TabGroup.swift`
- Create: `TabbedTests/TabGroupTests.swift`

**Step 1: Write WindowInfo model**

```swift
import AppKit
import ApplicationServices

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let element: AXUIElement
    let ownerPID: pid_t
    let bundleID: String
    var title: String
    var appName: String
    var icon: NSImage?

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}
```

**Step 2: Write TabGroup model**

```swift
import Foundation
import CoreGraphics

class TabGroup: Identifiable, ObservableObject {
    let id = UUID()
    @Published var windows: [WindowInfo]
    @Published var activeIndex: Int
    @Published var frame: CGRect

    var activeWindow: WindowInfo? {
        guard activeIndex >= 0, activeIndex < windows.count else { return nil }
        return windows[activeIndex]
    }

    init(windows: [WindowInfo], frame: CGRect) {
        self.windows = windows
        self.activeIndex = 0
        self.frame = frame
    }

    func contains(windowID: CGWindowID) -> Bool {
        windows.contains { $0.id == windowID }
    }

    func addWindow(_ window: WindowInfo) {
        guard !contains(windowID: window.id) else { return }
        windows.append(window)
    }

    func removeWindow(at index: Int) -> WindowInfo? {
        guard index >= 0, index < windows.count else { return nil }
        let removed = windows.remove(at: index)
        if activeIndex >= windows.count {
            activeIndex = max(0, windows.count - 1)
        }
        return removed
    }

    func removeWindow(withID windowID: CGWindowID) -> WindowInfo? {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return nil }
        return removeWindow(at: index)
    }

    func switchTo(index: Int) {
        guard index >= 0, index < windows.count else { return }
        activeIndex = index
    }

    func switchTo(windowID: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        activeIndex = index
    }

    func moveTab(from source: Int, to destination: Int) {
        guard source >= 0, source < windows.count,
              destination >= 0, destination <= windows.count else { return }

        let wasActive = source == activeIndex
        let window = windows.remove(at: source)

        let adjustedDestination = destination > source ? destination - 1 : destination
        windows.insert(window, at: adjustedDestination)

        if wasActive {
            activeIndex = adjustedDestination
        } else if source < activeIndex, adjustedDestination >= activeIndex {
            activeIndex -= 1
        } else if source > activeIndex, adjustedDestination <= activeIndex {
            activeIndex += 1
        }
    }
}
```

**Step 3: Write TabGroup unit tests**

```swift
import XCTest
@testable import Tabbed
import ApplicationServices

final class TabGroupTests: XCTestCase {
    func makeWindow(id: CGWindowID) -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(
            id: id,
            element: element,
            ownerPID: 0,
            bundleID: "com.test",
            title: "Window \(id)",
            appName: "Test",
            icon: nil
        )
    }

    func testInitSetsActiveIndexToZero() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        XCTAssertEqual(group.activeIndex, 0)
    }

    func testActiveWindow() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let group = TabGroup(windows: [w1, w2], frame: .zero)
        XCTAssertEqual(group.activeWindow?.id, 1)
        group.switchTo(index: 1)
        XCTAssertEqual(group.activeWindow?.id, 2)
    }

    func testContains() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero)
        XCTAssertTrue(group.contains(windowID: 1))
        XCTAssertFalse(group.contains(windowID: 99))
    }

    func testAddWindow() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero)
        group.addWindow(makeWindow(id: 2))
        XCTAssertEqual(group.windows.count, 2)
    }

    func testAddDuplicateWindowIsIgnored() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero)
        group.addWindow(makeWindow(id: 1))
        XCTAssertEqual(group.windows.count, 1)
    }

    func testRemoveWindow() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        let removed = group.removeWindow(withID: 1)
        XCTAssertEqual(removed?.id, 1)
        XCTAssertEqual(group.windows.count, 1)
    }

    func testRemoveActiveWindowAdjustsIndex() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        group.switchTo(index: 1)
        group.removeWindow(at: 1)
        XCTAssertEqual(group.activeIndex, 0)
    }

    func testSwitchToIndex() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        group.switchTo(index: 1)
        XCTAssertEqual(group.activeIndex, 1)
    }

    func testSwitchToInvalidIndexDoesNothing() {
        let group = TabGroup(windows: [makeWindow(id: 1)], frame: .zero)
        group.switchTo(index: 5)
        XCTAssertEqual(group.activeIndex, 0)
    }

    func testSwitchToWindowID() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2)], frame: .zero)
        group.switchTo(windowID: 2)
        XCTAssertEqual(group.activeIndex, 1)
    }

    func testMoveTab() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.moveTab(from: 0, to: 2)
        XCTAssertEqual(group.windows.map(\.id), [2, 1, 3])
    }

    func testMoveTabUpdatesActiveIndex() {
        let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
        group.switchTo(index: 0)
        group.moveTab(from: 0, to: 2)
        XCTAssertEqual(group.activeIndex, 1)
        XCTAssertEqual(group.activeWindow?.id, 1)
    }
}
```

**Step 4: Run tests**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build test`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Tabbed/Models TabbedTests/TabGroupTests.swift
git commit -m "feat: add WindowInfo and TabGroup data models with tests"
```

---

### Task 3: Accessibility Helper

**Files:**
- Create: `Tabbed/Accessibility/AccessibilityHelper.swift`
- Create: `Tabbed/Accessibility/CoordinateConverter.swift`
- Create: `TabbedTests/CoordinateConverterTests.swift`

**Step 1: Create AccessibilityHelper**

This is a thin wrapper around the C-based Accessibility API. Not unit-testable (requires live windows). We verify it works manually in a later task.

```swift
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

enum AccessibilityHelper {

    static func checkPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Window Discovery

    static func getWindowList() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return windowList.filter { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            guard let _ = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return true
        }
    }

    static func appElement(for pid: pid_t) -> AXUIElement {
        return AXUIElementCreateApplication(pid)
    }

    static func windowElements(for pid: pid_t) -> [AXUIElement] {
        let app = appElement(for: pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        let result = _AXUIElementGetWindow(element, &windowID)
        guard result == .success else { return nil }
        return windowID
    }

    // MARK: - Read Attributes

    static func getPosition(of element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    static func getSize(of element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    static func getFrame(of element: AXUIElement) -> CGRect? {
        guard let position = getPosition(of: element),
              let size = getSize(of: element) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func getTitle(of element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard result == .success, let title = value as? String else { return nil }
        return title
    }

    // MARK: - Write Attributes

    static func setPosition(of element: AXUIElement, to point: CGPoint) {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    static func setSize(of element: AXUIElement, to size: CGSize) {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    static func setFrame(of element: AXUIElement, to frame: CGRect) {
        setPosition(of: element, to: frame.origin)
        setSize(of: element, to: frame.size)
    }

    // MARK: - Actions

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    // MARK: - Observer

    static func createObserver(
        for pid: pid_t,
        callback: @escaping AXObserverCallback
    ) -> AXObserver? {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, callback, &observer)
        guard result == .success, let obs = observer else { return nil }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode
        )
        return obs
    }

    static func addNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: String,
        context: UnsafeMutableRawPointer?
    ) {
        AXObserverAddNotification(observer, element, notification as CFString, context)
    }

    static func removeNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: String
    ) {
        AXObserverRemoveNotification(observer, element, notification as CFString)
    }
}
```

**Step 2: Create CoordinateConverter**

```swift
import AppKit

enum CoordinateConverter {
    /// Convert from AX/CG coordinates (top-left origin, Y down)
    /// to AppKit coordinates (bottom-left origin, Y up)
    static func axToAppKit(point: CGPoint, windowHeight: CGFloat) -> CGPoint {
        guard let screen = NSScreen.main else { return point }
        let screenHeight = screen.frame.height
        return CGPoint(
            x: point.x,
            y: screenHeight - point.y - windowHeight
        )
    }

    /// Convert from AppKit coordinates (bottom-left origin, Y up)
    /// to AX/CG coordinates (top-left origin, Y down)
    static func appKitToAX(point: CGPoint, windowHeight: CGFloat) -> CGPoint {
        guard let screen = NSScreen.main else { return point }
        let screenHeight = screen.frame.height
        return CGPoint(
            x: point.x,
            y: screenHeight - point.y - windowHeight
        )
    }

    /// Get the visible frame in AX coordinates (excludes menu bar and Dock)
    static func visibleFrameInAX() -> CGRect {
        guard let screen = NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        let screenHeight = screen.frame.height
        return CGRect(
            x: visible.origin.x,
            y: screenHeight - visible.origin.y - visible.height,
            width: visible.width,
            height: visible.height
        )
    }
}
```

**Step 3: Write CoordinateConverter tests**

```swift
import XCTest
@testable import Tabbed

final class CoordinateConverterTests: XCTestCase {
    func testAXToAppKitRoundTrip() {
        let original = CGPoint(x: 100, y: 200)
        let windowHeight: CGFloat = 400
        let appKit = CoordinateConverter.axToAppKit(point: original, windowHeight: windowHeight)
        let backToAX = CoordinateConverter.appKitToAX(point: appKit, windowHeight: windowHeight)
        XCTAssertEqual(original.x, backToAX.x, accuracy: 0.01)
        XCTAssertEqual(original.y, backToAX.y, accuracy: 0.01)
    }

    func testVisibleFrameInAXReturnsNonZero() {
        let frame = CoordinateConverter.visibleFrameInAX()
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }
}
```

**Step 4: Run tests**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build test`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Tabbed/Accessibility TabbedTests/CoordinateConverterTests.swift
git commit -m "feat: add Accessibility API helper and coordinate converter"
```

---

### Task 4: WindowManager

**Files:**
- Create: `Tabbed/Managers/WindowManager.swift`

**Step 1: Create WindowManager**

WindowManager discovers windows and builds `WindowInfo` objects by correlating `CGWindowListCopyWindowInfo` data with `AXUIElement` references.

```swift
import AppKit
import ApplicationServices

class WindowManager: ObservableObject {
    @Published var availableWindows: [WindowInfo] = []

    private let ownBundleID = Bundle.main.bundleIdentifier ?? ""
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func refreshWindowList() {
        let cgWindows = AccessibilityHelper.getWindowList()
        var results: [WindowInfo] = []

        // Group CG windows by PID
        var pidToWindows: [pid_t: [[String: Any]]] = [:]
        for info in cgWindows {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            pidToWindows[pid, default: []].append(info)
        }

        for (pid, cgWindowsForPid) in pidToWindows {
            guard pid != ownPID else { continue }

            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = app?.bundleIdentifier ?? ""
            let appName = app?.localizedName ?? (cgWindowsForPid.first?[kCGWindowOwnerName as String] as? String ?? "Unknown")
            let icon = app?.icon

            let axWindows = AccessibilityHelper.windowElements(for: pid)

            // Match AX windows to CG windows by window ID
            for axWindow in axWindows {
                guard let windowID = AccessibilityHelper.windowID(for: axWindow) else { continue }

                // Verify this window is in our CG list (on-screen, layer 0)
                guard cgWindowsForPid.contains(where: {
                    ($0[kCGWindowNumber as String] as? CGWindowID) == windowID
                }) else { continue }

                let title = AccessibilityHelper.getTitle(of: axWindow) ?? ""

                // Skip windows with no title and tiny size (likely not real windows)
                if let size = AccessibilityHelper.getSize(of: axWindow),
                   size.width < 50 || size.height < 50, title.isEmpty {
                    continue
                }

                results.append(WindowInfo(
                    id: windowID,
                    element: axWindow,
                    ownerPID: pid,
                    bundleID: bundleID,
                    title: title,
                    appName: appName,
                    icon: icon
                ))
            }
        }

        availableWindows = results
    }
}
```

**Step 2: Verify manually**

Add a temporary print statement in `AppDelegate.applicationDidFinishLaunching` to test window discovery:

```swift
let wm = WindowManager()
wm.refreshWindowList()
for w in wm.availableWindows {
    print("[\(w.appName)] \(w.title) (id: \(w.id))")
}
```

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build && open build/Build/Products/Debug/Tabbed.app`

Expected: Console output lists open windows with app names and titles. Remove the temporary print after verifying.

**Step 3: Commit**

```bash
git add Tabbed/Managers/WindowManager.swift
git commit -m "feat: add WindowManager with window discovery"
```

---

### Task 5: GroupManager

**Files:**
- Create: `Tabbed/Managers/GroupManager.swift`
- Create: `TabbedTests/GroupManagerTests.swift`

**Step 1: Write GroupManager tests**

```swift
import XCTest
@testable import Tabbed
import ApplicationServices

final class GroupManagerTests: XCTestCase {
    var gm: GroupManager!

    func makeWindow(id: CGWindowID) -> WindowInfo {
        let element = AXUIElementCreateSystemWide()
        return WindowInfo(
            id: id, element: element, ownerPID: 0,
            bundleID: "com.test", title: "Window \(id)",
            appName: "Test", icon: nil
        )
    }

    override func setUp() {
        gm = GroupManager()
    }

    func testCreateGroup() {
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        let group = gm.createGroup(with: windows, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNotNil(group)
        XCTAssertEqual(gm.groups.count, 1)
        XCTAssertEqual(group?.windows.count, 2)
    }

    func testCreateGroupRequiresAtLeastTwoWindows() {
        let group = gm.createGroup(with: [makeWindow(id: 1)], frame: .zero)
        XCTAssertNil(group)
        XCTAssertEqual(gm.groups.count, 0)
    }

    func testCannotAddWindowAlreadyInGroup() {
        let w1 = makeWindow(id: 1)
        let w2 = makeWindow(id: 2)
        let w3 = makeWindow(id: 3)
        let group = gm.createGroup(with: [w1, w2], frame: .zero)!
        gm.addWindow(w1, to: group)
        XCTAssertEqual(group.windows.count, 2)

        // Can't create a new group containing w1 either
        let group2 = gm.createGroup(with: [w1, w3], frame: .zero)
        XCTAssertNil(group2)
    }

    func testFindGroupForWindow() {
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        gm.createGroup(with: windows, frame: .zero)
        XCTAssertNotNil(gm.group(for: 1))
        XCTAssertNil(gm.group(for: 99))
    }

    func testRemoveWindowDissolvesGroupWhenOneLeft() {
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        let group = gm.createGroup(with: windows, frame: .zero)!
        gm.releaseWindow(withID: 1, from: group)
        XCTAssertEqual(gm.groups.count, 0)
    }

    func testRemoveWindowKeepsGroupWithMultiple() {
        let windows = [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)]
        let group = gm.createGroup(with: windows, frame: .zero)!
        gm.releaseWindow(withID: 1, from: group)
        XCTAssertEqual(gm.groups.count, 1)
        XCTAssertEqual(group.windows.count, 2)
    }

    func testIsWindowGrouped() {
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        gm.createGroup(with: windows, frame: .zero)
        XCTAssertTrue(gm.isWindowGrouped(1))
        XCTAssertFalse(gm.isWindowGrouped(99))
    }

    func testDissolveGroup() {
        let windows = [makeWindow(id: 1), makeWindow(id: 2)]
        let group = gm.createGroup(with: windows, frame: .zero)!
        gm.dissolveGroup(group)
        XCTAssertEqual(gm.groups.count, 0)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build test`
Expected: FAIL — GroupManager not defined

**Step 3: Create GroupManager**

```swift
import Foundation
import CoreGraphics

class GroupManager: ObservableObject {
    @Published var groups: [TabGroup] = []

    /// Callback fired when a group is dissolved. Passes the released windows.
    var onGroupDissolved: (([WindowInfo]) -> Void)?

    /// Callback fired when a window is released from a group.
    var onWindowReleased: ((WindowInfo) -> Void)?

    func isWindowGrouped(_ windowID: CGWindowID) -> Bool {
        groups.contains { $0.contains(windowID: windowID) }
    }

    func group(for windowID: CGWindowID) -> TabGroup? {
        groups.first { $0.contains(windowID: windowID) }
    }

    @discardableResult
    func createGroup(with windows: [WindowInfo], frame: CGRect) -> TabGroup? {
        guard windows.count >= 2 else { return nil }

        // Prevent adding windows that are already grouped
        for window in windows {
            if isWindowGrouped(window.id) { return nil }
        }

        let group = TabGroup(windows: windows, frame: frame)
        groups.append(group)
        return group
    }

    func addWindow(_ window: WindowInfo, to group: TabGroup) {
        guard !isWindowGrouped(window.id) else { return }
        group.addWindow(window)
    }

    func releaseWindow(withID windowID: CGWindowID, from group: TabGroup) {
        guard let removed = group.removeWindow(withID: windowID) else { return }
        onWindowReleased?(removed)

        if group.windows.count <= 1 {
            dissolveGroup(group)
        }
    }

    func dissolveGroup(_ group: TabGroup) {
        onGroupDissolved?(group.windows)
        groups.removeAll { $0.id == group.id }
    }

    func dissolveAllGroups() {
        for group in groups {
            onGroupDissolved?(group.windows)
        }
        groups.removeAll()
    }
}
```

**Step 4: Run tests**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build test`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Tabbed/Managers/GroupManager.swift TabbedTests/GroupManagerTests.swift
git commit -m "feat: add GroupManager with group lifecycle and tests"
```

---

### Task 6: TabBarPanel (NSPanel Subclass)

**Files:**
- Create: `Tabbed/Views/TabBarPanel.swift`

**Step 1: Create TabBarPanel**

```swift
import AppKit

class TabBarPanel: NSPanel {
    static let tabBarHeight: CGFloat = 36

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: Self.tabBarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .normal
        self.isFloatingPanel = false
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = true
        self.animationBehavior = .none

        let visualEffect = NSVisualEffectView(frame: self.contentView!.bounds)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .menu  // Try .titlebar, .headerView, or .hudWindow if this doesn't look right
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        // Top corners only (minY = top in NSView's flipped layer coords)
        // If corners appear on the wrong side, swap to [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        visualEffect.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        visualEffect.layer?.cornerRadius = 8
        self.contentView?.addSubview(visualEffect, positioned: .below, relativeTo: nil)
    }

    /// Position the panel above the given window frame (in AX/CG coordinates)
    func positionAbove(windowFrame: CGRect) {
        let appKitOrigin = CoordinateConverter.axToAppKit(
            point: CGPoint(
                x: windowFrame.origin.x,
                y: windowFrame.origin.y - Self.tabBarHeight
            ),
            windowHeight: Self.tabBarHeight
        )
        self.setFrame(
            NSRect(
                x: appKitOrigin.x,
                y: appKitOrigin.y,
                width: windowFrame.width,
                height: Self.tabBarHeight
            ),
            display: true
        )
    }

    /// Order this panel directly above the specified window
    func orderAbove(windowID: CGWindowID) {
        self.order(.above, relativeTo: Int(windowID))
    }

    func show(above windowFrame: CGRect, windowID: CGWindowID) {
        positionAbove(windowFrame: windowFrame)
        orderFront(nil)
        orderAbove(windowID: windowID)
    }
}
```

**Step 2: Manual verification**

Temporarily add to `AppDelegate.applicationDidFinishLaunching`:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    let panel = TabBarPanel()
    panel.show(
        above: CGRect(x: 200, y: 200, width: 800, height: 600),
        windowID: 0
    )
    panel.orderFront(nil)
}
```

Run and verify: A translucent bar appears on screen. It should not steal focus from the current app. Remove temporary code after verifying.

**Step 3: Commit**

```bash
git add Tabbed/Views/TabBarPanel.swift
git commit -m "feat: add TabBarPanel NSPanel subclass"
```

---

### Task 7: Tab Bar SwiftUI View

**Files:**
- Create: `Tabbed/Views/TabBarView.swift`
- Modify: `Tabbed/Views/TabBarPanel.swift`

**Step 1: Create TabBarView**

```swift
import SwiftUI

struct TabBarView: View {
    @ObservedObject var group: TabGroup
    var onSwitchTab: (Int) -> Void
    var onReleaseTab: (Int) -> Void
    var onAddWindow: () -> Void

    @State private var hoveredIndex: Int? = nil

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                tabButton(for: window, at: index)
            }
            addButton
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tabButton(for window: WindowInfo, at index: Int) -> some View {
        let isActive = index == group.activeIndex
        let isHovered = hoveredIndex == index

        Button {
            onSwitchTab(index)
        } label: {
            HStack(spacing: 6) {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(window.title.isEmpty ? window.appName : window.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 12))

                Spacer(minLength: 0)

                if isHovered {
                    Button {
                        onReleaseTab(index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.white.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredIndex = hovering ? index : nil
        }
    }

    private var addButton: some View {
        Button {
            onAddWindow()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}
```

**Step 2: Update TabBarPanel to host SwiftUI view**

Add to `TabBarPanel.swift` — a method to set the SwiftUI content:

```swift
import SwiftUI

// Add this import at the top of TabBarPanel.swift, and store a reference to the visual effect view:
private let visualEffectView: NSVisualEffectView  // Add as a property

// In init(), store the reference:
// self.visualEffectView = visualEffect  (add this line after creating visualEffect)

// Add this method to TabBarPanel:
func setContent(group: TabGroup, onSwitchTab: @escaping (Int) -> Void, onReleaseTab: @escaping (Int) -> Void, onAddWindow: @escaping () -> Void) {
    let tabBarView = TabBarView(
        group: group,
        onSwitchTab: onSwitchTab,
        onReleaseTab: onReleaseTab,
        onAddWindow: onAddWindow
    )
    let hostingView = NSHostingView(rootView: tabBarView)
    hostingView.frame = visualEffectView.bounds
    hostingView.autoresizingMask = [.width, .height]

    // Add as subview OF the visual effect view so vibrancy shows through
    // and hosting view background is transparent
    visualEffectView.addSubview(hostingView)
}
```

**Step 3: Build and verify**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Tabbed/Views/TabBarView.swift Tabbed/Views/TabBarPanel.swift
git commit -m "feat: add SwiftUI tab bar view hosted in TabBarPanel"
```

---

### Task 8: Window Picker View

**Files:**
- Create: `Tabbed/Views/WindowPickerView.swift`

**Step 1: Create WindowPickerView**

```swift
import SwiftUI

struct WindowPickerView: View {
    @ObservedObject var windowManager: WindowManager
    let groupManager: GroupManager
    let onCreateGroup: ([WindowInfo]) -> Void
    let onAddToGroup: (WindowInfo) -> Void
    let onDismiss: () -> Void

    /// If non-nil, we're adding to an existing group (show single-select).
    /// If nil, we're creating a new group (show multi-select).
    let addingToGroup: TabGroup?

    @State private var selectedIDs: Set<CGWindowID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            windowList
            Divider()
            footer
        }
        .frame(width: 350, height: 400)
    }

    private var header: some View {
        HStack {
            Text(addingToGroup != nil ? "Add Window" : "New Group")
                .font(.headline)
            Spacer()
            Button("Cancel") { onDismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var windowList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(windowManager.availableWindows) { window in
                    let isGrouped = groupManager.isWindowGrouped(window.id)
                    windowRow(window: window, isGrouped: isGrouped)
                }
            }
            .padding(8)
        }
    }

    private func windowRow(window: WindowInfo, isGrouped: Bool) -> some View {
        let isSelected = selectedIDs.contains(window.id)

        return Button {
            guard !isGrouped else { return }
            if addingToGroup != nil {
                onAddToGroup(window)
            } else {
                if isSelected {
                    selectedIDs.remove(window.id)
                } else {
                    selectedIDs.insert(window.id)
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.appName)
                        .font(.system(size: 12, weight: .medium))
                    Text(window.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isGrouped {
                    Text("Grouped")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if addingToGroup == nil {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .blue : .secondary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isGrouped)
        .opacity(isGrouped ? 0.4 : 1)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if addingToGroup == nil {
                Button("Create Group") {
                    let selected = windowManager.availableWindows.filter { selectedIDs.contains($0.id) }
                    onCreateGroup(selected)
                }
                .disabled(selectedIDs.count < 2)
            }
        }
        .padding(12)
    }
}
```

**Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Tabbed/Views/WindowPickerView.swift
git commit -m "feat: add WindowPicker view for selecting windows to group"
```

---

### Task 9: Menu Bar Popover

**Files:**
- Modify: `Tabbed/TabbedApp.swift`
- Create: `Tabbed/Views/MenuBarView.swift`

**Step 1: Create MenuBarView**

```swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var groupManager: GroupManager

    var onNewGroup: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if groupManager.groups.isEmpty {
                Text("No groups")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(groupManager.groups) { group in
                    groupRow(group)
                }
            }

            Divider()

            Button {
                onNewGroup()
            } label: {
                Label("New Group", systemImage: "plus")
            }
            .padding(.horizontal, 8)

            Divider()

            Button {
                onQuit()
            } label: {
                Text("Quit Tabbed")
            }
            .padding(.horizontal, 8)
        }
        .padding(8)
        .frame(width: 220)
    }

    private func groupRow(_ group: TabGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(group.windows) { window in
                HStack(spacing: 4) {
                    if let icon = window.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 4)
    }
}
```

**Step 2: Update TabbedApp.swift**

```swift
import SwiftUI

@main
struct TabbedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Tabbed", systemImage: "rectangle.stack") {
            MenuBarView(
                groupManager: appDelegate.groupManager,
                onNewGroup: { appDelegate.showWindowPicker() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        }
    }
}
```

**Step 3: Update AppDelegate to hold shared state**

Replace `Tabbed/AppDelegate.swift`:

```swift
import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    let windowManager = WindowManager()
    let groupManager = GroupManager()

    private var windowPickerPanel: NSPanel?
    private var tabBarPanels: [UUID: TabBarPanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for (_, panel) in tabBarPanels {
            panel.close()
        }
        tabBarPanels.removeAll()
        groupManager.dissolveAllGroups()
    }

    func showWindowPicker(addingTo group: TabGroup? = nil) {
        windowManager.refreshWindowList()

        let picker = WindowPickerView(
            windowManager: windowManager,
            groupManager: groupManager,
            onCreateGroup: { [weak self] windows in
                self?.createGroup(with: windows)
                self?.dismissWindowPicker()
            },
            onAddToGroup: { [weak self] window in
                guard let group = group else { return }
                self?.addWindow(window, to: group)
                self?.dismissWindowPicker()
            },
            onDismiss: { [weak self] in
                self?.dismissWindowPicker()
            },
            addingToGroup: group
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: picker)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowPickerPanel = panel
    }

    private func dismissWindowPicker() {
        windowPickerPanel?.close()
        windowPickerPanel = nil
    }

    private func createGroup(with windows: [WindowInfo]) {
        guard let firstFrame = AccessibilityHelper.getFrame(of: windows[0].element) else { return }

        let tabBarHeight = TabBarPanel.tabBarHeight
        let windowFrame = CGRect(
            x: firstFrame.origin.x,
            y: firstFrame.origin.y + tabBarHeight,
            width: firstFrame.width,
            height: firstFrame.height - tabBarHeight
        )

        guard let group = groupManager.createGroup(with: windows, frame: windowFrame) else { return }

        // Sync all windows to same frame
        for window in group.windows {
            AccessibilityHelper.setFrame(of: window.element, to: windowFrame)
        }

        // Raise the first window
        AccessibilityHelper.raise(group.windows[0].element)

        // Create and show tab bar
        let panel = TabBarPanel()
        panel.setContent(
            group: group,
            onSwitchTab: { [weak self] index in
                self?.switchTab(in: group, to: index, panel: panel)
            },
            onReleaseTab: { [weak self] index in
                self?.releaseTab(at: index, from: group, panel: panel)
            },
            onAddWindow: { [weak self] in
                self?.showWindowPicker(addingTo: group)
            }
        )

        tabBarPanels[group.id] = panel

        if let activeWindow = group.activeWindow {
            panel.show(above: windowFrame, windowID: activeWindow.id)
        }
    }

    private func switchTab(in group: TabGroup, to index: Int, panel: TabBarPanel) {
        group.switchTo(index: index)
        guard let window = group.activeWindow else { return }
        AccessibilityHelper.raise(window.element)
        panel.orderAbove(windowID: window.id)
    }

    private func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
        let tabBarHeight = TabBarPanel.tabBarHeight

        if let window = group.windows[safe: index] {
            // Expand window upward into tab bar area
            if let frame = AccessibilityHelper.getFrame(of: window.element) {
                let expandedFrame = CGRect(
                    x: frame.origin.x,
                    y: frame.origin.y - tabBarHeight,
                    width: frame.width,
                    height: frame.height + tabBarHeight
                )
                AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
            }
        }

        groupManager.releaseWindow(withID: group.windows[index].id, from: group)

        // If group was dissolved, remove the panel
        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            panel.close()
            tabBarPanels.removeValue(forKey: group.id)
        }
    }

    private func addWindow(_ window: WindowInfo, to group: TabGroup) {
        AccessibilityHelper.setFrame(of: window.element, to: group.frame)
        groupManager.addWindow(window, to: group)
    }
}

// Safe array subscript
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

**Step 4: Build and test manually**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build && open build/Build/Products/Debug/Tabbed.app`

Expected: Click menu bar icon → shows popover with "No groups" and "New Group". Click "New Group" → window picker appears listing open windows. Select 2+ windows → "Create Group" button enables. Click it → windows snap together, tab bar appears above them. Click tabs to switch.

**Step 5: Commit**

```bash
git add Tabbed/Views/MenuBarView.swift Tabbed/TabbedApp.swift Tabbed/AppDelegate.swift
git commit -m "feat: wire up menu bar, window picker, and group creation flow"
```

---

### Task 10: AXObserver Integration

**Files:**
- Create: `Tabbed/Managers/WindowObserver.swift`
- Modify: `Tabbed/AppDelegate.swift`

**Step 1: Create WindowObserver**

This watches grouped windows for move, resize, focus, close, and title changes.

```swift
import ApplicationServices
import AppKit

class WindowObserver {
    private var observers: [pid_t: AXObserver] = [:]

    var onWindowMoved: ((CGWindowID) -> Void)?
    var onWindowResized: ((CGWindowID) -> Void)?
    var onWindowFocused: ((pid_t, AXUIElement) -> Void)?
    var onWindowDestroyed: ((CGWindowID) -> Void)?
    var onTitleChanged: ((CGWindowID) -> Void)?

    func observe(window: WindowInfo) {
        let pid = window.ownerPID

        if observers[pid] == nil {
            let callback: AXObserverCallback = { observer, element, notification, refcon in
                guard let refcon = refcon else { return }
                let windowObserver = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
                windowObserver.handleNotification(element: element, notification: notification as String)
            }

            guard let observer = AccessibilityHelper.createObserver(for: pid, callback: callback) else { return }
            observers[pid] = observer

            // Observe app-level focus change
            let appElement = AccessibilityHelper.appElement(for: pid)
            let context = Unmanaged.passUnretained(self).toOpaque()
            AccessibilityHelper.addNotification(
                observer: observer,
                element: appElement,
                notification: kAXFocusedWindowChangedNotification as String,
                context: context
            )
        }

        guard let observer = observers[pid] else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()

        let notifications = [
            kAXMovedNotification as String,
            kAXResizedNotification as String,
            kAXUIElementDestroyedNotification as String,
            kAXTitleChangedNotification as String,
        ]

        for notification in notifications {
            AccessibilityHelper.addNotification(
                observer: observer,
                element: window.element,
                notification: notification,
                context: context
            )
        }
    }

    func stopObserving(window: WindowInfo) {
        guard let observer = observers[window.ownerPID] else { return }

        let notifications = [
            kAXMovedNotification as String,
            kAXResizedNotification as String,
            kAXUIElementDestroyedNotification as String,
            kAXTitleChangedNotification as String,
        ]

        for notification in notifications {
            AccessibilityHelper.removeNotification(
                observer: observer,
                element: window.element,
                notification: notification
            )
        }
    }

    func stopAll() {
        observers.removeAll()
    }

    private func handleNotification(element: AXUIElement, notification: String) {
        // For focus changes, the callback usually receives the window element,
        // but sometimes receives the app element (when no window has focus).
        // Handle both cases.
        if notification == kAXFocusedWindowChangedNotification as String {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)

            // Check if element is a window by trying to get its window ID
            if let windowID = AccessibilityHelper.windowID(for: element) {
                // Element IS the focused window — use it directly
                onWindowFocused?(pid, element)
            } else {
                // Element is the app — query for the focused window
                var focusedWindow: AnyObject?
                let result = AXUIElementCopyAttributeValue(
                    element, kAXFocusedWindowAttribute as CFString, &focusedWindow
                )
                if result == .success, let windowElement = focusedWindow {
                    onWindowFocused?(pid, windowElement as! AXUIElement)
                }
            }
            return
        }

        guard let windowID = AccessibilityHelper.windowID(for: element) else { return }

        switch notification {
        case kAXMovedNotification as String:
            onWindowMoved?(windowID)
        case kAXResizedNotification as String:
            onWindowResized?(windowID)
        case kAXUIElementDestroyedNotification as String:
            onWindowDestroyed?(windowID)
        case kAXTitleChangedNotification as String:
            onTitleChanged?(windowID)
        default:
            break
        }
    }
}
```

**Step 2: Wire WindowObserver into AppDelegate**

Add to `AppDelegate` class properties:

```swift
let windowObserver = WindowObserver()
// Note: tabBarPanels dict was already added in Task 9
```

Add setup in `applicationDidFinishLaunching` after the permission check:

```swift
windowObserver.onWindowMoved = { [weak self] windowID in
    self?.handleWindowMoved(windowID)
}
windowObserver.onWindowResized = { [weak self] windowID in
    self?.handleWindowResized(windowID)
}
windowObserver.onWindowFocused = { [weak self] pid, element in
    self?.handleWindowFocused(pid: pid, element: element)
}
windowObserver.onWindowDestroyed = { [weak self] windowID in
    self?.handleWindowDestroyed(windowID)
}
windowObserver.onTitleChanged = { [weak self] windowID in
    self?.handleTitleChanged(windowID)
}
```

Add handler methods:

```swift
private func handleWindowMoved(_ windowID: CGWindowID) {
    guard let group = groupManager.group(for: windowID),
          let panel = tabBarPanels[group.id],
          let activeWindow = group.activeWindow,
          activeWindow.id == windowID,
          let frame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

    // Clamp to visible frame — ensure room for tab bar
    let visibleFrame = CoordinateConverter.visibleFrameInAX()
    let tabBarHeight = TabBarPanel.tabBarHeight
    var adjustedFrame = frame
    if frame.origin.y < visibleFrame.origin.y + tabBarHeight {
        adjustedFrame.origin.y = visibleFrame.origin.y + tabBarHeight
        AccessibilityHelper.setPosition(of: activeWindow.element, to: adjustedFrame.origin)
    }

    group.frame = adjustedFrame

    // Sync other windows
    for window in group.windows where window.id != windowID {
        AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
    }

    // Update panel position
    panel.positionAbove(windowFrame: adjustedFrame)
    panel.orderAbove(windowID: activeWindow.id)
}

private func handleWindowResized(_ windowID: CGWindowID) {
    guard let group = groupManager.group(for: windowID),
          let panel = tabBarPanels[group.id],
          let activeWindow = group.activeWindow,
          activeWindow.id == windowID,
          let frame = AccessibilityHelper.getFrame(of: activeWindow.element) else { return }

    group.frame = frame

    // Sync other windows
    for window in group.windows where window.id != windowID {
        AccessibilityHelper.setFrame(of: window.element, to: frame)
    }

    // Update panel size and position
    panel.positionAbove(windowFrame: frame)
    panel.orderAbove(windowID: activeWindow.id)
}

private func handleWindowFocused(pid: pid_t, element: AXUIElement) {
    // Find which window gained focus
    guard let windowID = AccessibilityHelper.windowID(for: element),
          let group = groupManager.group(for: windowID),
          let panel = tabBarPanels[group.id] else { return }

    group.switchTo(windowID: windowID)
    panel.orderAbove(windowID: windowID)
}

private func handleWindowDestroyed(_ windowID: CGWindowID) {
    guard let group = groupManager.group(for: windowID),
          let panel = tabBarPanels[group.id] else { return }

    windowObserver.stopObserving(window: group.windows.first { $0.id == windowID }!)
    groupManager.releaseWindow(withID: windowID, from: group)

    if !groupManager.groups.contains(where: { $0.id == group.id }) {
        panel.close()
        tabBarPanels.removeValue(forKey: group.id)
    }
}

private func handleTitleChanged(_ windowID: CGWindowID) {
    guard let group = groupManager.group(for: windowID) else { return }
    if let index = group.windows.firstIndex(where: { $0.id == windowID }),
       let newTitle = AccessibilityHelper.getTitle(of: group.windows[index].element) {
        group.windows[index].title = newTitle
    }
}
```

Update `createGroup` to register observers and store panels:

```swift
// At the end of createGroup, after creating the panel:
tabBarPanels[group.id] = panel

for window in group.windows {
    windowObserver.observe(window: window)
}
```

Update `releaseTab` to clean up observer:

```swift
// Before releasing the window:
windowObserver.stopObserving(window: group.windows[index])

// After group dissolution check:
if !groupManager.groups.contains(where: { $0.id == group.id }) {
    panel.close()
    tabBarPanels.removeValue(forKey: group.id)
}
```

Update `addWindow` to register observer:

```swift
private func addWindow(_ window: WindowInfo, to group: TabGroup) {
    AccessibilityHelper.setFrame(of: window.element, to: group.frame)
    groupManager.addWindow(window, to: group)
    windowObserver.observe(window: window)
}
```

Update `applicationWillTerminate` to also stop the observer:

```swift
func applicationWillTerminate(_ notification: Notification) {
    windowObserver.stopAll()
    for (_, panel) in tabBarPanels {
        panel.close()
    }
    tabBarPanels.removeAll()
    groupManager.dissolveAllGroups()
}
```

**Step 3: Build and test**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build && open build/Build/Products/Debug/Tabbed.app`

Expected: Create a group. Move the active window → tab bar and other windows snap to new position. Resize → everything syncs. Close a grouped window → it's removed from the tab. Switch to a grouped window via Cmd+Tab or clicking → tab bar updates active tab.

**Step 4: Commit**

```bash
git add Tabbed/Managers/WindowObserver.swift Tabbed/AppDelegate.swift
git commit -m "feat: add AXObserver integration for window tracking and sync"
```

---

### Task 11: Full-Screen Detection

**Files:**
- Modify: `Tabbed/Managers/WindowObserver.swift`
- Modify: `Tabbed/AppDelegate.swift`

**Step 1: Add full-screen detection**

When a grouped window's frame matches the screen bounds (after a resize notification), it likely entered full-screen. Release it from the group.

Add to `handleWindowResized` in AppDelegate, before the existing logic:

```swift
// Detect full-screen: window frame matches screen bounds
if let screen = NSScreen.main {
    let screenFrame = CGRect(
        origin: .zero,
        size: CGSize(width: screen.frame.width, height: screen.frame.height)
    )
    if frame.origin.x == 0 && frame.origin.y == 0 &&
       frame.width >= screenFrame.width && frame.height >= screenFrame.height {
        // Window went full-screen — release it
        windowObserver.stopObserving(window: group.windows.first { $0.id == windowID }!)
        groupManager.releaseWindow(withID: windowID, from: group)
        if !groupManager.groups.contains(where: { $0.id == group.id }) {
            panel.close()
            tabBarPanels.removeValue(forKey: group.id)
        }
        return
    }
}
```

**Step 2: Build and test**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build && open build/Build/Products/Debug/Tabbed.app`

Expected: Create a group. Click the green maximize button on one of the grouped windows → that window is released from the group. If only one window remains, the group dissolves.

**Step 3: Commit**

```bash
git add Tabbed/AppDelegate.swift
git commit -m "feat: detect full-screen and release window from group"
```

---

### Task 12: Tab Bar Panel Drag → Group Move

**Files:**
- Modify: `Tabbed/Views/TabBarPanel.swift`
- Modify: `Tabbed/AppDelegate.swift`

**Step 1: Add drag-end notification to TabBarPanel**

`isMovableByWindowBackground` handles the drag automatically. We need to detect when it ends and sync the windows. Override `mouseUp` in TabBarPanel:

```swift
var onPanelMoved: (() -> Void)?
private var frameOnMouseDown: NSRect = .zero

override func mouseDown(with event: NSEvent) {
    frameOnMouseDown = self.frame
    super.mouseDown(with: event)
}

override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
    // Only fire if the panel actually moved
    if self.frame != frameOnMouseDown {
        onPanelMoved?()
    }
}
```

**Step 2: Wire up in AppDelegate**

In `createGroup`, after creating the panel and before storing it:

```swift
panel.onPanelMoved = { [weak self] in
    self?.handlePanelMoved(group: group, panel: panel)
}
```

Add handler:

```swift
private func handlePanelMoved(group: TabGroup, panel: TabBarPanel) {
    let panelFrame = panel.frame
    let tabBarHeight = TabBarPanel.tabBarHeight

    // Convert panel's AppKit frame to AX coordinates for the window area below it
    let windowOriginAX = CoordinateConverter.appKitToAX(
        point: CGPoint(x: panelFrame.origin.x, y: panelFrame.origin.y),
        windowHeight: tabBarHeight
    )
    let windowFrame = CGRect(
        x: windowOriginAX.x,
        y: windowOriginAX.y + tabBarHeight,
        width: panelFrame.width,
        height: group.frame.height
    )

    group.frame = windowFrame

    for window in group.windows {
        AccessibilityHelper.setFrame(of: window.element, to: windowFrame)
    }

    if let activeWindow = group.activeWindow {
        AccessibilityHelper.raise(activeWindow.element)
        panel.orderAbove(windowID: activeWindow.id)
    }
}
```

**Step 3: Build and test**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build && open build/Build/Products/Debug/Tabbed.app`

Expected: Create a group. Drag the tab bar (on empty space between tabs) → tab bar moves. On release, all grouped windows snap to the new position below the tab bar.

**Step 4: Commit**

```bash
git add Tabbed/Views/TabBarPanel.swift Tabbed/AppDelegate.swift
git commit -m "feat: dragging tab bar moves entire group"
```

---

### Task 13: Tab Drag Reordering

**Files:**
- Modify: `Tabbed/Views/TabBarView.swift`

**Step 1: Add drag reordering to TabBarView**

Update TabBarView to support dragging tabs to reorder. Add `onMoveTab` callback and use `onDrag`/`onDrop`.

Note: `isMovableByWindowBackground` and SwiftUI `onDrag` should coexist without conflict — `onDrag` attaches to interactive controls (tab buttons), while `isMovableByWindowBackground` only triggers on non-interactive areas. If tab dragging unexpectedly moves the whole panel, disable `isMovableByWindowBackground` and implement panel drag manually via `mouseDown`/`mouseDragged` on background areas only.

```swift
// Add to TabBarView properties:
var onMoveTab: (Int, Int) -> Void

// Replace the ForEach in body with:
ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
    tabButton(for: window, at: index)
        .onDrag {
            NSItemProvider(object: String(index) as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            currentIndex: index,
            onMoveTab: onMoveTab
        ))
}
```

Add a drop delegate:

```swift
struct TabDropDelegate: DropDelegate {
    let currentIndex: Int
    let onMoveTab: (Int, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        item.loadObject(ofClass: NSString.self) { string, _ in
            guard let string = string as? String, let sourceIndex = Int(string) else { return }
            DispatchQueue.main.async {
                if sourceIndex != currentIndex {
                    onMoveTab(sourceIndex, currentIndex)
                }
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {}
    func dropExited(info: DropInfo) {}
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}
```

**Step 2: Wire onMoveTab in TabBarPanel and AppDelegate**

Update the `setContent` method signature and body to pass `onMoveTab`:

```swift
func setContent(group: TabGroup, onSwitchTab: @escaping (Int) -> Void, onReleaseTab: @escaping (Int) -> Void, onAddWindow: @escaping () -> Void, onMoveTab: @escaping (Int, Int) -> Void) {
    let tabBarView = TabBarView(
        group: group,
        onSwitchTab: onSwitchTab,
        onReleaseTab: onReleaseTab,
        onAddWindow: onAddWindow,
        onMoveTab: onMoveTab
    )
    // ... rest unchanged
}
```

In AppDelegate `createGroup`, update the `setContent` call to include `onMoveTab`:

```swift
panel.setContent(
    group: group,
    onSwitchTab: { [weak self] index in
        self?.switchTab(in: group, to: index, panel: panel)
    },
    onReleaseTab: { [weak self] index in
        self?.releaseTab(at: index, from: group, panel: panel)
    },
    onAddWindow: { [weak self] in
        self?.showWindowPicker(addingTo: group)
    },
    onMoveTab: { from, to in
        group.moveTab(from: from, to: to)
    }
)
```

**Step 3: Build and test**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme Tabbed -derivedDataPath build build && open build/Build/Products/Debug/Tabbed.app`

Expected: Create a group with 3+ windows. Drag a tab to a different position → tabs reorder. Active tab indicator follows correctly.

**Step 4: Commit**

```bash
git add Tabbed/Views/TabBarView.swift Tabbed/Views/TabBarPanel.swift Tabbed/AppDelegate.swift
git commit -m "feat: add tab drag reordering"
```

---

### Task 14: Final Polish & Cleanup

**Files:**
- Modify: `Tabbed/AppDelegate.swift`
- Modify: various files as needed

**Step 1: Remove any remaining temporary/debug code**

Search all files for `print(` statements and temporary test code. Remove them.

**Step 2: Handle edge case — adding a window via "+" when group has a tab bar panel**

Verify that after adding a window via "+", the new window's frame is set correctly and it appears as a new tab. The `addWindow` method already handles this.

**Step 3: Verify title changes propagate**

In `handleTitleChanged`, the `WindowInfo.title` is updated. Since `TabGroup` is an `ObservableObject` and `windows` is `@Published`, the SwiftUI view should update. Verify: create a group with a browser window, navigate to a new page → tab title updates.

**Step 4: Run all tests**

Run: `xcodegen generate && xcodebuild -project Tabbed.xcodeproj -scheme TabbedTests -derivedDataPath build test`
Expected: All tests pass

**Step 5: Full manual test pass**

Test checklist:
- [ ] App launches with menu bar icon, no Dock icon
- [ ] Accessibility permission prompt appears on first launch
- [ ] Menu bar popover shows "No groups" initially
- [ ] "New Group" opens window picker
- [ ] Window picker lists open windows with icons and titles
- [ ] Already-grouped windows are grayed out
- [ ] Selecting 2+ windows enables "Create Group"
- [ ] Creating a group: windows snap together, tab bar appears
- [ ] Clicking tabs switches the visible window
- [ ] Tab clicks work on first click (no focus stealing)
- [ ] "+" button opens picker to add windows to group
- [ ] Release button (hover → X) removes window from group
- [ ] Group with 2 windows: releasing one dissolves the group
- [ ] Moving the active window: everything snaps on release
- [ ] Resizing the active window: everything syncs
- [ ] Dragging the tab bar: group moves on release
- [ ] Dragging tabs: reordering works
- [ ] Cmd+Tab to a grouped window: tab bar updates active tab
- [ ] Closing a grouped window: removed from group
- [ ] Full-screen a grouped window: released from group
- [ ] Window title changes: tab label updates
- [ ] Multiple groups can coexist
- [ ] Quitting the app: all panels removed, windows stay in place

**Step 6: Commit**

```bash
git add -A
git commit -m "feat: Tabbed MVP — macOS window tab grouping utility"
```
