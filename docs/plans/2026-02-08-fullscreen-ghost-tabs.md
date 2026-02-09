# Fullscreen Ghost Tabs Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When a grouped window enters macOS true fullscreen, keep it in the group as a "ghost tab" and restore it when it exits fullscreen.

**Architecture:** Add a `isFullscreened` flag to `WindowInfo`. When fullscreen is detected in `handleWindowResized`, mark the window instead of releasing it. Keep AX observation alive so we get the resize notification on exit. Ghost tabs render dimmed in the tab bar with a `-` button (release from group). Clicking a ghost tab activates its fullscreen app. Skip fullscreened windows in all frame-sync loops and the space-change ejector.

**Tech Stack:** Swift 5.9, macOS Accessibility APIs, SwiftUI

---

### Task 1: Add `isFullscreened` flag to WindowInfo

**Files:**
- Modify: `Tabbed/features/TabGroups/WindowInfo.swift:4-19`
- Test: `TabbedTests/TabGroupTests.swift`

**Step 1: Write the failing test**

Add to `TabGroupTests.swift`:

```swift
func testWindowInfoIsFullscreenedDefaultsFalse() {
    let window = makeWindow(id: 1)
    XCTAssertFalse(window.isFullscreened)
}
```

**Step 2: Run test to verify it fails**

Run: `scripts/test.sh`
Expected: FAIL — `WindowInfo` has no member `isFullscreened`

**Step 3: Write minimal implementation**

In `WindowInfo.swift`, add a mutable property after `cgBounds`:

```swift
var isFullscreened: Bool = false
```

Update `==` to include the new field:

```swift
static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
    lhs.id == rhs.id && lhs.isFullscreened == rhs.isFullscreened
}
```

**Step 4: Run test to verify it passes**

Run: `scripts/test.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/WindowInfo.swift TabbedTests/TabGroupTests.swift
git commit -m "feat: add isFullscreened flag to WindowInfo"
```

---

### Task 2: Add fullscreen-aware helpers to TabGroup

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroup.swift`
- Test: `TabbedTests/TabGroupTests.swift`

We need TabGroup to know which windows are fullscreened so it can skip them in active window resolution and cycling.

**Step 1: Write failing tests**

Add to `TabGroupTests.swift`:

```swift
func testFullscreenedWindowsProperty() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
    XCTAssertTrue(group.fullscreenedWindowIDs.isEmpty)
    group.windows[1].isFullscreened = true
    XCTAssertEqual(group.fullscreenedWindowIDs, [2])
}

func testVisibleWindowsExcludesFullscreened() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
    group.windows[1].isFullscreened = true
    XCTAssertEqual(group.visibleWindows.map(\.id), [1, 3])
}
```

**Step 2: Run test to verify it fails**

Run: `scripts/test.sh`
Expected: FAIL — no member `fullscreenedWindowIDs` or `visibleWindows`

**Step 3: Write minimal implementation**

Add computed properties to `TabGroup.swift`:

```swift
var fullscreenedWindowIDs: Set<CGWindowID> {
    Set(windows.filter(\.isFullscreened).map(\.id))
}

/// Windows that are not in fullscreen — used for frame sync operations.
var visibleWindows: [WindowInfo] {
    windows.filter { !$0.isFullscreened }
}
```

**Step 4: Run test to verify it passes**

Run: `scripts/test.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroup.swift TabbedTests/TabGroupTests.swift
git commit -m "feat: add fullscreenedWindowIDs and visibleWindows to TabGroup"
```

---

### Task 3: Handle fullscreen entry — mark instead of release

**Files:**
- Modify: `Tabbed/features/TabGroups/WindowEventHandlers.swift:104-114`

This is the core change. Instead of stopping observation and releasing the window, mark it as fullscreened and hide the tab bar if no visible windows remain.

**Step 1: No unit test** (this is AX integration code — tested manually)

**Step 2: Replace the fullscreen block in `handleWindowResized`**

Replace lines 104-114:

```swift
if AccessibilityHelper.isFullScreen(activeWindow.element) {
    expectedFrames.removeValue(forKey: windowID)
    windowObserver.stopObserving(window: activeWindow)
    groupManager.releaseWindow(withID: windowID, from: group)
    if !groupManager.groups.contains(where: { $0.id == group.id }) {
        handleGroupDissolution(group: group, panel: panel)
    } else if let newActive = group.activeWindow {
        bringTabToFront(newActive, in: group)
    }
    return
}
```

With:

```swift
if AccessibilityHelper.isFullScreen(activeWindow.element) {
    Logger.log("[FULLSCREEN] Window \(windowID) entered fullscreen in group \(group.id)")
    expectedFrames.removeValue(forKey: windowID)
    if let idx = group.windows.firstIndex(where: { $0.id == windowID }) {
        group.windows[idx].isFullscreened = true
    }
    // Switch to next visible tab if available
    if let nextVisible = group.visibleWindows.first {
        group.switchTo(windowID: nextVisible.id)
        bringTabToFront(nextVisible, in: group)
    } else {
        // All windows fullscreened — hide the tab bar
        panel.orderOut(nil)
    }
    return
}
```

**Step 3: Add early return for fullscreen exit detection**

Add this block at the **top** of `handleWindowResized`, before the existing guard (before line 95):

```swift
// Check if a fullscreened window is exiting fullscreen.
// This runs before the main guard because the fullscreened window
// won't be the activeWindow (a visible tab is active instead).
if let group = groupManager.group(for: windowID),
   let idx = group.windows.firstIndex(where: { $0.id == windowID }),
   group.windows[idx].isFullscreened {
    if !AccessibilityHelper.isFullScreen(group.windows[idx].element) {
        handleFullscreenExit(windowID: windowID, group: group)
    }
    return
}
```

**Step 4: Build**

Run: `scripts/build.sh`
Expected: Build succeeds (after Task 4 adds `handleFullscreenExit`)

Note: This task and Task 4 must be committed together since `handleFullscreenExit` is referenced here but defined in Task 4.

---

### Task 4: Handle fullscreen exit — restore window to group

**Files:**
- Modify: `Tabbed/features/TabGroups/WindowEventHandlers.swift`

**Step 1: Add `handleFullscreenExit` method**

Add to the `AppDelegate` extension in `WindowEventHandlers.swift`:

```swift
// MARK: - Fullscreen Restoration

func handleFullscreenExit(windowID: CGWindowID, group: TabGroup) {
    guard let panel = tabBarPanels[group.id],
          let idx = group.windows.firstIndex(where: { $0.id == windowID }) else { return }

    Logger.log("[FULLSCREEN] Window \(windowID) exited fullscreen in group \(group.id)")
    group.windows[idx].isFullscreened = false

    // Re-squeeze the window to fit the group's current frame
    let element = group.windows[idx].element
    setExpectedFrame(group.frame, for: [windowID])
    AccessibilityHelper.setFrame(of: element, to: group.frame)

    // Make this the active tab and bring it to front
    group.switchTo(windowID: windowID)
    group.recordFocus(windowID: windowID)
    lastActiveGroupID = group.id

    // Ensure tab bar is visible (it may have been hidden if all were fullscreened)
    panel.positionAbove(windowFrame: group.frame)
    panel.show(above: group.frame, windowID: windowID)
    bringTabToFront(group.windows[idx], in: group)
}
```

**Step 2: Build**

Run: `scripts/build.sh`
Expected: PASS

**Step 3: Commit Tasks 3 + 4 together**

```bash
git add Tabbed/features/TabGroups/WindowEventHandlers.swift
git commit -m "feat: mark windows as fullscreened instead of releasing, restore on exit"
```

---

### Task 5: Skip fullscreened windows in frame-sync loops

**Files:**
- Modify: `Tabbed/features/TabGroups/WindowEventHandlers.swift` (move/resize handlers)
- Modify: `Tabbed/features/TabGroups/TabGroups.swift` (setupGroup, switchTab, bar drag, etc.)

When move/resize handlers sync all group windows to the same frame, fullscreened windows must be skipped — macOS will reject the frame change and it could cause flicker on exit.

**Step 1: Update `handleWindowMoved` (WindowEventHandlers.swift:83-87)**

Change:
```swift
let otherIDs = group.windows.filter { $0.id != windowID }.map(\.id)
setExpectedFrame(adjustedFrame, for: otherIDs)
for window in group.windows where window.id != windowID {
    AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
}
```

To:
```swift
let others = group.visibleWindows.filter { $0.id != windowID }
setExpectedFrame(adjustedFrame, for: others.map(\.id))
for window in others {
    AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
}
```

**Step 2: Update `handleWindowResized` (WindowEventHandlers.swift:137-141)**

Same pattern — change:
```swift
let otherIDs = group.windows.filter { $0.id != windowID }.map(\.id)
setExpectedFrame(adjustedFrame, for: otherIDs)
for window in group.windows where window.id != windowID {
    AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
}
```

To:
```swift
let others = group.visibleWindows.filter { $0.id != windowID }
setExpectedFrame(adjustedFrame, for: others.map(\.id))
for window in others {
    AccessibilityHelper.setFrame(of: window.element, to: adjustedFrame)
}
```

**Step 3: Update the resync block** in `handleWindowResized` (around line 173-177)

Same change — filter to `visibleWindows`:
```swift
let others = group.visibleWindows.filter { $0.id != activeWindow.id }
self.setExpectedFrame(clamped, for: others.map(\.id))
for window in others {
    AccessibilityHelper.setFrame(of: window.element, to: clamped)
}
```

**Step 4: Update frame sync in `TabGroups.swift`**

All these loops set frame on `group.windows` — change to `group.visibleWindows`:

- `setupGroup` (lines 97-101): `setExpectedFrame` + `setFrame` loop
- `setupGroup` delayed resync (lines 190-196): the `others` loop
- `switchTab` (lines 258-259): `setExpectedFrame` + `setFrame` for the switched-to window — this one is fine as-is since we only switch to visible tabs
- `handleBarDrag` (lines 540-544): `setExpectedFrame` + `setPosition` loop
- `handleBarDragEnded` (lines 552-556): `setExpectedFrame` + `setFrame` loop
- `handleBarDragEnded` clamping loop (lines 569-573)
- `setGroupFrame` (lines 609-613)

For each, replace `group.windows` with `group.visibleWindows` in the iteration and ID mapping.

**Step 5: Build and test**

Run: `scripts/build.sh && scripts/test.sh`
Expected: PASS

**Step 6: Commit**

```bash
git add Tabbed/features/TabGroups/WindowEventHandlers.swift Tabbed/features/TabGroups/TabGroups.swift
git commit -m "fix: skip fullscreened windows in all frame-sync loops"
```

---

### Task 6: Skip fullscreened windows in space-change ejector

**Files:**
- Modify: `Tabbed/features/TabGroups/WindowEventHandlers.swift:315-352`

Fullscreened windows live on their own Space. The `handleSpaceChanged` handler must not eject them.

**Step 1: Update `handleSpaceChanged`**

In the `strayIDs` computation (lines 319-323), skip fullscreened windows:

```swift
let strayIDs = group.windows.compactMap { window -> CGWindowID? in
    guard !window.isFullscreened else { return nil }  // ← add this line
    guard let windowSpace = spaceMap[window.id],
          windowSpace != group.spaceID else { return nil }
    return window.id
}
```

**Step 2: Build**

Run: `scripts/build.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add Tabbed/features/TabGroups/WindowEventHandlers.swift
git commit -m "fix: don't eject fullscreened windows from group on space change"
```

---

### Task 7: Ghost tab UI in TabBarView

**Files:**
- Modify: `Tabbed/features/TabGroups/TabBarView.swift`
- Test: `TabbedTests/TabGroupTests.swift`

Ghost tabs render dimmed with a `-` button (release from group, not close). Clicking focuses the fullscreen app.

**Step 1: Write failing test for ghost tab tooltip truncation check**

Not needed — the view layer is best tested manually. Proceed to implementation.

**Step 2: Update `tabItem` in TabBarView.swift**

In the `tabItem` method (starting line 358), modify the close/release button logic. Currently (lines 377-401):

```swift
if isHovered && !isSelected {
    if isActive {
        Image(systemName: "minus")
            // ... release button
    } else {
        Image(systemName: confirmingCloseID == window.id ? "questionmark" : "xmark")
            // ... close button
    }
}
```

Change to:

```swift
if isHovered && !isSelected {
    if window.isFullscreened || isActive {
        Image(systemName: "minus")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded {
                onReleaseTab(index)
            })
    } else {
        Image(systemName: confirmingCloseID == window.id ? "questionmark" : "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(confirmingCloseID == window.id ? .primary : .secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded {
                if confirmingCloseID == window.id {
                    confirmingCloseID = nil
                    onCloseTab(index)
                } else {
                    confirmingCloseID = window.id
                }
            })
    }
}
```

**Step 3: Dim ghost tab appearance**

In the text styling (line 373), adjust opacity for fullscreened:

```swift
.foregroundStyle(window.isFullscreened ? .tertiary : isActive ? .primary : .secondary)
```

Dim the icon too (line 367):

```swift
Image(nsImage: icon)
    .resizable()
    .frame(width: 16, height: 16)
    .opacity(window.isFullscreened ? 0.4 : 1.0)
```

**Step 4: Build**

Run: `scripts/build.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/TabBarView.swift
git commit -m "feat: ghost tab UI — dimmed appearance with minus button for fullscreened windows"
```

---

### Task 8: Ghost tab click → focus fullscreen app

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroups.swift` (switchTab method)

When clicking a ghost tab, we should activate the fullscreened app (bringing the user to its fullscreen Space) instead of doing the normal frame-sync tab switch.

**Step 1: Update `switchTab` in TabGroups.swift**

At the top of `switchTab` (line 236), add an early return for fullscreened windows:

```swift
func switchTab(in group: TabGroup, to index: Int, panel: TabBarPanel) {
    guard let window = group.windows[safe: index] else { return }

    // Fullscreened window: just activate its app (takes user to fullscreen Space)
    if window.isFullscreened {
        if let app = NSRunningApplication(processIdentifier: window.ownerPID) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [])
            }
        }
        return
    }

    let previousID = group.activeWindow?.id
    group.switchTo(index: index)
    // ... rest of existing method unchanged
```

**Step 2: Build**

Run: `scripts/build.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroups.swift
git commit -m "feat: clicking ghost tab activates fullscreen app"
```

---

### Task 9: Handle fullscreened window release (- button)

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroups.swift` (releaseTab method)

When releasing a fullscreened window, we don't need to expand its frame (it's fullscreened, macOS manages its frame). Just stop observing, clear the flag, and remove from group.

**Step 1: Update `releaseTab` in TabGroups.swift**

At the top of `releaseTab` (line 264), add handling for fullscreened windows:

```swift
func releaseTab(at index: Int, from group: TabGroup, panel: TabBarPanel) {
    guard let window = group.windows[safe: index] else { return }

    windowObserver.stopObserving(window: window)
    expectedFrames.removeValue(forKey: window.id)

    // Fullscreened windows: skip frame expansion (macOS manages their frame)
    if !window.isFullscreened {
        if let frame = AccessibilityHelper.getFrame(of: window.element) {
            let delta = max(group.tabBarSqueezeDelta, ScreenCompensation.tabBarHeight)
            let expanded = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
            let element = window.element
            AccessibilityHelper.setSize(of: element, to: expanded.size)
            AccessibilityHelper.setPosition(of: element, to: expanded.origin)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AccessibilityHelper.setPosition(of: element, to: expanded.origin)
                AccessibilityHelper.setSize(of: element, to: expanded.size)
            }
        }
    }

    groupManager.releaseWindow(withID: window.id, from: group)
    // ... rest unchanged
```

**Step 2: Build**

Run: `scripts/build.sh`
Expected: PASS

**Step 3: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroups.swift
git commit -m "fix: skip frame expansion when releasing fullscreened window"
```

---

### Task 10: Handle window destruction while fullscreened

**Files:**
- Modify: `Tabbed/features/TabGroups/WindowEventHandlers.swift` (handleWindowDestroyed)

If a fullscreened window is closed (user closes it while in fullscreen, or the app quits), `handleWindowDestroyed` already handles this correctly — it releases the window from the group regardless of state. No code change needed, but verify the path works.

**Step 1: Read `handleWindowDestroyed` and verify**

The existing code at lines 216-255 handles destroyed windows by looking them up in the group, doing bookkeeping, and calling `removeDestroyedWindow`. This works for fullscreened windows too because it doesn't check `activeWindow.id == windowID` — it looks up by window ID directly.

**Step 2: No changes needed — skip to commit**

This task is a verification-only task. No commit.

---

### Task 11: Skip fullscreened windows in tab cycling

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroup.swift` (nextInMRUCycle)
- Test: `TabbedTests/TabGroupTests.swift`

The MRU cycle should skip fullscreened windows since the user can't see them alongside normal tabs.

**Step 1: Write failing test**

Add to `TabGroupTests.swift`:

```swift
func testMRUCycleSkipsFullscreenedWindows() {
    let group = TabGroup(windows: [makeWindow(id: 1), makeWindow(id: 2), makeWindow(id: 3)], frame: .zero)
    group.recordFocus(windowID: 1)
    group.recordFocus(windowID: 2)
    group.recordFocus(windowID: 3)
    // Fullscreen window 2
    group.windows[1].isFullscreened = true
    // Cycle: should skip window 2
    let next1 = group.nextInMRUCycle()
    XCTAssertNotNil(next1)
    // The returned index should not point to window 2
    if let idx = next1 {
        XCTAssertNotEqual(group.windows[idx].id, 2)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `scripts/test.sh`
Expected: FAIL — cycle doesn't skip fullscreened windows

**Step 3: Update `nextInMRUCycle` in TabGroup.swift**

In `nextInMRUCycle`, filter the cycle snapshot to exclude fullscreened windows. Change the snapshot filter (around line 131):

```swift
let windowIDs = Set(windows.filter { !$0.isFullscreened }.map(\.id))
```

Also add a guard for the `windows.count > 1` check to use visible count:

```swift
guard windows.filter({ !$0.isFullscreened }).count > 1 else { return nil }
```

**Step 4: Run test to verify it passes**

Run: `scripts/test.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroup.swift TabbedTests/TabGroupTests.swift
git commit -m "fix: skip fullscreened windows in MRU tab cycling"
```

---

### Task 12: Skip fullscreened windows in session save

**Files:**
- Modify: `Tabbed/features/SessionRestore/SessionManager.swift:9-24`

When saving session, we should clear the `isFullscreened` flag conceptually — the snapshot uses `WindowSnapshot` which doesn't include it, so session save/restore already works correctly. The window will be grouped normally on restore.

**Step 1: Verify — no code change needed**

`SessionManager.saveSession` maps to `WindowSnapshot` which only stores `windowID`, `bundleID`, `title`, `appName`. The `isFullscreened` flag is transient and not persisted. On restore, windows start as non-fullscreened. This is correct.

**Step 2: No commit needed**

---

### Task 13: Guard disbandGroup and quitGroup for fullscreened windows

**Files:**
- Modify: `Tabbed/features/TabGroups/TabGroups.swift` (disbandGroup, quitGroup)

When disbanding a group, fullscreened windows should be released cleanly without frame expansion. The existing `disbandGroup` tries to expand all windows — skip fullscreened ones.

**Step 1: Update `disbandGroup` frame expansion loop (TabGroups.swift:373-379)**

Change:
```swift
for window in group.windows {
    windowObserver.stopObserving(window: window)
    if group.tabBarSqueezeDelta > 0, let frame = AccessibilityHelper.getFrame(of: window.element) {
        let expandedFrame = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
        AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
    }
}
```

To:
```swift
for window in group.windows {
    windowObserver.stopObserving(window: window)
    if !window.isFullscreened, group.tabBarSqueezeDelta > 0,
       let frame = AccessibilityHelper.getFrame(of: window.element) {
        let expandedFrame = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
        AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
    }
}
```

**Step 2: Update `handleGroupDissolution` (TabGroups.swift:349-355)**

Same pattern — skip frame expansion for fullscreened windows:

```swift
if let lastWindow = group.windows.first {
    windowObserver.stopObserving(window: lastWindow)
    if !lastWindow.isFullscreened, group.tabBarSqueezeDelta > 0,
       let lastFrame = AccessibilityHelper.getFrame(of: lastWindow.element) {
        let expandedFrame = ScreenCompensation.expandFrame(lastFrame, undoingSqueezeDelta: group.tabBarSqueezeDelta)
        AccessibilityHelper.setFrame(of: lastWindow.element, to: expandedFrame)
    }
}
```

**Step 3: Update `applicationWillTerminate` (AppDelegate.swift:272-281)**

Same skip:
```swift
for window in group.windows {
    if !window.isFullscreened, let frame = AccessibilityHelper.getFrame(of: window.element) {
        let expandedFrame = ScreenCompensation.expandFrame(frame, undoingSqueezeDelta: delta)
        AccessibilityHelper.setFrame(of: window.element, to: expandedFrame)
    }
}
```

**Step 4: Build and test**

Run: `scripts/build.sh && scripts/test.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add Tabbed/features/TabGroups/TabGroups.swift Tabbed/AppDelegate.swift
git commit -m "fix: skip frame expansion for fullscreened windows on disband/quit/terminate"
```

---

### Task 14: Manual integration testing

**Not a code task — testing checklist for manual verification:**

1. Group 3 windows → fullscreen one → verify ghost tab appears dimmed with `-`
2. Click ghost tab → verify it switches to the fullscreen Space
3. Click `-` on ghost tab → verify window is released from group (stays fullscreened)
4. Fullscreen a window → exit fullscreen → verify it returns to group with correct frame
5. Fullscreen the only visible window in a 2-window group → verify tab bar hides
6. Exit fullscreen → verify tab bar reappears
7. Fullscreen a window → close it while fullscreened → verify group updates correctly
8. Fullscreen a window → disband group → verify no crash/frame weirdness
9. Fullscreen a window → switch Spaces → verify it's not ejected from group
10. Fullscreen a window → Cmd+Tab cycle → verify fullscreened window is skipped in MRU cycle
11. Quit app with a fullscreened group member → relaunch → verify session restores correctly (window grouped normally)
