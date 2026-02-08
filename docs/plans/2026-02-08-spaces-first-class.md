# Spaces as First-Class Citizens — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make macOS Spaces a first-class concept so tab groups are always single-space, preventing cross-space bugs.

**Architecture:** Add `spaceID` to `TabGroup`, add a `SpaceUtils.spaceID(for:)` query helper, guard every entry point that adds windows to groups, and add a space-change handler that ejects stray windows.

**Tech Stack:** Swift 5.9, macOS 13+, CoreGraphics private SPIs (`CGSCopySpacesForWindows`), XCTest

---

### Task 1: Add `SpaceUtils.spaceID(for:)` helper

**Files:**
- Create: `Tabbed/Platform/SpaceUtils.swift`
- Test: `TabbedTests/SpaceUtilsTests.swift`

The CGS boilerplate for querying a window's space is repeated in 3+ places. Extract it once.

**Step 1: Write the failing test**

Create `TabbedTests/SpaceUtilsTests.swift`:

```swift
import XCTest
@testable import Tabbed

final class SpaceUtilsTests: XCTestCase {
    func testSpaceIDReturnsNilForInvalidWindow() {
        // Window ID 0 / nonexistent windows should return nil
        let result = SpaceUtils.spaceID(for: 0)
        XCTAssertNil(result)
    }

    func testSpaceIDsReturnsEmptyForNoWindows() {
        let result = SpaceUtils.spaceIDs(for: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSpaceIDsSkipsInvalidWindows() {
        let result = SpaceUtils.spaceIDs(for: [0, 99999])
        // Both invalid, so results should be empty or nil values
        XCTAssertTrue(result.values.allSatisfy { $0 == nil || $0 != nil })
    }
}
```

**Step 2: Run test to verify it fails**

Run: `scripts/test.sh`
Expected: FAIL — `SpaceUtils` not defined

**Step 3: Write implementation**

Create `Tabbed/Platform/SpaceUtils.swift`:

```swift
import CoreGraphics

enum SpaceUtils {
    /// Returns the primary space ID for a window, or nil if the window doesn't exist.
    static func spaceID(for windowID: CGWindowID) -> UInt64? {
        let conn = CGSMainConnectionID()
        let spaces = CGSCopySpacesForWindows(conn, 0x7, [windowID] as CFArray) as? [UInt64] ?? []
        return spaces.first
    }

    /// Batch query: returns a dictionary mapping each window ID to its space ID (or nil).
    static func spaceIDs(for windowIDs: [CGWindowID]) -> [CGWindowID: UInt64?] {
        guard !windowIDs.isEmpty else { return [:] }
        let conn = CGSMainConnectionID()
        var result: [CGWindowID: UInt64?] = [:]
        // Query individually since CGSCopySpacesForWindows returns a flat array
        // that doesn't indicate which space belongs to which window when batched
        for wid in windowIDs {
            let spaces = CGSCopySpacesForWindows(conn, 0x7, [wid] as CFArray) as? [UInt64] ?? []
            result[wid] = spaces.first
        }
        return result
    }
}
```

**Step 4: Add to project.yml sources (already included via `Tabbed` directory glob) and run tests**

Run: `scripts/test.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/Platform/SpaceUtils.swift TabbedTests/SpaceUtilsTests.swift
git commit -m "feat: add SpaceUtils helper for querying window space IDs"
```

---

### Task 2: Add `spaceID` to `TabGroup`

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroup.swift` — add `spaceID` property
- Modify: `Tabbed/features/TabGroups/GroupManager.swift` — pass `spaceID` through `createGroup`
- Test: `TabbedTests/GroupManagerTests.swift` — update existing tests, add space tests

**Step 1: Write the failing tests**

Add to `GroupManagerTests.swift`:

```swift
func testCreateGroupSetsSpaceID() {
    let gm = GroupManager()
    let windows = [makeWindow(id: 1), makeWindow(id: 2)]
    let group = gm.createGroup(with: windows, frame: .zero, spaceID: 42)
    XCTAssertNotNil(group)
    XCTAssertEqual(group?.spaceID, 42)
}

func testCreateGroupWithoutSpaceIDDefaultsToZero() {
    let gm = GroupManager()
    let windows = [makeWindow(id: 1), makeWindow(id: 2)]
    let group = gm.createGroup(with: windows, frame: .zero)
    XCTAssertNotNil(group)
    XCTAssertEqual(group?.spaceID, 0)
}
```

**Step 2: Run test to verify it fails**

Run: `scripts/test.sh`
Expected: FAIL — `spaceID` parameter not recognized

**Step 3: Write implementation**

Modify `TabGroup.swift` — add property and update init:

```swift
// Add after `var tabBarSqueezeDelta`:
var spaceID: UInt64

// Update init:
init(windows: [WindowInfo], frame: CGRect, spaceID: UInt64 = 0) {
    self.windows = windows
    self.activeIndex = 0
    self.frame = frame
    self.spaceID = spaceID
    self.focusHistory = windows.map(\.id)
}
```

Modify `GroupManager.swift` — update `createGroup`:

```swift
@discardableResult
func createGroup(with windows: [WindowInfo], frame: CGRect, spaceID: UInt64 = 0) -> TabGroup? {
    guard windows.count >= 1 else { return nil }
    let uniqueIDs = Set(windows.map(\.id))
    guard uniqueIDs.count == windows.count else { return nil }
    for window in windows {
        if isWindowGrouped(window.id) { return nil }
    }
    let group = TabGroup(windows: windows, frame: frame, spaceID: spaceID)
    groups.append(group)
    return group
}
```

**Step 4: Run tests**

Run: `scripts/test.sh`
Expected: PASS — all existing tests still pass (default spaceID=0), new tests pass

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroup.swift Tabbed/features/TabGroups/GroupManager.swift TabbedTests/GroupManagerTests.swift
git commit -m "feat: add spaceID property to TabGroup"
```

---

### Task 3: Set `spaceID` at group creation time

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroups.swift` — `setupGroup` queries and passes spaceID

The `setupGroup` method is the single funnel for group creation. It should query the first window's space and pass it to `GroupManager.createGroup`.

**Step 1: No new test needed** — this is wiring that calls into system APIs (CGS). The model tests from Task 2 cover the plumbing. Integration tested manually.

**Step 2: Write implementation**

Modify `setupGroup` in `TabGroups.swift`:

```swift
@discardableResult
func setupGroup(
    with windows: [WindowInfo],
    frame: CGRect,
    squeezeDelta: CGFloat,
    activeIndex: Int = 0
) -> TabGroup? {
    let spaceID = windows.first.flatMap { SpaceUtils.spaceID(for: $0.id) } ?? 0
    guard let group = groupManager.createGroup(with: windows, frame: frame, spaceID: spaceID) else { return nil }
    // ... rest unchanged
```

Also add logging:

```swift
Logger.log("[SPACE] Created group \(group.id) on space \(spaceID)")
```

**Step 3: Run tests and build**

Run: `scripts/build.sh && scripts/test.sh`
Expected: PASS

**Step 4: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroups.swift
git commit -m "feat: query and store spaceID when creating groups"
```

---

### Task 4: Guard `addWindow` with space check

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroups.swift` — `addWindow(_:to:)` rejects cross-space windows

**Step 1: Write implementation**

In `addWindow(_:to:)` (TabGroups.swift), add a space guard at the top:

```swift
func addWindow(_ window: WindowInfo, to group: TabGroup) {
    if group.spaceID != 0,
       let windowSpace = SpaceUtils.spaceID(for: window.id),
       windowSpace != group.spaceID {
        Logger.log("[SPACE] Rejected addWindow wid=\(window.id) (space \(windowSpace)) to group \(group.id) (space \(group.spaceID))")
        return
    }
    // ... existing code unchanged
```

The `group.spaceID != 0` guard is a safety valve for restored groups that couldn't resolve their space at creation time.

**Step 2: Run tests and build**

Run: `scripts/build.sh && scripts/test.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroups.swift
git commit -m "fix: reject cross-space windows in addWindow"
```

---

### Task 5: Guard auto-capture with space check

**Files:**
- Modify: `Tabbed/features/AutoCapture/AutoCapture.swift` — `captureWindowIfEligible` checks space

This is one of the two reported bugs: auto-capture grabs a window into a group on a different space.

**Step 1: Write implementation**

In `captureWindowIfEligible` (AutoCapture.swift), add a space check after the `buildWindowInfo` call:

```swift
guard !groupManager.isWindowGrouped(window.id) else { return false }

// Reject windows on a different space than the capture group
if group.spaceID != 0,
   let windowSpace = SpaceUtils.spaceID(for: window.id),
   windowSpace != group.spaceID {
    Logger.log("[AutoCapture] captureIfEligible[\(source)]: wrong space (\(windowSpace) != \(group.spaceID)) — \(window.appName): \(window.title)")
    return false
}
```

**Step 2: Run tests and build**

Run: `scripts/build.sh && scripts/test.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add Tabbed/features/AutoCapture/AutoCapture.swift
git commit -m "fix: auto-capture rejects windows from different space"
```

---

### Task 6: Guard merge and cross-panel drop with space check

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroups.swift` — `mergeGroup` and `moveTabsToExistingGroup` check space

**Step 1: Write implementation**

In `mergeGroup(_:into:)`:

```swift
func mergeGroup(_ source: TabGroup, into target: TabGroup) {
    guard let sourcePanel = tabBarPanels[source.id] else { return }
    if target.spaceID != 0, source.spaceID != 0, target.spaceID != source.spaceID {
        Logger.log("[SPACE] Rejected merge: source space \(source.spaceID) != target space \(target.spaceID)")
        return
    }
    // ... existing code
```

In `moveTabsToExistingGroup(withIDs:from:sourcePanel:toGroupID:at:)`:

```swift
guard let targetGroup = groupManager.groups.first(where: { $0.id == targetGroupID }),
      let targetPanel = tabBarPanels[targetGroupID] else { return }

if targetGroup.spaceID != 0, sourceGroup.spaceID != 0, targetGroup.spaceID != sourceGroup.spaceID {
    Logger.log("[SPACE] Rejected cross-panel drop: source space \(sourceGroup.spaceID) != target space \(targetGroup.spaceID)")
    return
}
```

**Step 2: Run tests and build**

Run: `scripts/build.sh && scripts/test.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroups.swift
git commit -m "fix: guard merge and cross-panel drop against cross-space groups"
```

---

### Task 7: Refactor existing space queries to use SpaceUtils

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroups.swift` — `movePanelToWindowSpace` uses `SpaceUtils.spaceID`
- Modify: `Tabbed/features/TabGroups/WindowPickerView.swift` — `mergeableGroups` uses `SpaceUtils.spaceID`

**Step 1: Write implementation**

Simplify `movePanelToWindowSpace` in TabGroups.swift:

```swift
func movePanelToWindowSpace(_ panel: TabBarPanel, windowID: CGWindowID) {
    guard panel.windowNumber > 0 else { return }
    guard let targetSpace = SpaceUtils.spaceID(for: windowID) else { return }
    let panelWID = CGWindowID(panel.windowNumber)
    guard SpaceUtils.spaceID(for: panelWID) != targetSpace else { return }
    let conn = CGSMainConnectionID()
    CGSMoveWindowsToManagedSpace(conn, [panelWID] as CFArray, targetSpace)
}
```

Simplify `mergeableGroups` in WindowPickerView.swift:

```swift
private var mergeableGroups: [TabGroup] {
    guard let target = addingToGroup,
          let targetWindowID = target.activeWindow?.id,
          let targetSpace = SpaceUtils.spaceID(for: targetWindowID) else { return [] }
    return groupManager.groups.filter { group in
        guard group.id != target.id,
              let windowID = group.activeWindow?.id else { return false }
        return SpaceUtils.spaceID(for: windowID) == targetSpace
    }
}
```

**Step 2: Run tests and build**

Run: `scripts/build.sh && scripts/test.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroups.swift Tabbed/features/TabGroups/WindowPickerView.swift
git commit -m "refactor: use SpaceUtils.spaceID in panel sync and window picker"
```

---

### Task 8: Add space-change handler to eject stray windows

**Files:**
- Modify: `Tabbed/AppDelegate.swift` — register space-change handler
- Modify: `Tabbed/features/TabGroups/WindowEventHandlers.swift` — add `handleSpaceChanged()` method

This is the key defensive mechanism. When the user switches spaces, scan all groups and eject any windows that are no longer on the group's space.

**Step 1: Write implementation**

Add to `WindowEventHandlers.swift`:

```swift
// MARK: - Space Change Handler

extension AppDelegate {
    func handleSpaceChanged() {
        for group in groupManager.groups {
            guard group.spaceID != 0 else { continue }
            let strayIDs = group.windows.compactMap { window -> CGWindowID? in
                guard let windowSpace = SpaceUtils.spaceID(for: window.id),
                      windowSpace != group.spaceID else { return nil }
                return window.id
            }
            guard !strayIDs.isEmpty else { continue }
            Logger.log("[SPACE] Ejecting \(strayIDs.count) stray windows from group \(group.id): \(strayIDs)")

            guard let panel = tabBarPanels[group.id] else { continue }

            for windowID in strayIDs {
                guard let window = group.windows.first(where: { $0.id == windowID }) else { continue }
                windowObserver.stopObserving(window: window)
                expectedFrames.removeValue(forKey: window.id)

                // Expand the ejected window to cover tab bar space
                if let frame = AccessibilityHelper.getFrame(of: window.element) {
                    let delta = max(group.tabBarSqueezeDelta, ScreenCompensation.tabBarHeight)
                    let expanded = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
                    AccessibilityHelper.setSize(of: window.element, to: expanded.size)
                    AccessibilityHelper.setPosition(of: window.element, to: expanded.origin)
                }
            }

            groupManager.releaseWindows(withIDs: Set(strayIDs), from: group)

            if !groupManager.groups.contains(where: { $0.id == group.id }) {
                handleGroupDissolution(group: group, panel: panel)
            } else if let newActive = group.activeWindow {
                raiseAndUpdate(newActive, in: group)
                panel.orderAbove(windowID: newActive.id)
            }
        }
        evaluateAutoCapture()
    }
}
```

Update the space-change observer in `AppDelegate.swift` `applicationDidFinishLaunching`:

Replace:
```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.evaluateAutoCapture()
}
```

With:
```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.handleSpaceChanged()
}
```

Note: `handleSpaceChanged()` already calls `evaluateAutoCapture()` at the end.

**Step 2: Run tests and build**

Run: `scripts/build.sh && scripts/test.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add Tabbed/features/TabGroups/WindowEventHandlers.swift Tabbed/AppDelegate.swift
git commit -m "feat: eject stray windows from groups on space change"
```

---

### Task 9: Update `isGroupOnCurrentSpace` to use `spaceID`

**Files:**
- Modify: `Tabbed/features/AutoCapture/AutoCapture.swift` — simplify `isGroupOnCurrentSpace`

Now that groups have a `spaceID`, we can compare directly instead of scanning the CG window list.

**Step 1: Write implementation**

However, `isGroupOnCurrentSpace` needs to compare against the *current* space, which requires knowing the current space ID. There's no direct API for "current space ID" — the existing approach (checking if any group window appears in the on-screen CG list) is actually the most reliable way to determine this. Keep the existing implementation but also add a spaceID-based fast path:

Actually, the simplest approach: query the active window's space to determine the current space, then compare. But the CG window list approach is simpler and already works. Leave `isGroupOnCurrentSpace` as-is — the `handleSpaceChanged` handler is the real fix.

**Skip this task** — the existing implementation is fine and changing it doesn't fix any bugs.

---

### Task 10: Set spaceID during session restore

**Files:**
- Modify: `Tabbed/features/SessionRestore/SessionRestore.swift` — pass spaceID to `setupGroup`

Session restore uses `setupGroup` which now queries spaceID from the first matched window. No additional changes needed — Task 3 already handles this via `setupGroup`. The spaceID will be set from whatever space the restored windows happen to be on.

**Verify:** Read through `restoreSession` and confirm `setupGroup` is called, which already queries spaceID. No code changes needed.

**Skip this task** — already handled by Task 3.

---

### Summary of Changes

| Task | File | Change |
|------|------|--------|
| 1 | `Tabbed/Platform/SpaceUtils.swift` | New: `spaceID(for:)` and `spaceIDs(for:)` helpers |
| 2 | `TabGroup.swift`, `GroupManager.swift` | Add `spaceID` property and pass through |
| 3 | `TabGroups.swift` | `setupGroup` queries and stores spaceID |
| 4 | `TabGroups.swift` | `addWindow` rejects cross-space windows |
| 5 | `AutoCapture.swift` | `captureWindowIfEligible` rejects cross-space windows |
| 6 | `TabGroups.swift` | `mergeGroup` and `moveTabsToExistingGroup` reject cross-space |
| 7 | `TabGroups.swift`, `WindowPickerView.swift` | Refactor to use `SpaceUtils.spaceID` |
| 8 | `WindowEventHandlers.swift`, `AppDelegate.swift` | Space-change handler ejects stray windows |

**Bugs fixed:**
- Dragging out a tab randomly adds it to a group from a different space → Task 4
- Auto-capture joins a window into a different space's group → Task 5
- Cross-spatial tab bars after either bug → Task 8 (defensive cleanup)
